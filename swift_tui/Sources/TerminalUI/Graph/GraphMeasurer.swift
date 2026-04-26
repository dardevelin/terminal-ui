/// Intrinsic size measurement for attribute graph nodes.
/// Separated from GraphRenderer for clarity — measurement is a distinct concern
/// from rendering into a CellBuffer.
///
/// Results are cached on AttributeNode (cachedWidth, cachedHeight) and invalidated
/// when markDirty() propagates up the tree.
public enum GraphMeasurer {

    /// Intrinsic width — cached on the node, recomputed only when dirty.
    /// ViewBody nodes (composite views, GeometryReader) bypass the cache
    /// because their subtree can change between measurement calls — the
    /// cache key would need a state fingerprint we don't have. Mirrors
    /// the equivalent skip in `measureHeight`.
    public static func measureWidth(_ node: AttributeNode) -> Int {
        let skipCache: Bool
        switch node.kind {
        case .viewBody: skipCache = true
        default: skipCache = false
        }
        if !skipCache, let cached = node.cachedWidth { return cached }
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
        default:
            // Layout containers that transitively embed a viewBody must
            // also skip cache: their summed/max height includes the
            // viewBody's freshly-recomputed value, so a stale parent
            // cache would freeze them at last frame's child height.
            // PromptInput soft-wrap was the canary — the GR's parent
            // VStack reported height=1 from cache even after the GR's
            // child grew to N rows.
            skipCache = containsViewBody(node)
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

    /// True if `node` or any descendant has `.viewBody` kind. Cached
    /// on the node — `AttributeGraph.update(from:)` stamps every node
    /// bottom-up after reconciliation, so the answer is O(1) on the
    /// measurement hot path. Falls back to a lazy descendant walk that
    /// fills the cache when the stamp hasn't run yet (e.g. a node
    /// queried mid-build).
    static func containsViewBody(_ node: AttributeNode) -> Bool {
        if let cached = node._containsViewBody {
            return cached
        }
        #if DEBUG
        containsViewBodyWalkCount += 1
        #endif
        let result: Bool
        if case .viewBody = node.kind {
            result = true
        } else {
            var found = false
            for child in node.children {
                if containsViewBody(child) {
                    found = true
                    break
                }
            }
            result = found
        }
        node._containsViewBody = result
        return result
    }

    #if DEBUG
    /// Counts every descendant walk performed by `containsViewBody`.
    /// Tests reset to zero, exercise the measurement path, and assert
    /// the counter stays at zero — proof the bottom-up stamp filled
    /// the cache and reads short-circuit. MainActor-only by inheritance
    /// from the test harness; release builds elide the field entirely.
    nonisolated(unsafe) static var containsViewBodyWalkCount: Int = 0

    /// Test-only entry point so suites can probe the cache without
    /// going through the full `measureHeight` measurement pipeline.
    /// Underscored to telegraph it is not a public API.
    static func _containsViewBodyForTesting(_ node: AttributeNode) -> Bool {
        containsViewBody(node)
    }
    #endif

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
            case .cellBuffer(let source): return source.width
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
                // by rect enforcement. See `TextWrapMode`.
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
            case .cellBuffer(let source): return source.height
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
            // synchronises the content subtree with a live size. The seeded
            // child was built once at graph-construction with `terminalSize`,
            // so its measurement is only correct when the allocated rect
            // happens to match the seed. Rebuild with the current proposed
            // width (height is flexible from the parent's perspective, so
            // Phase separation: GeometryReader rebuilders fire in
            // Layout.measureAndPlace (HYP-203), not during measurement.
            // Measurement reads the seed subtree constructed at build
            // time. Once a frame's layout pass has run, subsequent
            // measurement calls see the size-resolved children. This
            // means `proposedWidth` may not match the GR's eventual
            // allocated width; PromptInput-style soft-wrap that needs
            // the true width relies on the layout pass running before
            // measurement is consulted, which is the runtime path.
            return node.children.first.map { measureHeight($0, proposedWidth: proposedWidth) } ?? 0
        }
    }

    // MARK: - String Measurement Helpers

    /// Count max line width without allocating an intermediate array.
    /// Uses display-width per grapheme, so a CJK ideograph
    /// contributes 2 columns and a combining mark contributes 0.
    static func maxLineWidth(_ s: String) -> Int {
        var maxW = 0
        var current = 0
        for ch in s {
            if ch == "\n" {
                maxW = max(maxW, current)
                current = 0
            } else {
                current += ch.displayWidth
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

    /// Count lines accounting for word-aware wrapping at the given
    /// width. Each logical line (`\n`-separated) is wrapped by
    /// `TextLayout.wrapWords` and contributes that many rows. Uses
    /// display-width per grapheme so a 2-cell character is treated as
    /// occupying 2 columns when deciding whether to wrap.
    ///
    /// Aligned with the renderer's word-aware soft-wrap path so the
    /// measurer's predicted row count matches what the renderer
    /// actually paints — preventing HEIGHT/RENDER drift that surfaces
    /// as stale cells or truncated content.
    static func countWrappedLines(_ s: String, width: Int) -> Int {
        if s.isEmpty { return 0 }
        guard width > 0 else { return countLines(s) }
        var rows = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let chunks = TextLayout.wrapWords(String(line), width: width)
            rows += max(1, chunks.count)
        }
        return rows
    }
}
