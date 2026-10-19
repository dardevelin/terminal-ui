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
                // Gaps are part of how wide the stack is. Leaving them out
                // under-measures it, and every parent that sizes a stack from
                // its measurement — a centred stack, a border, a frame — then
                // clips the last child by exactly the total gap.
                return total + info.spacing * max(0, children.count - 1)
            case .scroll:
                // Both axes report the size of the content, measured through
                // the same single child `renderScroll` draws. A flex parent
                // never asks — it skips measurement for flex children and
                // hands the scroll view the space its siblings left — so
                // answering "0, you decide" only ever reached the parents that
                // size themselves to their content (`.border()`, `.padding()`),
                // which then allocated a viewport of nothing and drew an empty
                // box. Wanting all of the content and accepting less is the
                // contract SwiftUI's ScrollView states.
                return node.children.first.map { measureWidth($0) } ?? 0
            case .split(let axis):
                // SplitView: horizontal axis sums child widths + dividers;
                // vertical axis takes max child width. Mirrors hstack/vstack
                // measurement but accounts for the 1-cell divider per
                // sibling boundary.
                switch axis {
                case .horizontal:
                    var total = 0
                    for (i, child) in children.enumerated() {
                        if i > 0 { total += 1 }  // divider column
                        total += measureWidth(child)
                    }
                    return total
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
                var nextEnv = GraphContext.currentEnvironment ?? EnvironmentValues()
                apply(&nextEnv)
                return GraphContext.$currentEnvironment.withValue(nextEnv) {
                    measureWidth(child)
                }
            }
            // An explicit width answers on its own — see the height twin for
            // why measuring the child first and discarding it is not free.
            if case .frame(let width, _, _, _, _, _, _) = effect, let width { return width }

            var base = measureWidth(child)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border(_, _, let edges) = effect { base += edges.horizontalInset }
            if case .frame(_, _, let minW, let maxW, _, _, _) = effect {
                // .infinity contributes nothing to intrinsic measurement —
                // the renderer expands the rect during stack flex
                // distribution, not during measurement.
                if let maxW = maxW?.fixedValue { base = min(base, maxW) }
                if let minW = minW?.fixedValue { base = max(base, minW) }
            }
            return base

        case .viewBody:
            // Both readers take the width they are given and claim none of
            // their own: their content is built for that width, so asking it
            // how wide it is would be asking the answer for the question.
            if node.readerSizing != nil { return 0 }
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
                // Truncation shortens a logical line rather than spilling it,
                // so like `.none` the row count is the newline count — the
                // whole point is that the height cannot inflate.
                case .none, .truncate: return countLines(text)
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
                // See the width twin: the gaps are part of the size.
                return total + info.spacing * max(0, children.count - 1)
            case .hstack:
                // Each child must be measured against the width it will
                // actually be placed at, not the stack's full width. A
                // wrapping `Text` that fits the unspaced width but not the
                // width left after its siblings and the gaps reports one row
                // when it will render two, and the parent reserves a row too
                // few — the wrap's last line is then clipped by the parent's
                // rect. The allocation is shared with the render walk so the
                // two passes cannot drift apart.
                //
                // A non-positive `proposedWidth` is the "unconstrained,
                // measure intrinsically" sentinel the scroll-position walk
                // passes (see `measureFocusedPosition`). There is no width to
                // apportion then, so the proposal passes through untouched —
                // splitting zero columns between the children would measure
                // every one of them at nothing and report a stack of height 0.
                guard proposedWidth > 0 else {
                    var maxH = 0
                    for child in children {
                        maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                    }
                    return maxH
                }
                let childWidths = GraphRenderer.hstackChildWidths(
                    children, info: info, availableWidth: proposedWidth)
                var maxH = 0
                var x = 0
                for (i, child) in children.enumerated() {
                    if x >= proposedWidth { break }
                    let clamped = min(childWidths[i], proposedWidth - x)
                    maxH = max(maxH, measureHeight(child, proposedWidth: max(1, clamped)))
                    x += childWidths[i]
                    if i < children.count - 1 { x += info.spacing }
                }
                return maxH
            case .zstack:
                // Overlaid children each span the full width, so unlike an
                // `HStack` the proposal passes through untouched.
                var maxH = 0
                for child in children {
                    maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                }
                return maxH
            case .scroll:
                // Content height on both axes — see the width measurement for
                // why "0, parent decides" was only ever right for the parents
                // that never ask.
                var maxH = 0
                for child in children {
                    maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                }
                return maxH
            case .split(let axis):
                // Mirror of width measurement: vertical sums + 1 row per
                // sibling boundary; horizontal takes max child height.
                switch axis {
                case .horizontal:
                    var maxH = 0
                    for child in children {
                        maxH = max(maxH, measureHeight(child, proposedWidth: proposedWidth))
                    }
                    return maxH
                case .vertical:
                    var total = 0
                    for (i, child) in children.enumerated() {
                        if i > 0 { total += 1 }  // divider row
                        total += measureHeight(child, proposedWidth: proposedWidth)
                    }
                    return total
                }
            }

        case .modifier(let effect):
            guard let child = node.children.first else { return 0 }
            // Environment modifiers must influence measurement as well as
            // render (e.g. `.wrap(.none)` on a Text must stop the measurer
            // from inflating height at narrow widths). Push the modifier's
            // env over the current one, measure, then restore.
            if case .environment(let apply) = effect {
                var nextEnv = GraphContext.currentEnvironment ?? EnvironmentValues()
                apply(&nextEnv)
                return GraphContext.$currentEnvironment.withValue(nextEnv) {
                    measureHeight(child, proposedWidth: proposedWidth)
                }
            }
            // An explicit height is the answer on its own. Measuring the child
            // first and discarding the result was free while a scroll view
            // reported 0; now it walks — and evaluates the body of — every row
            // of a `Form` behind a `.frame(height:)`, once per frame, for a
            // number nothing reads.
            if case .frame(_, let height, _, _, _, _, _) = effect, let height { return height }

            // NOTE: the child is measured at the OUTER width, not the width
            // left after this modifier's own frame. That is wrong in
            // principle — a wrapping child inside a border reserves a row too
            // few — but correcting it destabilises the measure/layout feedback
            // cycle that `PromptInput`'s auto-growing height rides on (its
            // height policy reads `size.height` back out of its own
            // GeometryReader, and GR rebuilders fire during layout, not
            // measurement). Tracked separately; fixing it needs that cycle
            // addressed first.
            var base = measureHeight(child, proposedWidth: proposedWidth)
            if case .padding(let n) = effect { base += n * 2 }
            if case .border(_, _, let edges) = effect { base += edges.verticalInset }
            if case .frame(_, _, _, _, let minH, let maxH, _) = effect {
                if let maxH = maxH?.fixedValue { base = min(base, maxH) }
                if let minH = minH?.fixedValue { base = max(base, minH) }
            }
            return base

        case .viewBody:
            switch node.readerSizing {
            case .proposal:
                // Told its height by its container, so it claims none.
                // Reading its content here was the old contract, and the
                // content had been built for whatever size the last pass
                // happened to hold — a different answer depending on which
                // pass ran last. A container that sizes to its content gives
                // a GeometryReader nothing; give it a frame or a flexible slot.
                return 0
            case .width:
                // Built for the width being asked about, then measured. The
                // content depends on width alone, so this is the subtree
                // layout will draw at that width; asking twice in one update
                // is a memo hit. A non-positive width is the measurer's
                // "unconstrained" sentinel; the width last built stands in.
                let width = proposedWidth > 0 ? proposedWidth : (node._readerBuild?.width ?? 0)
                if width > 0 {
                    node.geometryRebuilder?(Size(width: width, height: 0), node)
                }
                return node.children.first.map { measureHeight($0, proposedWidth: max(1, width)) } ?? 0
            case nil:
                return node.children.first.map { measureHeight($0, proposedWidth: proposedWidth) } ?? 0
            }
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
