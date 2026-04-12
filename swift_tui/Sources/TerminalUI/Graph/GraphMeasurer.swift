/// Intrinsic size measurement for attribute graph nodes.
/// Separated from GraphRenderer for clarity — measurement is a distinct concern
/// from rendering into a CellBuffer.
///
/// Results are cached on AttributeNode (cachedWidth, cachedHeight) and invalidated
/// when markDirty() propagates up the tree.
public enum GraphMeasurer {

    /// Intrinsic width — cached on the node, recomputed only when dirty.
    public static func measureWidth(_ node: AttributeNode) -> Int {
        if let cached = node.cachedWidth { return cached }
        let result = computeWidth(node)
        node.cachedWidth = result
        return result
    }

    /// Intrinsic height — cached on the node, recomputed only when dirty.
    public static func measureHeight(_ node: AttributeNode, proposedWidth: Int) -> Int {
        if let cached = node.cachedHeight { return cached }
        let result = computeHeight(node, proposedWidth: proposedWidth)
        node.cachedHeight = result
        return result
    }

    // MARK: - Computation (no allocation hot paths)

    private static func computeWidth(_ node: AttributeNode) -> Int {
        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                if spans.count == 1 {
                    return maxLineWidth(spans[0].text)
                }
                return maxLineWidth(spans.map(\.text).joined())
            case .spacer, .empty: return 0
            case .divider: return 1
            case .progressBar: return 20
            case .spinner(let frame, let style):
                return style.frames[frame % style.frames.count].count
            }

        case .layout(let info):
            let children = GraphRenderer.effectiveChildren(of: node)
            switch info.kind {
            case .vstack, .zstack:
                var maxW = 0
                for child in children {
                    maxW = max(maxW, measureWidth(child))
                }
                return maxW
            case .hstack:
                var total = 0
                for child in children {
                    total += measureWidth(child)
                }
                return total
            case .scroll(let axis):
                // Horizontal scroll: report viewport width (0 = flexible, parent decides).
                // Vertical scroll: report content width (same as vstack).
                switch axis {
                case .horizontal: return 0
                case .vertical:
                    var maxW = 0
                    for child in children {
                        maxW = max(maxW, measureWidth(child))
                    }
                    return maxW
                }
            }

        case .modifier(let effect):
            guard let child = node.children.first else { return 0 }
            var base = measureWidth(child)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border = effect { base += 2 }
            if case .frame(let w, _, let minW, let maxW, _, _) = effect {
                if let w { return w }
                if let maxW { base = min(base, maxW) }
                if let minW { base = max(base, minW) }
            }
            return base

        case .viewBody:
            return node.children.first.map { measureWidth($0) } ?? 0
        }
    }

    private static func computeHeight(_ node: AttributeNode, proposedWidth: Int) -> Int {
        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                let text = spans.count == 1 ? spans[0].text : spans.map(\.text).joined()
                return countWrappedLines(text, width: proposedWidth)
            case .spacer: return 1
            case .divider: return 1
            case .empty: return 0
            case .progressBar: return 1
            case .spinner: return 1
            }

        case .layout(let info):
            let children = GraphRenderer.effectiveChildren(of: node)
            switch info.kind {
            case .vstack:
                var total = 0
                for child in children {
                    total += measureHeight(child, proposedWidth: proposedWidth)
                }
                return total
            case .hstack, .zstack:
                var maxH = 0
                for child in children {
                    maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                }
                return maxH
            case .scroll(let axis):
                // Horizontal scroll: report content height (same as hstack).
                // Vertical scroll: report 0 (flexible, parent decides viewport height).
                switch axis {
                case .horizontal:
                    var maxH = 0
                    for child in children {
                        maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                    }
                    return maxH
                case .vertical: return 0
                }
            }

        case .modifier(let effect):
            guard let child = node.children.first else { return 0 }
            var base = measureHeight(child, proposedWidth: proposedWidth)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border = effect { base += 2 }
            if case .frame(_, let h, _, _, let minH, let maxH) = effect {
                if let h { return h }
                if let maxH { base = min(base, maxH) }
                if let minH { base = max(base, minH) }
            }
            return base

        case .viewBody:
            return node.children.first.map { measureHeight($0, proposedWidth: proposedWidth) } ?? 0
        }
    }

    // MARK: - String Measurement Helpers

    /// Count max line width without allocating an intermediate array.
    static func maxLineWidth(_ s: String) -> Int {
        var maxW = 0
        var current = 0
        for ch in s {
            if ch == "\n" {
                maxW = max(maxW, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(maxW, current)
    }

    /// Count number of lines without allocating an intermediate array.
    static func countLines(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        var count = 1
        for ch in s {
            if ch == "\n" { count += 1 }
        }
        return count
    }

    /// Count lines accounting for wrapping at the given width.
    /// Each line that exceeds width wraps to additional rows.
    static func countWrappedLines(_ s: String, width: Int) -> Int {
        if s.isEmpty { return 0 }
        guard width > 0 else { return countLines(s) }

        var rows = 0
        var col = 0
        for ch in s {
            if ch == "\n" {
                rows += 1
                col = 0
            } else {
                col += 1
                if col > width {
                    rows += 1
                    col = 1
                }
            }
        }
        return rows + 1  // last line (no trailing \n)
    }
}
