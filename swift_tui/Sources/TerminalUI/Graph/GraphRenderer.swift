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

    public static func render(_ node: AttributeNode, into buffer: inout CellBuffer, context: RenderContext) {
        // Record resolved rect on every node — used for hit testing
        node.rect = context.rect

        #if DEBUG
        DevTracer.shared.traceLayoutPlace(node.kind.debugName, rect: context.rect)
        #endif

        // Propagate proposed size to this node's subtree so `GeometryReader`
        // reports the actual allocated rect rather than the root terminal
        // size. Without this, a `GeometryReader` inside a narrow nested
        // layout would still think it had the whole screen to work with —
        // the bug that left `TextInput` over-budgeting its horizontal
        // scroll window in the Storybook preview pane.
        let previousProposed = GraphContext.currentProposedSize
        GraphContext.currentProposedSize = Size(width: context.rect.width, height: context.rect.height)
        defer { GraphContext.currentProposedSize = previousProposed }

        // Rect-clip enforcement (HYP-90). Every node's writes are bounded to its
        // assigned rect intersected with all ancestors' rects. Prevents a child
        // from punching through a parent's border/frame when it miscalculates
        // measurement or paints past its bounds. Opt out with `.overflowOK()`.
        buffer.withClip(context.rect) { buffer in
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
                // GeometryReader rebuild path: if the node carries a
                // `geometryRebuilder` closure, invoke it with the actual
                // rect size so the subtree is constructed AFTER layout has
                // been assigned. The rebuilder captures its owning graph
                // and returns a freshly-constructed child node; we re-parent
                // it and replace any previous build.
                if let rebuild = node.geometryRebuilder {
                    let size = Size(width: context.rect.width, height: context.rect.height)
                    let newChild = rebuild(size)
                    newChild.parent = node
                    node.children = [newChild]
                }
                for child in node.children {
                    render(child, into: &buffer, context: context)
                }
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
                let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
                let maxWidth = context.rect.width
                for (i, line) in lines.enumerated() {
                    let y = context.rect.y + i
                    guard y < context.rect.y + context.rect.height else { break }
                    // Pad to rect width with spaces so the trailing region is
                    // cleared when content shrank from a longer previous frame
                    // (HYP-84 — "epsilone" → "epsilon" stale-cell bug). The
                    // HYP-90 rect clip keeps the padding within the rect even
                    // if the shape is oddly sized.
                    let clipped = line.count > maxWidth ? String(line.prefix(maxWidth)) : String(line)
                    let padCount = max(0, maxWidth - clipped.count)
                    let padded = clipped + String(repeating: " ", count: padCount)
                    buffer.write(padded, x: context.rect.x, y: y, style: context.style)
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
        }
    }

    // MARK: - Layout

    static func renderLayout(_ node: AttributeNode, info: LayoutInfo, into buffer: inout CellBuffer, context: RenderContext) {
        // Flatten structural children (ForEach/TupleView layout nodes) so their
        // children participate directly in the parent's layout axis.
        // Graph identity nodes are preserved — only the renderer sees through them.
        let children = effectiveChildren(of: node)
        guard !children.isEmpty else { return }

        // Clear-before-layout to prevent shrunk-content bleed (HYP-84).
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

    static func renderVStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        var flexCount = 0
        for child in children {
            if isVFlexChild(child) { flexCount += 1 }
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
        var (flexBase, flexRemainder) = spacerDistribution(spacerCount: flexCount, available: remaining)

        var y = context.rect.y
        for (i, child) in children.enumerated() {
            if isVFlexChild(child) {
                let flexHeight = consumeSpacer(base: flexBase, remainder: &flexRemainder)
                if case .primitive(.spacer) = child.kind {
                    y += flexHeight
                } else {
                    let childRect = Rect(x: context.rect.x, y: y,
                                         width: context.rect.width, height: max(1, flexHeight))
                    render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
                    y += flexHeight
                }
                continue
            }
            let h = childHeights[i]
            let childRect = Rect(x: context.rect.x, y: y, width: context.rect.width, height: max(1, h))
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            y += h
        }
    }

    /// Vertical flex: spacers and vertical scroll views consume remaining height.
    private static func isVFlexChild(_ node: AttributeNode) -> Bool {
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.vertical) = info.kind { return true }
        return false
    }

    static func renderHStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        // Count flex children: spacers and horizontal scroll views both consume remaining space
        var flexCount = 0
        for child in children {
            if isFlexChild(child) { flexCount += 1 }
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
        var (flexBase, flexRemainder) = spacerDistribution(spacerCount: flexCount, available: remaining)

        let maxX = context.rect.x + context.rect.width
        var x = context.rect.x
        for (i, child) in children.enumerated() {
            if x >= maxX { break }
            if isFlexChild(child) {
                let flexWidth = consumeSpacer(base: flexBase, remainder: &flexRemainder)
                // Spacers just consume space; scroll views render into the flex allocation
                if case .primitive(.spacer) = child.kind {
                    x += flexWidth
                } else {
                    let childRect = Rect(x: x, y: context.rect.y,
                                         width: max(1, flexWidth), height: context.rect.height)
                    render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
                    x += flexWidth
                }
                continue
            }
            let w = childWidths[i]
            let clampedWidth = min(w, maxX - x)
            let childRect = Rect(x: x, y: context.rect.y, width: max(1, clampedWidth), height: context.rect.height)
            render(child, into: &buffer, context: RenderContext(style: context.style, rect: childRect))
            x += w
        }
    }

    /// A child is "flex" if it should consume remaining space in a stack layout.
    /// Spacers and scroll views (in the matching axis) are flex children.
    private static func isFlexChild(_ node: AttributeNode) -> Bool {
        if case .primitive(.spacer) = node.kind { return true }
        if case .layout(let info) = node.kind, case .scroll(.horizontal) = info.kind { return true }
        return false
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
    /// (HYP-83). Indicator visibility is controlled by the `scrollIndicators`
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
                // (HYP-82 #8).
                let indicatorStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                if offset > 0 {
                    buffer[viewport.x, viewport.y] = Cell(character: "◀", style: indicatorStyle)
                }
                if contentWidth > offset + viewport.width {
                    buffer[viewport.x + viewport.width - 1, viewport.y] = Cell(character: "▶", style: indicatorStyle)
                }
            }

        case .vertical:
            let contentHeight = measureHeight(contentChild, proposedWidth: viewport.width)
            guard contentHeight > 0, viewport.width > 0, viewport.height > 0 else { return }

            var contentBuffer = CellBuffer(width: viewport.width, height: contentHeight)
            let contentRect = Rect(x: 0, y: 0, width: viewport.width, height: contentHeight)
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
                // (HYP-82 #8).
                let indicatorStyle = Style(foreground: .cyan, background: nil,
                                           bold: true, italic: false, underline: false)
                if offset > 0 {
                    buffer[viewport.x + viewport.width - 1, viewport.y] = Cell(character: "▲", style: indicatorStyle)
                }
                if contentHeight > offset + viewport.height {
                    buffer[viewport.x + viewport.width - 1, viewport.y + viewport.height - 1] = Cell(character: "▼", style: indicatorStyle)
                }
            }
        }
    }

    static func renderZStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        // All children occupy the full rect — last child renders on top
        for child in children {
            render(child, into: &buffer, context: context)
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

        case .padding(let amount):
            ctx.rect = ctx.rect.inset(by: amount)
            render(child, into: &buffer, context: ctx)

        case .border(let style):
            renderBorder(style, into: &buffer, context: ctx)
            ctx.rect = ctx.rect.inset(by: 1)
            render(child, into: &buffer, context: ctx)

        case .frame(let width, let height, let minWidth, let maxWidth, let minHeight, let maxHeight):
            if let w = width { ctx.rect.width = min(w, ctx.rect.width) }
            if let maxW = maxWidth { ctx.rect.width = min(maxW, ctx.rect.width) }
            if let minW = minWidth { ctx.rect.width = max(minW, ctx.rect.width) }
            if let h = height { ctx.rect.height = min(h, ctx.rect.height) }
            if let maxH = maxHeight { ctx.rect.height = min(maxH, ctx.rect.height) }
            if let minH = minHeight { ctx.rect.height = max(minH, ctx.rect.height) }
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

        case .environment(let apply):
            // Push a modified EnvironmentValues for the duration of this
            // subtree. Descendants read via `GraphContext.currentEnvironment`
            // (e.g. `GraphMeasurer.computeHeight` consulting `textWrap`).
            // Restore the prior environment on return so sibling subtrees
            // observe their own settings rather than inheriting from us.
            let previousEnv = GraphContext.currentEnvironment
            var newEnv = previousEnv ?? EnvironmentValues()
            apply(&newEnv)
            GraphContext.currentEnvironment = newEnv
            render(child, into: &buffer, context: ctx)
            GraphContext.currentEnvironment = previousEnv

        case .modal(let isPresented):
            // Always render base app
            render(child, into: &buffer, context: ctx)

            if isPresented, node.children.count > 1 {
                let modalNode = node.children[1]

                // Measure modal content
                let mw = measureWidth(modalNode)
                let mh = measureHeight(modalNode, proposedWidth: mw)
                let contentWidth = min(mw, buffer.width - 2)
                let contentHeight = min(mh, buffer.height - 2)

                // Center on screen
                let mx = max(0, (buffer.width - contentWidth) / 2)
                let my = max(0, (buffer.height - contentHeight) / 2)

                // Use compositor: dim layer + modal layer
                let dimLayer = Layer(
                    width: buffer.width, height: buffer.height,
                    x: 0, y: 0,
                    style: .dim(.ansi256(239))
                )

                // Render modal into its own isolated buffer
                var modalLayer = Layer(
                    width: contentWidth, height: contentHeight,
                    x: mx, y: my,
                    style: .transparent  // only overwrite cells that have content
                )
                let modalContext = RenderContext(
                    style: .plain,
                    rect: Rect(x: 0, y: 0, width: contentWidth, height: contentHeight)
                )
                render(modalNode, into: &modalLayer.buffer, context: modalContext)

                // Offset resolved rects so hit testing works in screen coordinates
                offsetRects(of: modalNode, dx: mx, dy: my)

                // Composite: dim first, then modal on top
                Compositor.composite(layers: [dimLayer, modalLayer], into: &buffer)
            }
        }
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
    /// Style is read from the environment (HYP-91). Each of the four styles
    /// has different semantics:
    ///
    /// - `.overlay` — bar at `rect.x - 1` outside the focused view's rect.
    ///   Matches pre-HYP-91 behavior; top-level pass has no clip so the cell
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
