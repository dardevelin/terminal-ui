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
            switch info.kind {
            case .vstack, .zstack:
                var maxW = 0
                for child in node.children {
                    maxW = max(maxW, measureWidth(child))
                }
                return maxW
            case .hstack:
                var total = 0
                for child in node.children {
                    total += measureWidth(child)
                }
                return total
            }

        case .modifier(let effect):
            guard let child = node.children.first else { return 0 }
            var base = measureWidth(child)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border = effect { base += 2 }
            if case .frame(let w, _) = effect, let w { return w }
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
                if spans.count == 1 {
                    return countLines(spans[0].text)
                }
                return countLines(spans.map(\.text).joined())
            case .spacer: return 1
            case .divider: return 1
            case .empty: return 0
            case .progressBar: return 1
            case .spinner: return 1
            }

        case .layout(let info):
            switch info.kind {
            case .vstack:
                var total = 0
                for child in node.children {
                    total += measureHeight(child, proposedWidth: proposedWidth)
                }
                return total
            case .hstack, .zstack:
                var maxH = 0
                for child in node.children {
                    maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                }
                return maxH
            }

        case .modifier(let effect):
            guard let child = node.children.first else { return 0 }
            var base = measureHeight(child, proposedWidth: proposedWidth)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border = effect { base += 2 }
            if case .frame(_, let h) = effect, let h { return h }
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
}
