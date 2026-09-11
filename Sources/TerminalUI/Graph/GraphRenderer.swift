/// The inherited drawing state a render walk carries into each node: the
/// ambient ``Style`` (modifiers accumulate into it on the way down) and the
/// rect the node may draw within.
public struct RenderContext {
    /// Ambient text style — foreground, background, and attributes inherited
    /// from enclosing modifiers.
    public var style: Style
    /// The cell region this node draws within, in buffer coordinates.
    public var rect: Rect

    /// Creates a context for a render walk — `.plain` style unless the
    /// caller is continuing an inherited chain.
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
                    case .truncate(let edge):
                        // One row, elision marked. Runs through
                        // `LineBreakMode` so the cell arithmetic that already
                        // handles wide graphemes is not reimplemented here.
                        chunks = [edge.lineBreakMode.apply(to: String(line), width: maxWidth)]
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
                // Styled path: write each span with its own resolved style.
                // Truncation happens on the run list rather than the joined
                // string so each surviving run keeps its own color — a status
                // row's icon, name and detail are three styles on one line.
                let mode = GraphContext.currentEnvironment?.textWrap ?? .wrap
                switch mode {
                case .truncate(let edge):
                    buffer.writeSpans(
                        TextLayout.truncate(spans, width: context.rect.width, edge: edge),
                        x: context.rect.x, y: context.rect.y,
                        maxWidth: context.rect.width, maxHeight: context.rect.height,
                        baseStyle: context.style, wrap: false)
                case .none:
                    buffer.writeSpans(spans, x: context.rect.x, y: context.rect.y,
                                      maxWidth: context.rect.width, maxHeight: context.rect.height,
                                      baseStyle: context.style, wrap: false)
                case .wrap:
                    // Wrapping is decided on the run list, not cell by cell, so
                    // a styled sentence breaks at the same words an unstyled one
                    // does — and at the same places the measurer counted.
                    let rows = TextLayout.wrap(spans, width: context.rect.width)
                    for (offset, row) in rows.enumerated() {
                        let y = context.rect.y + offset
                        guard y < context.rect.y + context.rect.height else { break }
                        buffer.writeSpans(row, x: context.rect.x, y: y,
                                          maxWidth: context.rect.width, maxHeight: 1,
                                          baseStyle: context.style, wrap: false)
                    }
                }
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
            renderVStack(children, info: info, into: &buffer, context: context)
        case .hstack:
            renderHStack(children, info: info, into: &buffer, context: context)
        case .zstack:
            renderZStack(children, info: info, into: &buffer, context: context)
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
    /// classified user-written VStacks nested inside composite-view bodies as
    /// structural — that broke Button-page arrow navigation, because the outer
    /// VStack holding the sibling Buttons was treated as transparent and the
    /// focus walk stepped past it. Now we read the explicit `isStructural`
    /// flag set at graph construction, so the distinction is reliable.
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

    static func renderVStack(_ children: [AttributeNode], info: LayoutInfo,
                             into buffer: inout CellBuffer, context: RenderContext) {
        let spacing = info.spacing
        let gaps = spacing * max(0, children.count - 1)
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

        // Gaps are spent before the flexible children divide what is left,
        // or a spacer would swallow the space the author asked to keep empty.
        let remaining = max(0, context.rect.height - totalContentHeight - gaps)
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
                    let width = vstackChildWidth(child, available: context.rect.width,
                                                 alignment: info.alignment.horizontal)
                    let childRect = Rect(
                        x: context.rect.x + info.alignment.horizontal.offset(for: width, in: context.rect.width),
                        y: y, width: width, height: max(1, flexHeight))
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
                if i < children.count - 1 { y += spacing }
                continue
            }
            let h = childHeights[i]
            let width = vstackChildWidth(child, available: context.rect.width,
                                         alignment: info.alignment.horizontal)
            let childRect = Rect(
                x: context.rect.x + info.alignment.horizontal.offset(for: width, in: context.rect.width),
                y: y, width: width, height: max(1, h))
            Layout.measureAndPlace(graph: child, in: childRect)
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            y += h
            if i < children.count - 1 { y += spacing }
        }
    }

    /// How wide a child sits across a `VStack`.
    ///
    /// A child that declared a width gets it. One that declared nothing fills
    /// the stack under the default alignment — `Divider` and every
    /// background-filling row depend on that — but asking for `.center` or
    /// `.trailing` is asking for the child to be *placed*, which is only
    /// meaningful once its own width is known, so that case measures.
    private static func vstackChildWidth(_ child: AttributeNode, available: Int,
                                         alignment: HorizontalAlignment) -> Int {
        if let declared = declaredWidth(of: child) { return max(1, min(available, declared)) }
        if fillsHorizontally(child) { return available }
        guard alignment != .leading else { return available }
        return max(1, min(available, measureWidth(child)))
    }

    /// Whether a child fills the width it is given whatever the stack's
    /// alignment says.
    ///
    /// Measuring a child is how alignment places it, but some children have a
    /// nominal measurement and draw across everything they are handed. A
    /// `Divider` measures one cell and rules its whole rect, so honouring that
    /// measurement under `.center` turned the rule into a single dash floating
    /// mid-stack; `.frame(maxWidth: .infinity)` is a request for all of it and
    /// cannot mean "centre me at my natural size".
    private static func fillsHorizontally(_ node: AttributeNode) -> Bool {
        if case .primitive(.divider) = node.kind { return true }
        return isFlexChild(node)
    }

    /// The vertical twin of `fillsHorizontally`.
    private static func fillsVertically(_ node: AttributeNode) -> Bool {
        isVFlexChild(node)
    }

    /// Vertical flex: spacers, vertical scroll views, `.flexible(.vertical)`,
    /// `.frame(maxHeight: .infinity)`, and `GeometryReader` all consume
    /// remaining height. A GeometryReader exists to be told its size — with
    /// no entry here a stack measured it instead, so it collapsed to its
    /// content's natural size, and any view whose body reads its size through
    /// one (`TreeView`) echoed the parent's extent back as a fixed measure
    /// and overflowed the stack.
    private static func isVFlexChild(_ node: AttributeNode) -> Bool {
        if node.geometryRebuilder != nil { return true }
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.vertical) = info.kind { return true }
        if case .modifier(.flexible(let axes, _)) = node.kind, axes.contains(.vertical) { return true }
        if case .modifier(.frame(_, _, _, _, _, let maxH, _)) = node.kind, maxH == .infinity { return true }
        if let child = flexBearingChild(of: node) { return isVFlexChild(child) }
        return false
    }

    /// A child's own size, placed inside `available` by `alignment`.
    private static func placedRect(of node: AttributeNode, in available: Rect,
                                   alignment: Alignment) -> Rect {
        let width = min(available.width, declaredWidth(of: node) ?? measureWidth(node))
        let height = min(available.height,
                         declaredHeight(of: node)
                            ?? measureHeight(node, proposedWidth: max(1, width)))
        return Rect(
            x: available.x + alignment.horizontal.offset(for: width, in: available.width),
            y: available.y + alignment.vertical.offset(for: height, in: available.height),
            width: max(1, width), height: max(1, height)
        )
    }

    /// The width a subtree explicitly asked for, or nil when it asked for
    /// nothing and should take what the stack offers.
    ///
    /// A stack owns its main axis and hands out measured extents there, but it
    /// used to hand every child the *whole* of its cross axis — so
    /// `.frame(width: 8).border()` in a VStack drew its box at the stack's
    /// width and only the text inside reflowed. Insets add themselves on the
    /// way out, because that view occupies ten cells, not eight.
    ///
    /// Only an explicit request shrinks a child. A view that asked for nothing
    /// still fills the cross axis, which is what `Divider` and every
    /// background-filling row rely on.
    static func declaredWidth(of node: AttributeNode) -> Int? {
        declaredExtent(of: node, horizontal: true)
    }

    /// The height twin of `declaredWidth` — an HStack's cross axis.
    static func declaredHeight(of node: AttributeNode) -> Int? {
        declaredExtent(of: node, horizontal: false)
    }

    private static func declaredExtent(of node: AttributeNode, horizontal: Bool) -> Int? {
        guard case .modifier(let effect) = node.kind else { return nil }
        let child = node.children.first
        func inner() -> Int? { child.flatMap { declaredExtent(of: $0, horizontal: horizontal) } }

        switch effect {
        case .frame(let width, let height, _, _, _, _, _):
            if let explicit = horizontal ? width : height { return explicit }
            return inner()
        case .padding(let amount):
            return inner().map { $0 + amount * 2 }
        case .border(_, _, let edges):
            return inner().map { $0 + (horizontal ? edges.horizontalInset : edges.verticalInset) }
        case .flexible(let axes, _):
            // Asked for the space rather than a size, so it is not fixed on
            // that axis — but may still be fixed on the other one.
            let claimsAxis = horizontal ? axes.contains(.horizontal) : axes.contains(.vertical)
            return claimsAxis ? nil : inner()
        // A presentation carries a second subtree whose size is not the base
        // view's to report.
        case .overlay, .backgroundView, .modal:
            return nil
        default:
            return inner()
        }
    }

    /// The child whose flexibility this node inherits, or nil when the node
    /// decides its own size.
    ///
    /// Flexibility is a property of what a subtree *is*, not of the node that
    /// happens to sit on top of it. Reading it off one node's kind stopped at
    /// the first wrapper: a scroll view behind `.environment(...)` collapsed to
    /// one row, a scroll view behind `.border()` took its full natural height
    /// and painted over its siblings, and a composite view whose `body` is a
    /// scroll view — every `Form` — did the same. Three shapes, one missing
    /// rule.
    ///
    /// A `.frame` with an explicit dimension does decide, which is why it is
    /// absent here and why `.frame(height:)` remains the way to bound a
    /// scroll view against a greedy one.
    private static func flexBearingChild(of node: AttributeNode) -> AttributeNode? {
        switch node.kind {
        // A composite view is its body.
        case .viewBody:
            return node.children.first
        case .modifier(let effect):
            switch effect {
            // Painting, lifecycle, focus and dispatch impose no size at all;
            // insets add their own cells around whatever they are given
            // without choosing how much that is.
            case .foreground, .background, .bold, .italic, .underline,
                 .focusable, .focusScope,
                 .onKeyPress, .onAppear, .onChange, .onDisappear,
                 .onClick, .onHover, .onPaste,
                 .actions, .environment, .explicitID,
                 .padding, .border, .task:
                return node.children.first
            // A frame and `.flexible` state a size on their own behalf; the
            // presentation shapes carry a second subtree whose flexibility is
            // not the base view's to inherit. Listed rather than defaulted so
            // a new effect has to answer this question.
            case .frame, .flexible, .overlay, .backgroundView, .modal:
                return nil
            }
        default:
            return nil
        }
    }

    /// Grow weight for a vertical flex child. Spacers, scroll views,
    /// and `.frame(maxHeight: .infinity)` all weight at 1; only
    /// `.flexible(grow:)` exposes a non-default weight.
    private static func vFlexGrow(_ node: AttributeNode) -> Int {
        if case .modifier(.flexible(_, let grow)) = node.kind { return grow }
        return 1
    }

    /// Column width an `HStack` allocates to each child, in child order.
    ///
    /// Shared by the render walk and by `GraphMeasurer`'s height pass. The
    /// measurer needs it because a child's height depends on the width it
    /// is *actually* given: asking a wrapping `Text` how tall it is at the
    /// stack's full width under-reports it by a row whenever the text fits
    /// the unspaced width but not the width left after siblings and gaps.
    /// The parent then reserves one row too few and the wrap's last line is
    /// clipped. Keeping one implementation is what stops the two passes
    /// disagreeing again.
    ///
    /// Widths are pre-clamp: callers walking left-to-right still have to
    /// clamp against the space actually remaining, as both do.
    static func hstackChildWidths(_ children: [AttributeNode], info: LayoutInfo,
                                  availableWidth: Int) -> [Int] {
        let gaps = info.spacing * max(0, children.count - 1)
        // Identify flex children + their grow weights. Spacers, scroll
        // views, `.flexible(.horizontal)`, and `.frame(maxWidth: .infinity)`
        // all qualify; only `.flexible(grow:)` carries a non-default weight.
        var flexIndices: [Int] = []
        var flexWeights: [Int] = []
        var childWidths: [Int] = []
        var totalContentWidth = 0
        for (i, child) in children.enumerated() {
            if isFlexChild(child) {
                flexIndices.append(i)
                flexWeights.append(flexGrow(child))
                childWidths.append(0)
            } else {
                let w = measureWidth(child)
                childWidths.append(w)
                totalContentWidth += w
            }
        }

        // See the vertical twin: gaps come out before flex divides the rest.
        let remaining = max(0, availableWidth - totalContentWidth - gaps)
        let perFlex = weightedDistribution(weights: flexWeights, available: remaining)
        for (slot, idx) in flexIndices.enumerated() {
            childWidths[idx] = perFlex[slot]
        }
        return childWidths
    }

    static func renderHStack(_ children: [AttributeNode], info: LayoutInfo,
                             into buffer: inout CellBuffer, context: RenderContext) {
        let spacing = info.spacing
        let childWidths = hstackChildWidths(children, info: info,
                                            availableWidth: context.rect.width)

        let maxX = context.rect.x + context.rect.width
        var x = context.rect.x
        for (i, child) in children.enumerated() {
            if x >= maxX { break }
            if isFlexChild(child) {
                let flexWidth = childWidths[i]
                // Spacers just consume space; scroll views and other
                // flex-marked children render into the allocated rect.
                if case .primitive(.spacer) = child.kind {
                    x += flexWidth
                } else {
                    let height = hstackChildHeight(child, available: context.rect.height,
                                                   proposedWidth: max(1, flexWidth),
                                                   alignment: info.alignment.vertical)
                    let childRect = Rect(
                        x: x,
                        y: context.rect.y + info.alignment.vertical.offset(for: height, in: context.rect.height),
                        width: max(1, flexWidth), height: height)
                    Layout.measureAndPlace(graph: child, in: childRect)
                    render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
                    x += flexWidth
                }
                if i < children.count - 1 { x += spacing }
                continue
            }
            let w = childWidths[i]
            let clampedWidth = min(w, maxX - x)
            let height = hstackChildHeight(child, available: context.rect.height,
                                           proposedWidth: max(1, clampedWidth),
                                           alignment: info.alignment.vertical)
            let childRect = Rect(
                x: x,
                y: context.rect.y + info.alignment.vertical.offset(for: height, in: context.rect.height),
                width: max(1, clampedWidth), height: height)
            Layout.measureAndPlace(graph: child, in: childRect)
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            x += w
            if i < children.count - 1 { x += spacing }
        }
    }

    /// The vertical twin of `vstackChildWidth` — how tall a child sits across
    /// an `HStack`. Height needs the child's own width to measure against,
    /// since wrapping makes it width-dependent.
    private static func hstackChildHeight(_ child: AttributeNode, available: Int,
                                          proposedWidth: Int,
                                          alignment: VerticalAlignment) -> Int {
        if let declared = declaredHeight(of: child) { return max(1, min(available, declared)) }
        if fillsVertically(child) { return available }
        guard alignment != .top else { return available }
        return max(1, min(available, measureHeight(child, proposedWidth: proposedWidth)))
    }

    /// A child is "flex" if it should consume remaining space in a stack layout.
    /// Spacers, horizontal scroll views, `.flexible(.horizontal)`,
    /// `.frame(maxWidth: .infinity)`, and `GeometryReader` all qualify in
    /// HStacks — see `isVFlexChild` for why the reader is here.
    private static func isFlexChild(_ node: AttributeNode) -> Bool {
        if node.geometryRebuilder != nil { return true }
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.horizontal) = info.kind { return true }
        if case .modifier(.flexible(let axes, _)) = node.kind, axes.contains(.horizontal) { return true }
        if case .modifier(.frame(_, _, _, let maxW, _, _, _)) = node.kind, maxW == .infinity { return true }
        if let child = flexBearingChild(of: node) { return isFlexChild(child) }
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
        // Claimed below only if a track is actually painted; a pane whose
        // content fits must not swallow clicks meant for what is under it.
        node.scrollAffordanceRect = nil

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

            // See the vertical branch: drawn, not declared.
            let drawnWidth = lastDrawnColumn(in: contentBuffer).map { $0 + 1 } ?? 0
            node.scrollDrawnExtent = drawnWidth

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
                if drawnWidth > offset + viewport.width {
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
                                              content: drawnWidth,
                                              offset: offset) {
                    let trackY = viewport.y + viewport.height - 1
                    node.scrollAffordanceRect = Rect(x: viewport.x, y: trackY,
                                                     width: viewport.width, height: 1)
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

            // What the content draws, not what it declares. The affordances
            // below answer "is there more to see", and rows padded out by a
            // fixed frame or a trailing spacer are not more to see: a list
            // sitting on its last row kept promising ▼ and kept scrolling into
            // blank space, which reads as a stuck pane rather than as an end.
            let drawnHeight = lastDrawnRow(in: contentBuffer).map { $0 + 1 } ?? 0
            node.scrollDrawnExtent = drawnHeight

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
                if drawnHeight > offset + viewport.height {
                    buffer[viewport.x + viewport.width - 1, viewport.y + viewport.height - 1] = Cell(character: "▼", style: indicatorStyle)
                }

                // Vertical thumb-track on the rightmost column. │ track
                // top-to-bottom, █ thumb at the proportional start. Painted
                // BEFORE the ▲/▼ edge glyphs above so those still win at
                // the corners; thumb skips its track cells where the
                // edge-glyph already sits. Skipped when content fits
                // (scrollbarThumb returns nil).
                if let thumb = scrollbarThumb(viewport: viewport.height,
                                              content: drawnHeight,
                                              offset: offset) {
                    let trackX = viewport.x + viewport.width - 1
                    node.scrollAffordanceRect = Rect(x: trackX, y: viewport.y,
                                                     width: 1, height: viewport.height)
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
                            && drawnHeight > offset + viewport.height
                        if isTopGlyph || isBottomGlyph { continue }
                        buffer[trackX, trackY] = Cell(character: "│", style: trackStyle)
                    }
                    for i in 0..<thumb.length {
                        let y = thumb.start + i
                        let trackY = viewport.y + y
                        let isTopGlyph = y == 0 && offset > 0
                        let isBottomGlyph = y == viewport.height - 1
                            && drawnHeight > offset + viewport.height
                        if isTopGlyph || isBottomGlyph { continue }
                        buffer[trackX, trackY] = Cell(character: "█", style: thumbStyle)
                    }
                }
            }
        }
    }

    /// Mark a view that sits flush against the left edge by inverting its
    /// first column: the focus colour becomes the background, so the cell
    /// reads as a marked cell while the character it holds survives.
    private static func highlightFirstColumn(of node: AttributeNode, style: Style,
                                             into buffer: inout CellBuffer) {
        let rect = node.rect
        guard rect.width > 0, rect.x >= 0, rect.x < buffer.width else { return }
        let startY = max(0, min(rect.y, buffer.height))
        let endY = max(startY, min(rect.y + rect.height, buffer.height))
        let marked = Style(foreground: .black, background: style.foreground,
                           bold: style.bold, italic: false, underline: false)
        for y in startY..<endY {
            buffer[rect.x, y] = Cell(character: buffer[rect.x, y].character, style: marked)
        }
    }

    /// The last row of a freshly rendered content buffer that drew anything,
    /// or nil when nothing did. Scans upward, so the common case — content
    /// that fills its buffer — stops on the first row it looks at.
    private static func lastDrawnRow(in buffer: CellBuffer) -> Int? {
        for y in stride(from: buffer.height - 1, through: 0, by: -1) {
            for x in 0..<buffer.width where buffer[x, y] != .empty {
                return y
            }
        }
        return nil
    }

    /// The horizontal twin of `lastDrawnRow`.
    private static func lastDrawnColumn(in buffer: CellBuffer) -> Int? {
        for x in stride(from: buffer.width - 1, through: 0, by: -1) {
            for y in 0..<buffer.height where buffer[x, y] != .empty {
                return x
            }
        }
        return nil
    }

    static func renderZStack(_ children: [AttributeNode], info: LayoutInfo,
                             into buffer: inout CellBuffer, context: RenderContext) {
        // Layer 2: Layout stamps every ZStack child's rect to the parent's
        // rect. Render reads the pre-stamped rect — last child wins on
        // overlapping cells.
        //
        // Under the default `.topLeading` that is the whole story. Any other
        // alignment means placing children, which needs each one's own size,
        // so those measure and re-stamp.
        let alignment = info.alignment
        for child in children {
            var childCtx = context
            childCtx.rect = child.rect
            if alignment != .topLeading {
                let width = min(context.rect.width,
                                declaredWidth(of: child) ?? measureWidth(child))
                let height = min(context.rect.height,
                                 declaredHeight(of: child)
                                    ?? measureHeight(child, proposedWidth: max(1, width)))
                childCtx.rect = Rect(
                    x: context.rect.x + alignment.horizontal.offset(for: width, in: context.rect.width),
                    y: context.rect.y + alignment.vertical.offset(for: height, in: context.rect.height),
                    width: max(1, width), height: max(1, height))
                Layout.measureAndPlace(graph: child, in: childCtx.rect)
            }
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

        case .border(let style, let color, let edges):
            // Border edges draw at the modifier node's OUTER rect
            // (`ctx.rect`); the child draws inside the inset rect
            // that Layout already stamped on `child.rect`.
            renderBorder(style, color: color, edges: edges, into: &buffer, context: ctx)
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

        case .overlay(let alignment):
            // Base first, then the overlay over it. `.topLeading` keeps the
            // original behaviour of handing the overlay the base's whole rect;
            // any other alignment is a request to *place* it, which needs its
            // own size — a badge pinned `.topTrailing` is the case this exists
            // for.
            render(child, into: &buffer, context: ctx)
            if node.children.count > 1 {
                let overlay = node.children[1]
                var overlayCtx = ctx
                if alignment != .topLeading {
                    // Aligned within the *base view's* frame, not the rect the
                    // parent happened to hand down. A stack gives its children
                    // the full cross axis, so aligning against that would pin a
                    // badge to the screen edge rather than to the thing it
                    // belongs to.
                    let baseWidth = min(ctx.rect.width, measureWidth(child))
                    let baseHeight = min(ctx.rect.height,
                                         measureHeight(child, proposedWidth: max(1, baseWidth)))
                    let base = Rect(x: ctx.rect.x, y: ctx.rect.y,
                                    width: max(1, baseWidth), height: max(1, baseHeight))
                    overlayCtx.rect = placedRect(of: overlay, in: base, alignment: alignment)
                    Layout.measureAndPlace(graph: overlay, in: overlayCtx.rect)
                }
                render(overlay, into: &buffer, context: overlayCtx)
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

        case .task:
            // The work is started on the node during construct/update and
            // cancelled when the node leaves the tree; drawing is unaffected.
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

    static func renderBorder(_ style: BorderStyle, color: Color?, edges: BorderEdges,
                             into buffer: inout CellBuffer, context: RenderContext) {
        let r = context.rect
        guard !edges.isEmpty, r.width >= 1, r.height >= 1 else { return }
        // A full ring needs room for two opposite edges plus something between;
        // a single edge only needs the one cell it occupies. Guarding on 2x2
        // regardless would silently drop every rail in a one-column frame.
        guard r.width >= edges.horizontalInset, r.height >= edges.verticalInset else { return }

        // A nil colour inherits the surrounding foreground, which is what
        // `.border()` has always done. A supplied colour states the frame
        // independently of its content — the whole point of the parameter.
        var glyphStyle = context.style
        if let color { glyphStyle.foreground = color }

        let rx = r.x, ry = r.y, rw = r.width, rh = r.height
        let maxX = rx + rw - 1, maxY = ry + rh - 1

        let hasTop = edges.contains(.top), hasBottom = edges.contains(.bottom)
        let hasLeading = edges.contains(.leading), hasTrailing = edges.contains(.trailing)

        // Corners belong to whichever edges meet there. With both present the
        // corner glyph joins them; with one, that edge simply runs through, so
        // a lone `.top` is an unbroken rule rather than a rule with corner
        // pieces stuck on its ends.
        func corner(_ both: Character, vertical: Bool, horizontal: Bool) -> Character? {
            switch (vertical, horizontal) {
            case (true, true): both
            case (true, false): style.vertical
            case (false, true): style.horizontal
            case (false, false): nil
            }
        }

        if let glyph = corner(style.topLeft, vertical: hasLeading, horizontal: hasTop) {
            buffer[rx, ry] = Cell(character: glyph, style: glyphStyle)
        }
        if let glyph = corner(style.topRight, vertical: hasTrailing, horizontal: hasTop) {
            buffer[maxX, ry] = Cell(character: glyph, style: glyphStyle)
        }
        if let glyph = corner(style.bottomLeft, vertical: hasLeading, horizontal: hasBottom) {
            buffer[rx, maxY] = Cell(character: glyph, style: glyphStyle)
        }
        if let glyph = corner(style.bottomRight, vertical: hasTrailing, horizontal: hasBottom) {
            buffer[maxX, maxY] = Cell(character: glyph, style: glyphStyle)
        }

        // Runs between the corners. The ranges are empty when the rect is only
        // as wide or tall as its own corners, so no bounds guard is needed.
        if hasTop || hasBottom {
            for x in (rx + 1)..<max(rx + 1, maxX) {
                if hasTop { buffer[x, ry] = Cell(character: style.horizontal, style: glyphStyle) }
                if hasBottom { buffer[x, maxY] = Cell(character: style.horizontal, style: glyphStyle) }
            }
        }
        if hasLeading || hasTrailing {
            for y in (ry + 1)..<max(ry + 1, maxY) {
                if hasLeading { buffer[rx, y] = Cell(character: style.vertical, style: glyphStyle) }
                if hasTrailing { buffer[maxX, y] = Cell(character: style.vertical, style: glyphStyle) }
            }
        }
    }

    // MARK: - Measurement (delegated to GraphMeasurer)

    /// The subtree's natural width in cells — the measurement pass stacks
    /// use to size fixed children before flex distribution.
    public static func measureWidth(_ node: AttributeNode) -> Int {
        GraphMeasurer.measureWidth(node)
    }

    /// The subtree's natural height in cells at the proposed width —
    /// height is width-dependent because text wraps.
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

        // `.focusIndicator(_:)` is written on a view, so it is read from the
        // view it was written on. Asking the ambient environment instead meant
        // the modifier only ever worked applied globally, and a pane that
        // draws its own focus visual could not opt out of the bar — the same
        // `_resolvedEnv` rule `allowArrowFocusNavigation` and the boundary
        // policy already follow, for the same reason: the TaskLocal binding is
        // bound during a frame's render walk, and this pass runs after it.
        let ambient = GraphContext.currentEnvironment?.focusIndicatorStyle ?? .overlay
        func style(for node: AttributeNode) -> FocusIndicatorStyle {
            node._resolvedEnv?.focusIndicatorStyle ?? ambient
        }

        // Keyboard focus — cyan bar
        if let focusedID = focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: focusedID, in: root) {
            // A row you can read but not operate says so in its cursor, and
            // says it twice: a lighter glyph as well as a quieter colour.
            // Colour alone is not a signal (HIG, Accessibility: "Don't convey
            // information using color alone"), and this distinction is the
            // only thing telling the user why Enter does nothing here.
            let readOnly = node.isReadOnlyFocus
            let focusStyle = Style(foreground: readOnly ? .gray : .cyan, background: nil,
                                   bold: !readOnly, italic: false, underline: false)
            drawIndicator(node: node, style: style(for: node), glyph: readOnly ? "┆" : "▎",
                          cellStyle: focusStyle, into: &buffer, skipInScroll: true)
        }

        // Mouse hover — subtle underline bar (only if different from keyboard focus)
        if let hoverID = focusEngine.mouseHoverID,
           hoverID != focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: hoverID, in: root) {
            let hoverStyle = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)
            drawIndicator(node: node, style: style(for: node), glyph: "▏", cellStyle: hoverStyle,
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
            // Outside the focused child's rect — one cell to the left, in the
            // padding a bordered pane already has.
            //
            // A scroll container used to disqualify the node outright. The
            // concern was real but stated too broadly: what fights with a
            // viewport is a bar drawn for a row that has scrolled *out* of it,
            // not the existence of a scroll ancestor. Since every `Form`
            // composes a `ScrollView`, the broad rule left every control in
            // every form unmarked — the focused row was the one thing on
            // screen with nothing to say it had focus. The viewport is a clip
            // below instead.
            let viewport = skipInScroll ? scrollAncestorRect(of: node) : nil
            // A presented modal is a bounded region too, but only its edge
            // cells are at risk: writing left of a control flush against the
            // dialog frame would punch a hole in the border. One cell in from
            // that — ordinary padding — is free, and using it preserves the
            // control's own first column. That matters because `.bar` draws
            // *inside* the rect, so a focused `Button` (`[ label ]`) would
            // otherwise render as `▎ label ]` with its opening bracket gone.
            // Fall back to `.bar` only when the adjacent cell is not blank,
            // rather than dropping the indicator and leaving the control
            // unmarked.
            if node.containmentDepth > 0, !isBlankCellLeftOf(node, in: buffer) {
                drawIndicator(node: node, style: .bar, glyph: glyph,
                              cellStyle: cellStyle, into: &buffer,
                              skipInScroll: skipInScroll)
                return
            }
            let r = node.rect
            let drawX = r.x - 1
            // Column 0 is a cell like any other; refusing it left a view one
            // cell in with no mark at all. A view flush against the left edge
            // has no cell outside itself to use, so it marks its own first
            // column instead — the same fallback the modal-edge case takes.
            // Focus that is nowhere reads as a key that did nothing, and the
            // stop outside a detail pane is exactly where that happens: Tab
            // out of a form looked like a form that traps Tab.
            guard drawX >= 0 else {
                // Nothing outside the view to mark, so mark the view's own
                // first column — by restyling it, not by drawing over it. The
                // glyph would cost the row its first character, and the first
                // character of a row is a letter of the word the user is
                // reading: `Account` marked this way renders as `▎ccount`.
                highlightFirstColumn(of: node, style: cellStyle, into: &buffer)
                return
            }
            // A row scrolled sideways out of its viewport would put the bar in
            // whatever pane sits to the left of this one.
            if let viewport, drawX < viewport.x - 1 { return }
            // Clamp to buffer bounds: focused node may have an off-screen
            // rect (e.g. after a layout rebuild where a child landed below
            // the viewport), in which case `r.y > buffer.height` inverts
            // the range and crashes. Same class of fix as CellBuffer.fill.
            // Inside a scroll container the viewport clamps too, so the part
            // of a half-scrolled row that is drawn is the part that is marked.
            let topLimit = max(0, viewport?.y ?? 0)
            let bottomLimit = min(buffer.height, viewport.map { $0.y + $0.height } ?? buffer.height)
            let startY = max(topLimit, min(r.y, bottomLimit))
            let endY = max(startY, min(r.y + r.height, bottomLimit))
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

    /// Whether every cell immediately left of `node`'s rect is blank, i.e. the
    /// indicator can be drawn there without overwriting a border, a sibling,
    /// or a parent's chrome. Checked against what has already been composited
    /// rather than inferred from the tree — the neighbouring cell may belong
    /// to any ancestor, and the rendered buffer is the only place that is
    /// known for certain.
    private static func isBlankCellLeftOf(_ node: AttributeNode, in buffer: CellBuffer) -> Bool {
        let r = node.rect
        let x = r.x - 1
        guard x >= 0, x < buffer.width else { return false }
        let startY = max(0, min(r.y, buffer.height))
        let endY = max(startY, min(r.y + r.height, buffer.height))
        guard startY < endY else { return false }
        for y in startY..<endY where buffer[x, y].character != " " {
            return false
        }
        return true
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
