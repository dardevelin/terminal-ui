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

    /// Intrinsic height — cached on the node, recomputed only when dirty or
    /// when the proposed width changes. The `cachedHeight` value is only
    /// valid for the width it was computed at; a narrow `VStack` proposing
    /// 41 cells must not reuse a height computed for 140. ViewBody nodes
    /// (GeometryReader, any composite view with a body that reads live
    /// state inside a rebuild closure) bypass the cache because their
    /// subtree can change between measurement calls even when the width
    /// hasn't — the cache key would need to include the observed state
    /// fingerprint, which we don't have here.
    public static func measureHeight(_ node: AttributeNode, proposedWidth: Int) -> Int {
        let skipCache: Bool
        switch node.kind {
        case .viewBody: skipCache = true
        default: skipCache = false
        }
        if !skipCache,
           let cached = node.cachedHeight,
           node.cachedHeightWidth == proposedWidth {
            return cached
        }
        let result = computeHeight(node, proposedWidth: proposedWidth)
        node.cachedHeight = result
        node.cachedHeightWidth = proposedWidth
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
            if case .environment(let apply) = effect {
                let previous = GraphContext.currentEnvironment
                var nextEnv = previous ?? EnvironmentValues()
                apply(&nextEnv)
                GraphContext.currentEnvironment = nextEnv
                let result = measureWidth(child)
                GraphContext.currentEnvironment = previous
                return result
            }
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
                // Under `.none` wrap mode (set by DotMatrixText, MorseTicker,
                // and other fixed-geometry views), count only newline-separated
                // rows so measurement doesn't inflate when a logical row
                // exceeds proposedWidth. Overflow is clipped at render time
                // by HYP-90 rect enforcement. See `TextWrapMode`.
                let mode = GraphContext.currentEnvironment?.textWrap ?? .wrap
                switch mode {
                case .wrap: return countWrappedLines(text, width: proposedWidth)
                case .none: return countLines(text)
                }
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
            // Environment modifiers must influence measurement as well as
            // render (e.g. `.wrap(.none)` on a Text must stop the measurer
            // from inflating height at narrow widths). Push the modifier's
            // env over the current one, measure, then restore.
            if case .environment(let apply) = effect {
                let previous = GraphContext.currentEnvironment
                var nextEnv = previous ?? EnvironmentValues()
                apply(&nextEnv)
                GraphContext.currentEnvironment = nextEnv
                let result = measureHeight(child, proposedWidth: proposedWidth)
                GraphContext.currentEnvironment = previous
                return result
            }
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
            // GeometryReader nodes carry a `geometryRebuilder` closure that
            // constructs the content subtree from a live size. The seeded
            // child was built once at graph-construction with `terminalSize`,
            // so its measurement is only correct when the allocated rect
            // happens to match the seed. Rebuild with the current proposed
            // width (height is flexible from the parent's perspective, so
            // pass it through as-is) before measuring. Fixes PromptInput
            // soft-wrap: on narrow previews the seed reports 1 row but the
            // live rebuild with the true width reports the wrapped count.
            if let rebuild = node.geometryRebuilder {
                let width = proposedWidth > 0 ? proposedWidth : (GraphContext.currentEnvironment?.terminalSize.cols ?? 80)
                let height = GraphContext.currentProposedSize?.height ?? (GraphContext.currentEnvironment?.terminalSize.rows ?? 24)
                let rebuilt = rebuild(Size(width: width, height: height))
                return measureHeight(rebuilt, proposedWidth: proposedWidth)
            }
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
