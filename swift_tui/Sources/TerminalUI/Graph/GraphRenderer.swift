public struct RenderContext {
    public var style: Style
    public var rect: Rect

    public init(style: Style = .plain, rect: Rect) {
        self.style = style
        self.rect = rect
    }
}

/// Renderer that walks the attribute graph instead of the view tree.
/// Switches on NodeKind enum — no Any, no as?, no protocol conformance checks.
public enum GraphRenderer {

    /// Presented modals collected during a render walk, composited against
    /// the screen buffer once the tree is drawn.
    ///
    /// A modal is a *screen-level* presentation: it dims everything and
    /// centres on the terminal. But `ScrollView` renders its content into a
    /// local buffer that is later blitted (see `renderLayout`'s scroll
    /// cases), so a modal declared inside one would otherwise centre on that
    /// sub-buffer and be clipped by the blit — the dialog lands inside the
    /// scrolled pane instead of over the app. Deferring detaches presentation
    /// from wherever it happens to be declared, which is the same reason
    /// SwiftUI's sheets don't inherit the declaring view's geometry.
    ///
    /// `nonisolated(unsafe)` matches the existing render-path statics: the
    /// runtime invariant is that rendering happens on the MainActor.
    nonisolated(unsafe) private static var deferredPresentations: [AttributeNode] = []

    /// Render `node`, then composite any presentations it declared against
    /// the full buffer. Nested calls (ScrollView content, the modal's own
    /// subtree) go through `render(_:into:context:)` and do NOT drain, so
    /// the deferral survives until the outermost walk finishes.
    public static func render(_ node: AttributeNode, into buffer: inout CellBuffer, context: RenderContext) {
        let isOutermost = !isRendering
        if isOutermost {
            isRendering = true
            deferredPresentations.removeAll(keepingCapacity: true)
        }
        renderNode(node, into: &buffer, context: context)
        if isOutermost {
            isRendering = false
            drainPresentations(into: &buffer)
        }
    }

    /// True while a render walk is in flight, so nested `render` calls know
    /// they are not the outermost one and must not drain.
    nonisolated(unsafe) private static var isRendering = false

    static func renderNode(_ node: AttributeNode, into buffer: inout CellBuffer, context: RenderContext) {
        // Record resolved rect on every node — used for hit testing
        node.rect = context.rect

        // Snapshot the in-flight environment onto the node so handlers
        // and tooling can read per-subtree resolved env between events
        // without replaying the render walk. SwiftUI's @Environment
        // reads target the same kind of cache. The snapshot is captured
        // BEFORE descending into children — the parent env is what this
        // node sees, descendants update their own slot when the
        // .environment modifier path mutates the in-flight context.
        node._resolvedEnv = GraphContext.currentEnvironment ?? EnvironmentValues()

        #if DEBUG
        DevTracer.shared.traceLayoutPlace(node.kind.debugName, rect: context.rect)
        #endif

        // Propagate proposed size to this node's subtree so `GeometryReader`
        // reports the actual allocated rect rather than the root terminal
        // size. Without this, a `GeometryReader` inside a narrow nested
        // layout would still think it had the whole screen to work with —
        // the bug that left `TextInput` over-budgeting its horizontal
        // scroll window in the Storybook preview pane.
        let proposed = Size(width: context.rect.width, height: context.rect.height)
        // The `withUnsafeMutablePointer` dance lets the `inout buffer`
        // parameter cross the @TaskLocal closure boundary — Swift
        // closures can't capture `inout` directly, but a pointer-by-
        // value closure can dereference back into the original storage.
        withUnsafeMutablePointer(to: &buffer) { bufPtr in
            GraphContext.$currentProposedSize.withValue(proposed) {
                // Rect-clip enforcement + overflow detection. Every node's
                // writes are bounded to its assigned rect intersected with
                // all ancestors' rects, so a misbehaving child can't punch
                // through a parent's border/frame. `withClipMeasured` also
                // returns the count of writes the clip dropped — when
                // non-zero AND the subtree hasn't opted into `.overflowOK()`,
                // emit a `componentOverflow` framework warning so the
                // layout bug is loud instead of silent.
                let droppedCells = bufPtr.pointee.withClipMeasured(context.rect) { buffer in
                    switch node.kind {
                    case .primitive(let content):
                        renderPrimitive(content, into: &buffer, context: context)

                    case .layout(let info):
                        renderLayout(node, info: info, into: &buffer, context: context)

                    case .modifier(let effect):
                        renderModifier(node, effect: effect, into: &buffer, context: context)

                    case .viewBody(let info):
                        #if DEBUG
                        DevTracer.shared.traceBodyEvaluated(info.viewTypeName)
                        #endif
                        // Phase separation: GeometryReader rebuilders run in
                        // the layout phase (`Layout.measureAndPlace`) before
                        // render reaches them. The runtime always calls
                        // measureAndPlace ahead of render so the GR's child
                        // subtree is already at the right size when render
                        // arrives — this branch is a pure draw on the
                        // production path.
                        //
                        // Defensive fallback for direct-render callers (unit
                        // tests that drive `GraphRenderer.render` without a
                        // prior `Layout.measureAndPlace`): if the GR's
                        // last-laid-out size doesn't match the current rect,
                        // fire the rebuilder once and stamp the size. This
                        // keeps existing test fixtures working while the
                        // runtime contract stays "render is pure."
                        if let rebuild = node.geometryRebuilder {
                            let size = Size(width: context.rect.width, height: context.rect.height)
                            if node._lastLaidOutSize != size {
                                rebuild(size, node)
                                node._lastLaidOutSize = size
                            }
                        }
                        for child in node.children {
                            render(child, into: &buffer, context: context)
                        }
                    }
                }
                #if DEBUG
                if droppedCells > 0 {
                    let envAllows = (node._resolvedEnv ?? GraphContext.currentEnvironment ?? EnvironmentValues()).overflowAllowed
                    if !envAllows {
                        DebugStream.shared.emitWarning(
                            .componentOverflow,
                            message: "node \(node.kind.debugName) wrote \(droppedCells) cell(s) outside its assigned rect (\(context.rect.width)×\(context.rect.height) at (\(context.rect.x), \(context.rect.y))). Layout bug? Suppress with `.overflowOK()` if intentional."
                        )
                    }
                }
                #endif
            }
        }
    }

    // MARK: - Primitives (enum switch = jump table)

    static func renderPrimitive(_ content: PrimitiveContent, into buffer: inout CellBuffer, context: RenderContext) {
        switch content {
        case .text(let spans):
            // Fast path: single unstyled span — use simple write
            if spans.count == 1 && !spans[0].hasOverrides {
                let string = spans[0].text
                let logicalLines = string.split(separator: "\n", omittingEmptySubsequences: false)
                let maxWidth = context.rect.width
                let mode = GraphContext.currentEnvironment?.textWrap ?? .wrap
                // Word-aware soft-wrap matches SwiftUI's
                // kCTLineBreakByWordWrapping default and HIG's text-
                // view prescription. `.none` keeps the legacy clip-
                // and-pad behaviour for fixed-geometry views (DotMatrix,
                // MorseTicker) that compose their own glyph rows.
                var rowOffset = 0
                for line in logicalLines {
                    let chunks: [String]
                    switch mode {
                    case .wrap:
                        chunks = TextLayout.wrapWords(String(line), width: maxWidth)
                    case .none:
                        // Legacy: clip to rect width, no wrapping.
                        let clipped = line.count > maxWidth ? String(line.prefix(maxWidth)) : String(line)
                        chunks = [clipped]
                    }
                    for chunk in chunks {
                        let y = context.rect.y + rowOffset
                        rowOffset += 1
                        guard y < context.rect.y + context.rect.height else { return }
                        // Pad to rect width with spaces so the trailing
                        // region is cleared when content shrank from a
                        // longer previous frame ("epsilone" →
                        // "epsilon" stale-cell bug).
                        let padCount = max(0, maxWidth - chunk.count)
                        let padded = chunk + String(repeating: " ", count: padCount)
                        buffer.write(padded, x: context.rect.x, y: y, style: context.style)
                    }
                }
            } else {
                // Styled path: write each span with its own resolved style
                buffer.writeSpans(spans, x: context.rect.x, y: context.rect.y,
                                  maxWidth: context.rect.width, maxHeight: context.rect.height,
                                  baseStyle: context.style)
            }

        case .spacer:
            break

        case .divider:
            let y = context.rect.y
            for x in context.rect.x..<(context.rect.x + context.rect.width) {
                buffer[x, y] = Cell(character: "─", style: context.style)
            }

        case .progressBar(let value, let label, let filled, let empty):
            let width = context.rect.width
            let labelPart = label.map { $0 + " " } ?? ""
            let percentText = " \(Int(value * 100))%"
            let barWidth = max(0, width - labelPart.count - percentText.count)
            let filledCount = Int(Double(barWidth) * value)
            let emptyCount = barWidth - filledCount
            let barText = labelPart
                + String(repeating: filled, count: filledCount)
                + String(repeating: empty, count: emptyCount)
                + percentText
            buffer.write(barText, x: context.rect.x, y: context.rect.y, style: context.style)

        case .spinner(let frame, let style):
            let frames = style.frames
            let text = frames[frame % frames.count]
            buffer.write(text, x: context.rect.x, y: context.rect.y, style: context.style)

        case .empty:
            break

        case .cellBuffer(let source):
            // Blit source[x, y] → buffer[rect.x + x, rect.y + y] for
            // the intersection of source dimensions and rect.
            // Source .empty cells DO write through — the user's
            // buffer is authoritative content; blanks are real.
            // (ScrollView's local-buffer blit skips .empty for a
            // different reason — it's masking out unpainted regions.)
            let cols = min(source.width, context.rect.width)
            let rows = min(source.height, context.rect.height)
            for y in 0..<rows {
                for x in 0..<cols {
                    buffer[context.rect.x + x, context.rect.y + y] = source[x, y]
                }
            }
        }
    }

    // MARK: - Layout

    static func renderLayout(_ node: AttributeNode, info: LayoutInfo, into buffer: inout CellBuffer, context: RenderContext) {
        // Flatten structural children (ForEach/TupleView layout nodes) so their
        // children participate directly in the parent's layout axis.
        // Graph identity nodes are preserved — only the renderer sees through them.
        let children = effectiveChildren(of: node)
        guard !children.isEmpty else { return }

        // Clear-before-layout to prevent shrunk-content bleed.
        // A VStack whose rows can change length (e.g. List swapping "epsilone"
        // for "epsilon") must blank its rect before re-laying children so
        // the vacated trailing cells aren't left with stale glyphs. ZStack
        // is SKIPPED because its semantics are stacking — each child draws on
        // top of the previous, blanking would wipe the layers below. Scroll
        // is SKIPPED because it composites via a local buffer, already
        // producing a clean viewport.
        switch info.kind {
        case .vstack, .hstack:
            buffer.fill(context.rect, character: " ", style: context.style)
        case .zstack, .scroll:
            break
        case .split:
            // Split owns its rect arithmetic in Layout (Layer 2) and
            // each child's rect carries its slice. Clear the parent
            // rect once so divider columns/rows aren't ghosted from
            // the previous frame, then walk children + draw dividers.
            buffer.fill(context.rect, character: " ", style: context.style)
        }

        switch info.kind {
        case .vstack:
            renderVStack(children, into: &buffer, context: context)
        case .hstack:
            renderHStack(children, into: &buffer, context: context)
        case .zstack:
            renderZStack(children, into: &buffer, context: context)
        case .scroll(let axis):
            renderScroll(node, axis: axis, children: children, into: &buffer, context: context)
        case .split(let axis):
            renderSplit(axis: axis, children: children, into: &buffer, context: context)
        }
    }

    /// Render a SplitView's children at their pre-stamped rects (set by
    /// `Layout.placeSplit`) and draw the divider glyph in the gap between
    /// adjacent siblings.
    ///
    /// Layer-2 contract: rects are read, never recomputed here.
    /// Divider glyph: U+2502 BOX DRAWINGS LIGHT VERTICAL `│` for
    /// horizontal-axis splits (column gap), U+2500 BOX DRAWINGS LIGHT
    /// HORIZONTAL `─` for vertical-axis splits (row gap).
    private static func renderSplit(
        axis: SplitAxis,
        children: [AttributeNode],
        into buffer: inout CellBuffer,
        context: RenderContext
    ) {
        for child in children {
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: child.rect))
        }

        // Dividers sit in the 1-cell gap between adjacent child rects.
        let glyph: Character = axis == .horizontal ? "│" : "─"
        for i in 0..<(children.count - 1) {
            let leading = children[i].rect
            switch axis {
            case .horizontal:
                let dividerX = leading.x + leading.width
                for y in context.rect.y..<(context.rect.y + context.rect.height) {
                    buffer[dividerX, y] = Cell(character: glyph, style: context.style)
                }
            case .vertical:
                let dividerY = leading.y + leading.height
                for x in context.rect.x..<(context.rect.x + context.rect.width) {
                    buffer[x, dividerY] = Cell(character: glyph, style: context.style)
                }
            }
        }
    }

    /// Collect effective children by flattening nested layout nodes that are
    /// structural (ForEach, TupleView) rather than explicit (VStack, HStack, ZStack).
    /// A structural layout node is one whose viewTypeName in the graph came from
    /// ForEach/TupleView — these should be transparent to the parent's layout axis.
    static func effectiveChildren(of node: AttributeNode) -> [AttributeNode] {
        var result: [AttributeNode] = []
        for child in node.children {
            if isStructuralLayout(child) {
                result.append(contentsOf: effectiveChildren(of: child))
            } else {
                result.append(child)
            }
        }
        return result
    }

    /// A layout node is "structural" if it was synthesised by ForEach or the
    /// `@TerminalViewBuilder` TupleView machinery. User-written
    /// `VStack`/`HStack`/`ZStack` are NOT structural.
    ///
    /// Previously this used a heuristic based on parent-node kind, which mis-
    /// classified user-written VStacks nested inside composite-view bodies
    /// as structural — that broke Button-page arrow navigation because the
    /// outer VStack holding the sibling Buttons was treated as transparent
    /// and `findLayoutParent` walked past it. Now we read the explicit
    /// `isStructural` flag set at graph construction, so the distinction is
    /// reliable.
    static func isStructuralLayout(_ node: AttributeNode) -> Bool {
        if case .layout(let info) = node.kind, info.isStructural { return true }
        return false
    }

    /// Compute spacer distribution: base size per spacer + how many get one extra unit.
    private static func spacerDistribution(spacerCount: Int, available: Int) -> (base: Int, remainder: Int) {
        guard spacerCount > 0 else { return (0, 0) }
        return (available / spacerCount, available % spacerCount)
    }

    /// Consume one spacer unit from a distribution, returning the size for this spacer.
    private static func consumeSpacer(base: Int, remainder: inout Int) -> Int {
        let extra = remainder > 0 ? 1 : 0
        remainder -= extra
        return base + extra
    }

    /// Distribute `available` cells across flex children proportional
    /// to their `grow` weights, mirroring CSS flexbox `flex-grow`.
    /// Returns the per-child cell count in input order. The leftover
    /// remainder (`available % totalWeight`) is dealt out one cell at
    /// a time to the children with the highest fractional share so
    /// the total still sums to `available`.
    ///
    /// Equal-weight inputs collapse to the same equal-split that
    /// `spacerDistribution` produced, so spacers and scroll views
    /// route through this function unchanged.
    private static func weightedDistribution(weights: [Int], available: Int) -> [Int] {
        guard !weights.isEmpty, available > 0 else {
            return Array(repeating: 0, count: weights.count)
        }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            return Array(repeating: 0, count: weights.count)
        }
        // Integer floor allocation per child.
        var sizes = weights.map { ($0 * available) / totalWeight }
        var leftover = available - sizes.reduce(0, +)
        // Hand out leftover cells to children with the largest
        // fractional shortfall — compute shortfall = (weight*available)
        // % totalWeight; the higher this is, the closer the child was
        // to rounding up. Largest shortfall first keeps distribution
        // stable and weight-proportional.
        let shortfalls: [(idx: Int, short: Int)] = weights.enumerated().map { (idx, w) in
            (idx, (w * available) % totalWeight)
        }
        let order = shortfalls.sorted { $0.short > $1.short }.map { $0.idx }
        var orderIdx = 0
        while leftover > 0 {
            sizes[order[orderIdx % order.count]] += 1
            leftover -= 1
            orderIdx += 1
        }
        return sizes
    }

    static func renderVStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        var flexIndices: [Int] = []
        var flexWeights: [Int] = []
        for (i, child) in children.enumerated() {
            if isVFlexChild(child) {
                flexIndices.append(i)
                flexWeights.append(vFlexGrow(child))
            }
        }

        var childHeights: [Int] = []
        var totalContentHeight = 0
        for child in children {
            if isVFlexChild(child) {
                childHeights.append(0)
            } else {
                let h = measureHeight(child, proposedWidth: context.rect.width)
                childHeights.append(h)
                totalContentHeight += h
            }
        }

        let remaining = max(0, context.rect.height - totalContentHeight)
        let perFlex = weightedDistribution(weights: flexWeights, available: remaining)
        var flexHeightByIndex: [Int: Int] = [:]
        for (slot, idx) in flexIndices.enumerated() {
            flexHeightByIndex[idx] = perFlex[slot]
        }

        var y = context.rect.y
        for (i, child) in children.enumerated() {
            if isVFlexChild(child) {
                let flexHeight = flexHeightByIndex[i] ?? 0
                if case .primitive(.spacer) = child.kind {
                    y += flexHeight
                } else {
                    let childRect = Rect(x: context.rect.x, y: y,
                                         width: context.rect.width, height: max(1, flexHeight))
                    // Re-stamp the subtree's Layer-2 rects from this
                    // child's anchor. VStack/HStack/Scroll still own
                    // distribution (Layer 3), so the top-level Layout
                    // pass placed this child at the parent's rect; we
                    // need a fresh stamp now that flex resolved the
                    // real slot. Once Layer 3 lands, this call goes
                    // away and render becomes a pure walk.
                    Layout.measureAndPlace(graph: child, in: childRect)
                    render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
                    y += flexHeight
                }
                continue
            }
            let h = childHeights[i]
            let childRect = Rect(x: context.rect.x, y: y, width: context.rect.width, height: max(1, h))
            Layout.measureAndPlace(graph: child, in: childRect)
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            y += h
        }
    }

    /// Vertical flex: spacers, vertical scroll views, `.flexible(.vertical)`,
    /// and `.frame(maxHeight: .infinity)` all consume remaining height.
    private static func isVFlexChild(_ node: AttributeNode) -> Bool {
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.vertical) = info.kind { return true }
        if case .modifier(.flexible(let axes, _)) = node.kind, axes.contains(.vertical) { return true }
        if case .modifier(.frame(_, _, _, _, _, let maxH)) = node.kind, maxH == .infinity { return true }
        // Transparent modifiers (env, lifecycle, focus hooks, paint
        // effects) don't impose a height of their own — peel through
        // to detect a flex descendant. Without this, wrapping a
        // ScrollView in `.environment(...)` (e.g. `.scrollPosition(id:)`)
        // collapses it to its intrinsic 1-row size in a VStack.
        if case .modifier(let effect) = node.kind, isTransparentModifier(effect),
           let child = node.children.first {
            return isVFlexChild(child)
        }
        return false
    }

    /// A modifier is "transparent" for flex/sizing purposes when it
    /// doesn't impose its own size on the child. Painting effects
    /// (foreground/bold/etc), lifecycle hooks, focus modifiers,
    /// click/hover/key dispatch, environment passthrough — none of
    /// these change layout. Frames, padding, borders, .flexible, and
    /// the modal/overlay shapes DO change layout and are NOT
    /// transparent.
    private static func isTransparentModifier(_ effect: ModifierEffect) -> Bool {
        switch effect {
        case .foreground, .background, .bold, .italic, .underline,
             .focusable, .focusScope,
             .onKeyPress, .onAppear, .onChange, .onDisappear,
             .onClick, .onHover, .onPaste,
             .actions, .environment, .explicitID:
            return true
        case .padding, .border, .frame, .flexible,
             .overlay, .backgroundView, .modal:
            return false
        }
    }

    /// Grow weight for a vertical flex child. Spacers, scroll views,
    /// and `.frame(maxHeight: .infinity)` all weight at 1; only
    /// `.flexible(grow:)` exposes a non-default weight.
    private static func vFlexGrow(_ node: AttributeNode) -> Int {
        if case .modifier(.flexible(_, let grow)) = node.kind { return grow }
        return 1
    }

    static func renderHStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        // Identify flex children + their grow weights. Spacers, scroll
        // views, `.flexible(.horizontal)`, and `.frame(maxWidth: .infinity)`
        // all qualify; only `.flexible(grow:)` carries a non-default weight.
        var flexIndices: [Int] = []
        var flexWeights: [Int] = []
        for (i, child) in children.enumerated() {
            if isFlexChild(child) {
                flexIndices.append(i)
                flexWeights.append(flexGrow(child))
            }
        }

        var childWidths: [Int] = []
        var totalContentWidth = 0
        for child in children {
            if isFlexChild(child) {
                childWidths.append(0)
            } else {
                let w = measureWidth(child)
                childWidths.append(w)
                totalContentWidth += w
            }
        }

        let remaining = max(0, context.rect.width - totalContentWidth)
        let perFlex = weightedDistribution(weights: flexWeights, available: remaining)
        // Map flex slot index → allocated width.
        var flexWidthByIndex: [Int: Int] = [:]
        for (slot, idx) in flexIndices.enumerated() {
            flexWidthByIndex[idx] = perFlex[slot]
        }

        let maxX = context.rect.x + context.rect.width
        var x = context.rect.x
        for (i, child) in children.enumerated() {
            if x >= maxX { break }
            if isFlexChild(child) {
                let flexWidth = flexWidthByIndex[i] ?? 0
                // Spacers just consume space; scroll views and other
                // flex-marked children render into the allocated rect.
                if case .primitive(.spacer) = child.kind {
                    x += flexWidth
                } else {
                    let childRect = Rect(x: x, y: context.rect.y,
                                         width: max(1, flexWidth), height: context.rect.height)
                    Layout.measureAndPlace(graph: child, in: childRect)
                    render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
                    x += flexWidth
                }
                continue
            }
            let w = childWidths[i]
            let clampedWidth = min(w, maxX - x)
            let childRect = Rect(x: x, y: context.rect.y, width: max(1, clampedWidth), height: context.rect.height)
            Layout.measureAndPlace(graph: child, in: childRect)
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            x += w
        }
    }

    /// A child is "flex" if it should consume remaining space in a stack layout.
    /// Spacers, horizontal scroll views, `.flexible(.horizontal)`, and
    /// `.frame(maxWidth: .infinity)` all qualify in HStacks.
    private static func isFlexChild(_ node: AttributeNode) -> Bool {
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.horizontal) = info.kind { return true }
        if case .modifier(.flexible(let axes, _)) = node.kind, axes.contains(.horizontal) { return true }
        if case .modifier(.frame(_, _, _, let maxW, _, _)) = node.kind, maxW == .infinity { return true }
        return false
    }

    /// Grow weight for a horizontal flex child. Spacers, scroll views,
    /// and `.frame(maxWidth: .infinity)` all weight at 1; only
    /// `.flexible(grow:)` exposes a non-default weight.
    private static func flexGrow(_ node: AttributeNode) -> Int {
        if case .modifier(.flexible(_, let grow)) = node.kind { return grow }
        return 1
    }

    // MARK: - Scroll

    /// Render a scroll container: render content into a local buffer at natural size,
    /// then blit the visible slice (offset by scrollOffset) into the main buffer.
    ///
    /// Two-phase approach prevents content bleeding past the viewport boundary
    /// (e.g. into border columns). The local buffer acts as a clip mask.
    ///
    /// After blitting, a small edge-indicator glyph is painted in the last
    /// viewport cell of each direction that has scrollable content remaining
    ///. Indicator visibility is controlled by the `scrollIndicators`
    /// environment value.
    static func renderScroll(_ node: AttributeNode, axis: ScrollAxis, children: [AttributeNode],
                             into buffer: inout CellBuffer, context: RenderContext) {
        guard let contentChild = node.children.first else { return }
        let offset = node.scrollOffset
        let viewport = context.rect
        let showIndicators = (GraphContext.currentEnvironment?.scrollIndicators ?? .visible) == .visible

        switch axis {
        case .horizontal:
            let contentWidth = measureWidth(contentChild)
            guard contentWidth > 0, viewport.width > 0, viewport.height > 0 else { return }

            // Render content into a local buffer at (0,0) with natural width
            var contentBuffer = CellBuffer(width: contentWidth, height: viewport.height)
            let contentRect = Rect(x: 0, y: 0, width: contentWidth, height: viewport.height)
            // Re-stamp the content subtree's Layer-2 rects from the
            // local-buffer origin (0, 0) — the top-level Layout pass
            // placed contentChild at the viewport rect, but the local
            // render is anchored at (0, 0). offsetRects(...) below
            // translates back to screen coords after the content is
            // drawn.
            Layout.measureAndPlace(graph: contentChild, in: contentRect)
            render(contentChild, into: &contentBuffer,
                   context: RenderContext(style: context.style, rect: contentRect))

            // Blit visible slice: source x range [offset ..< offset+viewportWidth]
            let srcStartX = max(0, offset)
            let srcEndX = min(contentWidth, offset + viewport.width)
            for y in 0..<viewport.height {
                for srcX in srcStartX..<srcEndX {
                    let dstX = viewport.x + (srcX - offset)
                    let dstY = viewport.y + y
                    let cell = contentBuffer[srcX, y]
                    if cell != .empty {
                        buffer[dstX, dstY] = cell
                    }
                }
            }

            // Offset child rects so hit testing works in screen coordinates
            offsetRects(of: contentChild, dx: viewport.x - offset, dy: viewport.y)

            if showIndicators {
                // ◀ when content extends before the viewport's left edge,
                // ▶ when content extends past the right edge. Painted in the
                // first/last cell of the viewport's top row for visibility
                // without stealing a content row.
                // Indicator glyphs use cyan+bold to match the focus-ring
                // colour — dim grey was too subtle in live Storybook and
                // users mistook clipped content for missing content
                //.
                let indicatorStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                if offset > 0 {
                    buffer[viewport.x, viewport.y] = Cell(character: "◀", style: indicatorStyle)
                }
                if contentWidth > offset + viewport.width {
                    buffer[viewport.x + viewport.width - 1, viewport.y] = Cell(character: "▶", style: indicatorStyle)
                }

                // Horizontal thumb-track on the bottom row. ─ track
                // across the full width, █ thumb at the proportional
                // start. Skipped when content fits (scrollbarThumb
                // returns nil). Painted last so it overlays the
                // bottom row's content cells — acceptable since the
                // content row needed to grow above to leave room for
                // the scrollbar visual; the user trades one content
                // row for the affordance.
                if let thumb = scrollbarThumb(viewport: viewport.width,
                                              content: contentWidth,
                                              offset: offset) {
                    let trackY = viewport.y + viewport.height - 1
                    let trackStyle = Style(foreground: .gray, background: nil,
                                           bold: false, italic: false, underline: false)
                    let thumbStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                    for x in 0..<viewport.width {
                        buffer[viewport.x + x, trackY] = Cell(character: "─", style: trackStyle)
                    }
                    for i in 0..<thumb.length {
                        buffer[viewport.x + thumb.start + i, trackY] = Cell(character: "█", style: thumbStyle)
                    }
                }
            }

        case .vertical:
            let contentHeight = measureHeight(contentChild, proposedWidth: viewport.width)
            guard contentHeight > 0, viewport.width > 0, viewport.height > 0 else { return }

            var contentBuffer = CellBuffer(width: viewport.width, height: contentHeight)
            let contentRect = Rect(x: 0, y: 0, width: viewport.width, height: contentHeight)
            // Re-stamp from local-buffer origin (0, 0); offsetRects
            // below translates back to screen coords.
            Layout.measureAndPlace(graph: contentChild, in: contentRect)
            render(contentChild, into: &contentBuffer,
                   context: RenderContext(style: context.style, rect: contentRect))

            let srcStartY = max(0, offset)
            let srcEndY = min(contentHeight, offset + viewport.height)
            for srcY in srcStartY..<srcEndY {
                for x in 0..<viewport.width {
                    let dstX = viewport.x + x
                    let dstY = viewport.y + (srcY - offset)
                    let cell = contentBuffer[x, srcY]
                    if cell != .empty {
                        buffer[dstX, dstY] = cell
                    }
                }
            }

            offsetRects(of: contentChild, dx: viewport.x, dy: viewport.y - offset)

            if showIndicators {
                // ▲ when content extends above the viewport's top row,
                // ▼ when content extends below the bottom row. Painted in the
                // top/bottom-right cell of the viewport — right edge keeps
                // the indicator out of the way of content readers scanning
                // left-to-right.
                // Indicator glyphs use cyan+bold to match the focus-ring
                // colour — dim grey was too subtle in live Storybook and
                // users mistook clipped content for missing content
                //.
                let indicatorStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                if offset > 0 {
                    buffer[viewport.x + viewport.width - 1, viewport.y] = Cell(character: "▲", style: indicatorStyle)
                }
                if contentHeight > offset + viewport.height {
                    buffer[viewport.x + viewport.width - 1, viewport.y + viewport.height - 1] = Cell(character: "▼", style: indicatorStyle)
                }

                // Vertical thumb-track on the rightmost column. │ track
                // top-to-bottom, █ thumb at the proportional start. Painted
                // BEFORE the ▲/▼ edge glyphs above so those still win at
                // the corners; thumb skips its track cells where the
                // edge-glyph already sits. Skipped when content fits
                // (scrollbarThumb returns nil).
                if let thumb = scrollbarThumb(viewport: viewport.height,
                                              content: contentHeight,
                                              offset: offset) {
                    let trackX = viewport.x + viewport.width - 1
                    let trackStyle = Style(foreground: .gray, background: nil,
                                           bold: false, italic: false, underline: false)
                    let thumbStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                    for y in 0..<viewport.height {
                        // Don't paint over the ▲/▼ edge glyphs; they
                        // sit at trackY = top/bottom of the column and
                        // were already drawn by the block above.
                        let trackY = viewport.y + y
                        let isTopGlyph = y == 0 && offset > 0
                        let isBottomGlyph = y == viewport.height - 1
                            && contentHeight > offset + viewport.height
                        if isTopGlyph || isBottomGlyph { continue }
                        buffer[trackX, trackY] = Cell(character: "│", style: trackStyle)
                    }
                    for i in 0..<thumb.length {
                        let y = thumb.start + i
                        let trackY = viewport.y + y
                        let isTopGlyph = y == 0 && offset > 0
                        let isBottomGlyph = y == viewport.height - 1
                            && contentHeight > offset + viewport.height
                        if isTopGlyph || isBottomGlyph { continue }
                        buffer[trackX, trackY] = Cell(character: "█", style: thumbStyle)
                    }
                }
            }
        }
    }

    static func renderZStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        // Layer 2: Layout stamps every ZStack child's rect to the
        // parent's rect. Render reads the pre-stamped rect — last
        // child wins on overlapping cells.
        for child in children {
            var childCtx = context
            childCtx.rect = child.rect
            render(child, into: &buffer, context: childCtx)
        }
    }

    // MARK: - Scroll-to-Focused

    /// Adjust scroll offsets on all scroll containers that enclose the focused node.
    ///
    /// Strategy: find the focused node, walk UP to find scroll ancestors.
    /// For each scroll ancestor, compute the focused node's position within the
    /// scroll content using measurements, then adjust offset to keep it visible.
    ///
    /// Must run AFTER graph update, BEFORE render — render uses scrollOffset.
    public static func adjustScrollForFocus(root: AttributeNode?, focusedID: NodeID?,
                                            viewportWidth: Int, viewportHeight: Int) {
        guard let root, let focusedID else { return }
        guard let focusedNode = findNode(focusedID, in: root) else { return }

        // Walk up from focused node to find scroll container ancestors
        var current = focusedNode
        while let parent = current.parent {
            if case .layout(let info) = parent.kind, case .scroll(let axis) = info.kind {
                guard let contentChild = parent.children.first else { break }

                let focusedPosition = measureFocusedPosition(
                    in: contentChild, focusedID: focusedID, axis: axis
                )

                if let (start, size) = focusedPosition {
                    // Use the scroll node's rect from the previous frame for viewport size.
                    // This is the actual allocated size after parent layout, not the terminal size.
                    // On first frame rect is zero — fall back to terminal size.
                    let scrollRect = parent.rect
                    let viewportSize: Int
                    switch axis {
                    case .horizontal:
                        viewportSize = scrollRect.width > 0 ? scrollRect.width : viewportWidth
                    case .vertical:
                        viewportSize = scrollRect.height > 0 ? scrollRect.height : viewportHeight
                    }

                    adjustScrollOffset(
                        node: parent, axis: axis, focusedStart: start, focusedSize: size,
                        viewportSize: viewportSize
                    )
                }
            }
            current = parent
        }
    }

    /// Adjust scroll offsets on every scroll container whose resolved env
    /// has `scrollTargetID` set. Walks each scroll container's subtree to
    /// find the descendant tagged with `.id(matching)` and runs the same
    /// position math as `adjustScrollForFocus` to keep that node visible.
    ///
    /// Independent of keyboard focus — this is the SwiftUI
    /// `.scrollPosition(id:)` path. Runs as a sibling pass; either path
    /// (focus-driven OR target-driven) may set the offset, last writer
    /// wins per scroll container per frame. In practice they don't
    /// conflict: `.scrollPosition(id:)` is opt-in, and apps using it
    /// know they're driving scroll explicitly.
    ///
    /// Must run AFTER graph update, BEFORE render — render uses scrollOffset.
    public static func adjustScrollForExplicitTarget(root: AttributeNode?,
                                                     viewportWidth: Int, viewportHeight: Int) {
        guard let root else { return }
        adjustScrollForExplicitTargetWalk(root, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }

    private static func adjustScrollForExplicitTargetWalk(_ node: AttributeNode,
                                                          viewportWidth: Int,
                                                          viewportHeight: Int,
                                                          env: EnvironmentValues = EnvironmentValues()) {
        // Apply this node's env contribution before recursing — env
        // modifiers stack as we descend. Mirrors the render walk's
        // environment propagation, except we compute it in one pass
        // here instead of relying on `_resolvedEnv` (which is only
        // populated during render — but the scroll-adjust pass runs
        // BEFORE render, so the cache is one frame stale or absent).
        var currentEnv = env
        if case .modifier(.environment(let apply)) = node.kind {
            apply(&currentEnv)
        }

        // Is this a scroll container with an explicit target ID set?
        if case .layout(let info) = node.kind,
           case .scroll(let axis) = info.kind,
           let targetID = currentEnv.scrollTargetID,
           let contentChild = node.children.first
        {
            // Find the descendant whose subtree was tagged with .id(targetID).
            if let targetNode = findExplicitlyIDedNode(in: contentChild, matching: targetID) {
                let focusedPosition = measureFocusedPosition(
                    in: contentChild, focusedID: targetNode.id, axis: axis
                )
                if let (start, size) = focusedPosition {
                    let scrollRect = node.rect
                    let viewportSize: Int
                    switch axis {
                    case .horizontal:
                        viewportSize = scrollRect.width > 0 ? scrollRect.width : viewportWidth
                    case .vertical:
                        viewportSize = scrollRect.height > 0 ? scrollRect.height : viewportHeight
                    }
                    adjustScrollOffset(
                        node: node, axis: axis, focusedStart: start, focusedSize: size,
                        viewportSize: viewportSize
                    )
                }
            }
        }
        // Recurse — nested ScrollViews may each have their own target.
        for child in node.children {
            adjustScrollForExplicitTargetWalk(child,
                                              viewportWidth: viewportWidth,
                                              viewportHeight: viewportHeight,
                                              env: currentEnv)
        }
    }

    /// Locate the node directly beneath an `.id(matching)` modifier in
    /// `subtree`. Returns the modifier's child (the tagged content)
    /// whose position the renderer can compute against the scroll axis.
    /// `nil` when no matching tag exists.
    private static func findExplicitlyIDedNode(in subtree: AttributeNode,
                                                matching targetID: ScrollTargetID) -> AttributeNode? {
        if case .modifier(.explicitID(let id)) = subtree.kind, id == targetID.id {
            // .id() wraps a single child — that's the node whose
            // position we want to bring into view.
            return subtree.children.first ?? subtree
        }
        for child in subtree.children {
            if let found = findExplicitlyIDedNode(in: child, matching: targetID) {
                return found
            }
        }
        return nil
    }

    /// Compute the position and size of the focused node within a content subtree.
    /// Returns (start offset in scroll axis, size in scroll axis) or nil if not found.
    ///
    /// For HStack content: walks effective children, sums widths before the child
    /// that contains the focused node.
    /// For VStack content: same with heights.
    /// For other node types: recurses into children.
    private static func measureFocusedPosition(in node: AttributeNode, focusedID: NodeID,
                                               axis: ScrollAxis) -> (start: Int, size: Int)? {
        // Is this node (or its subtree) the focused node?
        if node.id == focusedID {
            let size = axis == .horizontal ? measureWidth(node) : measureHeight(node, proposedWidth: 0)
            return (start: 0, size: size)
        }

        // If this is a layout node, compute child positions along its axis
        if case .layout(let info) = node.kind {
            let children = effectiveChildren(of: node)
            let isMatchingAxis: Bool
            switch (info.kind, axis) {
            case (.hstack, .horizontal), (.vstack, .vertical): isMatchingAxis = true
            default: isMatchingAxis = false
            }

            if isMatchingAxis {
                // Children are laid out sequentially along the scroll axis
                var position = 0
                for child in children {
                    if let result = measureFocusedPosition(in: child, focusedID: focusedID, axis: axis) {
                        return (start: position + result.start, size: result.size)
                    }
                    position += axis == .horizontal ? measureWidth(child) : measureHeight(child, proposedWidth: 0)
                }
                return nil
            }
        }

        // For non-matching layouts, modifiers, viewBody: recurse into children
        for child in node.children {
            if let result = measureFocusedPosition(in: child, focusedID: focusedID, axis: axis) {
                return result
            }
        }
        return nil
    }

    /// Adjust a scroll node's offset to keep the focused element visible within the viewport.
    private static func adjustScrollOffset(node: AttributeNode, axis: ScrollAxis,
                                           focusedStart: Int, focusedSize: Int, viewportSize: Int) {
        guard viewportSize > 0 else { return }

        // Measure total content size
        guard let contentChild = node.children.first else { return }
        let totalContent = axis == .horizontal
            ? measureWidth(contentChild)
            : measureHeight(contentChild, proposedWidth: 0)

        // Content fits in viewport — no scroll needed
        guard totalContent > viewportSize else {
            node.scrollOffset = 0
            return
        }

        let focusedEnd = focusedStart + focusedSize
        var offset = node.scrollOffset

        // Focused element past the right/bottom edge — scroll forward
        if focusedEnd > offset + viewportSize {
            offset = focusedEnd - viewportSize
        }

        // Focused element before the left/top edge — scroll backward
        if focusedStart < offset {
            offset = focusedStart
        }

        let maxOffset = max(0, totalContent - viewportSize)
        node.scrollOffset = max(0, min(offset, maxOffset))
    }

    /// Find a node by ID via tree walk.
    private static func findNode(_ id: NodeID, in node: AttributeNode) -> AttributeNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id, in: child) { return found }
        }
        return nil
    }

    // MARK: - Modifiers

    static func renderModifier(_ node: AttributeNode, effect: ModifierEffect, into buffer: inout CellBuffer, context: RenderContext) {
        var ctx = context
        guard let child = node.children.first else { return }

        switch effect {
        case .foreground(let color):
            ctx.style.foreground = color
            render(child, into: &buffer, context: ctx)

        case .background(let color):
            ctx.style.background = color
            render(child, into: &buffer, context: ctx)

        case .bold:
            ctx.style.bold = true
            render(child, into: &buffer, context: ctx)

        case .italic:
            ctx.style.italic = true
            render(child, into: &buffer, context: ctx)

        case .underline:
            ctx.style.underline = true
            render(child, into: &buffer, context: ctx)

        case .padding:
            // Layer 2: Layout has pre-stamped child.rect with the
            // padding inset. Render reads it and passes through —
            // no rect computation here.
            ctx.rect = child.rect
            render(child, into: &buffer, context: ctx)

        case .border(let style):
            // Border ring draws at the modifier node's OUTER rect
            // (`ctx.rect`); the child draws inside the inset rect
            // that Layout already stamped on `child.rect`.
            renderBorder(style, into: &buffer, context: ctx)
            ctx.rect = child.rect
            render(child, into: &buffer, context: ctx)

        case .frame:
            // Layer 2: Layout has pre-stamped child.rect with the
            // frame's clamped dimensions. Render passes the resolved
            // rect through unchanged.
            ctx.rect = child.rect
            render(child, into: &buffer, context: ctx)

        case .flexible:
            // The flex modifier itself doesn't transform the rect —
            // the parent stack's flex distribution already allocated
            // the right rect when it saw `.flexible(matchingAxis)` in
            // `isFlexChild` / `isVFlexChild`. Just render the wrapped
            // child into the rect we were given.
            render(child, into: &buffer, context: ctx)

        case .explicitID:
            render(child, into: &buffer, context: ctx)

        case .overlay:
            // Render base first, then overlay on top in same rect
            render(child, into: &buffer, context: ctx)
            if node.children.count > 1 {
                render(node.children[1], into: &buffer, context: ctx)
            }

        case .backgroundView:
            // Render background first, then base on top
            if node.children.count > 1 {
                render(node.children[1], into: &buffer, context: ctx)
            }
            render(child, into: &buffer, context: ctx)

        case .focusable:
            // isFocusable is set during graph construction (see below).
            // Just render the child — focus ring is drawn after main render pass.
            render(child, into: &buffer, context: ctx)

        case .focusScope:
            // Scope ids are stamped on focusable descendants during construction.
            // No visual effect — navigation-only modifier.
            render(child, into: &buffer, context: ctx)

        case .onKeyPress:
            // Handler is registered on FocusEngine during graph update,
            // not during rendering. Just pass through.
            render(child, into: &buffer, context: ctx)

        case .onAppear:
            render(child, into: &buffer, context: ctx)

        case .onChange:
            // Comparison + dispatch happens in the graph layer during update
            // (see `FocusGraphIntegration.fireLifecycleIfNeeded`). The
            // renderer is a pass-through.
            render(child, into: &buffer, context: ctx)

        case .onDisappear:
            // Removal-time hook — the closure is captured on the node and
            // invoked from `AttributeGraph` when the node leaves the tree.
            // The renderer is a pass-through.
            render(child, into: &buffer, context: ctx)

        case .onClick:
            render(child, into: &buffer, context: ctx)

        case .onHover:
            render(child, into: &buffer, context: ctx)

        case .onPaste:
            render(child, into: &buffer, context: ctx)

        case .actions:
            // ActionScope is captured on the modifier node during build
            // (see `FocusGraphIntegration.registerIfNeeded`). The
            // renderer is a pass-through; the input dispatcher walks
            // node._actionScope during event routing.
            render(child, into: &buffer, context: ctx)

        case .environment(let apply):
            // Push a modified EnvironmentValues for the duration of this
            // subtree. Descendants read via `GraphContext.currentEnvironment`
            // (e.g. `GraphMeasurer.computeHeight` consulting `textWrap`).
            // `withValue` automatically restores the prior binding on
            // closure exit so sibling subtrees observe their own
            // settings. The `withUnsafeMutablePointer` dance lets the
            // recursive `render` keep its `inout buffer` parameter
            // across the @TaskLocal closure boundary.
            var newEnv = GraphContext.currentEnvironment ?? EnvironmentValues()
            apply(&newEnv)
            withUnsafeMutablePointer(to: &buffer) { bufPtr in
                GraphContext.$currentEnvironment.withValue(newEnv) {
                    render(child, into: &bufPtr.pointee, context: ctx)
                }
            }

        case .modal(let isPresented):
            // Always render base app
            render(child, into: &buffer, context: ctx)

            // Defer the panel itself. It is a screen-level presentation, so
            // it must composite against the terminal buffer — not whatever
            // local buffer this subtree happens to be drawing into (a
            // ScrollView's content buffer, or another modal's layer).
            if isPresented, node.children.count > 1 {
                deferredPresentations.append(node)
            }
        }
    }

    /// Composite every presentation collected during the walk against the
    /// full-screen buffer, in declaration order so a modal presented from
    /// within a modal lands on top of it.
    private static func drainPresentations(into buffer: inout CellBuffer) {
        guard !deferredPresentations.isEmpty else { return }
        let pending = deferredPresentations
        deferredPresentations.removeAll(keepingCapacity: true)

        for node in pending {
            guard case .modifier(let effect) = node.kind,
                  case .modal = effect,
                  node.children.count > 1 else { continue }
            compositePresentation(node.children[1], effect: effect, into: &buffer)
        }
    }

    private static func compositePresentation(
        _ modalNode: AttributeNode,
        effect: ModifierEffect,
        into buffer: inout CellBuffer
    ) {
        let mw = measureWidth(modalNode)
        let mh = measureHeight(modalNode, proposedWidth: mw)
        let contentWidth = min(mw, buffer.width - 2)
        let contentHeight = min(mh, buffer.height - 2)
        guard contentWidth > 0, contentHeight > 0 else { return }

        #if DEBUG
        // Clipping a modal hides controls that stay focusable, so Tab can
        // reach buttons that were never drawn. Report it rather than letting
        // the dialog quietly lose its footer.
        if mw > contentWidth || mh > contentHeight {
            DebugStream.shared.emitWarning(
                .modalDoesNotFit,
                message: """
                    modal content \(mw)x\(mh) exceeds the \
                    \(buffer.width)x\(buffer.height) terminal and was \
                    clipped to \(contentWidth)x\(contentHeight); \
                    off-screen controls remain focusable
                    """,
                nodeID: String(describing: modalNode.id)
            )
        }
        #endif

        let mx = max(0, (buffer.width - contentWidth) / 2)
        let my = max(0, (buffer.height - contentHeight) / 2)

        let dimLayer = Layer(
            width: buffer.width, height: buffer.height,
            x: 0, y: 0,
            style: .dim(.ansi256(239))
        )

        var modalLayer = Layer(
            width: contentWidth, height: contentHeight,
            x: mx, y: my,
            // Style comes from the effect, not chosen here, so the renderer
            // cannot drift from the presentation's contract.
            style: effect.compositingStyle
        )
        let modalRect = Rect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        let modalContext = RenderContext(style: .plain, rect: modalRect)
        // Re-stamp the modal subtree's Layer-2 rects from (0, 0);
        // offsetRects(...) below translates to screen coords after the modal
        // layer is composited.
        Layout.measureAndPlace(graph: modalNode, in: modalRect)
        renderNode(modalNode, into: &modalLayer.buffer, context: modalContext)

        // Offset resolved rects so hit testing works in screen coordinates
        offsetRects(of: modalNode, dx: mx, dy: my)

        Compositor.composite(layers: [dimLayer, modalLayer], into: &buffer)
    }

    static func renderBorder(_ style: BorderStyle, into buffer: inout CellBuffer, context: RenderContext) {
        let r = context.rect
        guard r.width >= 2, r.height >= 2 else { return }

        let rx = r.x, ry = r.y, rw = r.width, rh = r.height

        buffer[rx, ry] = Cell(character: style.topLeft, style: context.style)
        buffer[rx + rw - 1, ry] = Cell(character: style.topRight, style: context.style)
        buffer[rx, ry + rh - 1] = Cell(character: style.bottomLeft, style: context.style)
        buffer[rx + rw - 1, ry + rh - 1] = Cell(character: style.bottomRight, style: context.style)

        for x in (rx + 1)..<(rx + rw - 1) {
            buffer[x, ry] = Cell(character: style.horizontal, style: context.style)
            buffer[x, ry + rh - 1] = Cell(character: style.horizontal, style: context.style)
        }

        for y in (ry + 1)..<(ry + rh - 1) {
            buffer[rx, y] = Cell(character: style.vertical, style: context.style)
            buffer[rx + rw - 1, y] = Cell(character: style.vertical, style: context.style)
        }
    }

    // MARK: - Measurement (delegated to GraphMeasurer)

    public static func measureWidth(_ node: AttributeNode) -> Int {
        GraphMeasurer.measureWidth(node)
    }

    public static func measureHeight(_ node: AttributeNode, proposedWidth: Int) -> Int {
        GraphMeasurer.measureHeight(node, proposedWidth: proposedWidth)
    }

    // MARK: - Focus Rendering

    /// Draw focus indicators after the main render pass.
    ///
    /// Style is read from the environment. Each of the four styles
    /// has different semantics:
    ///
    /// - `.overlay` — bar at `rect.x - 1` outside the focused view's rect.
    ///   Matches pre-behavior; top-level pass has no clip so the cell
    ///   adjacent to the focused view is overwritten (often a parent's
    ///   border/padding). Best visual for forms.
    /// - `.bar` — bar at `rect.x` INSIDE the focused view's first column.
    ///   Costs the view one cell of content width. Survives rect clipping.
    /// - `.prefix` — framework draws nothing. Views that own a `▸`-style
    ///   prefix (List) render their own focus visual.
    /// - `.none` — no indicator.
    ///
    /// Skips nodes inside scroll containers in `.overlay` mode — scroll
    /// content provides its own affordance and the bar fights with clipping.
    public static func renderFocusIndicators(into buffer: inout CellBuffer, focusEngine: FocusEngine, root: AttributeNode?) {
        guard let root else { return }

        let style = GraphContext.currentEnvironment?.focusIndicatorStyle ?? .overlay

        // Keyboard focus — cyan bar
        if let focusedID = focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: focusedID, in: root) {
            let focusStyle = Style(foreground: .cyan, background: nil, bold: true, italic: false, underline: false)
            drawIndicator(node: node, style: style, glyph: "▎", cellStyle: focusStyle,
                          into: &buffer, skipInScroll: true)
        }

        // Mouse hover — subtle underline bar (only if different from keyboard focus)
        if let hoverID = focusEngine.mouseHoverID,
           hoverID != focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: hoverID, in: root) {
            let hoverStyle = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)
            drawIndicator(node: node, style: style, glyph: "▏", cellStyle: hoverStyle,
                          into: &buffer, skipInScroll: true)
        }
    }

    /// Paint a single indicator according to the configured `FocusIndicatorStyle`.
    /// Called for both keyboard focus and mouse hover with different glyphs/styles.
    private static func drawIndicator(node: AttributeNode, style: FocusIndicatorStyle,
                                      glyph: Character, cellStyle: Style,
                                      into buffer: inout CellBuffer, skipInScroll: Bool) {
        switch style {
        case .none, .prefix:
            return

        case .overlay:
            // Outside the focused child's rect — one cell to the left.
            // Skip inside scroll containers: the scroll viewport's clipping
            // fights with indicator cells drawn outside the content area.
            if skipInScroll, scrollAncestorRect(of: node) != nil { return }
            // Same reasoning inside a presented modal, which is likewise a
            // bounded region: the cell left of the dialog's first column is
            // its border, so an outside-the-rect bar would punch a hole in
            // the frame. Fall back to `.bar`, which stays inside the rect
            // and is the style that already exists for exactly this
            // constraint — rather than dropping the indicator entirely and
            // leaving the focused control unmarked.
            if node.containmentDepth > 0 {
                drawIndicator(node: node, style: .bar, glyph: glyph,
                              cellStyle: cellStyle, into: &buffer,
                              skipInScroll: skipInScroll)
                return
            }
            let r = node.rect
            let drawX = r.x - 1
            guard drawX > 0 else { return }
            // Clamp to buffer bounds: focused node may have an off-screen
            // rect (e.g. after a layout rebuild where a child landed below
            // the viewport), in which case `r.y > buffer.height` inverts
            // the range and crashes. Same class of fix as CellBuffer.fill.
            let startY = max(0, min(r.y, buffer.height))
            let endY = max(startY, min(r.y + r.height, buffer.height))
            for y in startY..<endY {
                buffer[drawX, y] = Cell(character: glyph, style: cellStyle)
            }

        case .bar:
            // Inside the focused view's first column. No scroll-ancestor
            // exclusion needed — .bar is always inside the rect, so the
            // clip that enforces scroll viewports accepts it.
            let r = node.rect
            guard r.width > 0, r.x >= 0, r.x < buffer.width else { return }
            let startY = max(0, min(r.y, buffer.height))
            let endY = max(startY, min(r.y + r.height, buffer.height))
            for y in startY..<endY {
                buffer[r.x, y] = Cell(character: glyph, style: cellStyle)
            }
        }
    }

    /// Find the nearest scroll ancestor's viewport rect for clipping focus indicators.
    private static func scrollAncestorRect(of node: AttributeNode) -> Rect? {
        var current = node.parent
        while let p = current {
            if case .layout(let info) = p.kind, case .scroll = info.kind {
                return p.rect
            }
            current = p.parent
        }
        return nil
    }

    // MARK: - Rect Offset (for modal hit testing)

    /// Offset resolved rects of a subtree so hit testing works in screen coordinates.
    /// Modal content is rendered into a local buffer at (0,0) but composited at (dx,dy).
    static func offsetRects(of node: AttributeNode, dx: Int, dy: Int) {
        node.rect.x += dx
        node.rect.y += dy
        for child in node.children {
            offsetRects(of: child, dx: dx, dy: dy)
        }
    }
}
