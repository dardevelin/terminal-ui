/// Renderer that walks the attribute graph instead of the view tree.
/// Switches on NodeKind enum — no Any, no as?, no protocol conformance checks.
public enum GraphRenderer {

    public static func render(_ node: AttributeNode, into buffer: inout CellBuffer, context: RenderContext) {
        // Record resolved rect on every node — used for hit testing
        node.rect = context.rect

        #if DEBUG
        let tracer = DevTracer.shared
        let nodeName: String
        switch node.kind {
        case .primitive(let c):
            switch c {
            case .text: nodeName = "Text"
            case .spacer: nodeName = "Spacer"
            case .divider: nodeName = "Divider"
            case .progressBar: nodeName = "ProgressBar"
            case .spinner: nodeName = "Spinner"
            case .empty: nodeName = "Empty"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: nodeName = "VStack"
            case .hstack: nodeName = "HStack"
            case .zstack: nodeName = "ZStack"
            }
        case .modifier(let effect):
            switch effect {
            case .foreground: nodeName = "fg"
            case .background: nodeName = "bg"
            case .bold: nodeName = "bold"
            case .italic: nodeName = "italic"
            case .underline: nodeName = "underline"
            case .padding: nodeName = "padding"
            case .border: nodeName = "border"
            case .frame: nodeName = "frame"
            case .explicitID: nodeName = "id"
            case .overlay: nodeName = "overlay"
            case .backgroundView: nodeName = "bgView"
            case .modal: nodeName = "modal"
            case .focusable: nodeName = "focusable"
            case .onKeyPress: nodeName = "onKeyPress"
            case .onAppear: nodeName = "onAppear"
            case .onClick: nodeName = "onClick"
            }
        case .viewBody(let info):
            nodeName = info.viewTypeName
        }
        tracer.traceLayoutPlace(nodeName, rect: context.rect)
        #endif

        switch node.kind {
        case .primitive(let content):
            renderPrimitive(content, into: &buffer, context: context)

        case .layout(let info):
            renderLayout(node, info: info, into: &buffer, context: context)

        case .modifier(let effect):
            renderModifier(node, effect: effect, into: &buffer, context: context)

        case .viewBody(let info):
            #if DEBUG
            tracer.traceBodyEvaluated(info.viewTypeName)
            #endif
            for child in node.children {
                render(child, into: &buffer, context: context)
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
                    let clipped = line.count > maxWidth ? String(line.prefix(maxWidth)) : String(line)
                    buffer.write(clipped, x: context.rect.x, y: y, style: context.style)
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
            let line = String(repeating: "─", count: context.rect.width)
            buffer.write(line, x: context.rect.x, y: context.rect.y, style: context.style)

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
        let children = node.children
        guard !children.isEmpty else { return }

        switch info.kind {
        case .vstack:
            renderVStack(children, into: &buffer, context: context)
        case .hstack:
            renderHStack(children, into: &buffer, context: context)
        case .zstack:
            renderZStack(children, into: &buffer, context: context)
        }
    }

    static func renderVStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        let spacerCount = children.filter { if case .primitive(.spacer) = $0.kind { return true }; return false }.count

        var childHeights: [Int] = []
        var totalContentHeight = 0
        for child in children {
            if case .primitive(.spacer) = child.kind {
                childHeights.append(0)
            } else {
                let h = measureHeight(child, proposedWidth: context.rect.width)
                childHeights.append(h)
                totalContentHeight += h
            }
        }

        let remainingHeight = max(0, context.rect.height - totalContentHeight)
        let spacerBase = spacerCount > 0 ? remainingHeight / spacerCount : 0
        var spacerRemainder = spacerCount > 0 ? remainingHeight % spacerCount : 0

        var y = context.rect.y
        for (i, child) in children.enumerated() {
            if case .primitive(.spacer) = child.kind {
                let extra = spacerRemainder > 0 ? 1 : 0
                spacerRemainder -= extra
                y += spacerBase + extra
                continue
            }
            let h = childHeights[i]
            let childRect = Rect(x: context.rect.x, y: y, width: context.rect.width, height: max(1, h))
            let childContext = RenderContext(style: context.style, rect: childRect)
            render(child, into: &buffer, context: childContext)
            y += h
        }
    }

    static func renderHStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        let spacerCount = children.filter { if case .primitive(.spacer) = $0.kind { return true }; return false }.count

        var childWidths: [Int] = []
        var totalContentWidth = 0
        for child in children {
            if case .primitive(.spacer) = child.kind {
                childWidths.append(0)
            } else {
                let w = measureWidth(child)
                childWidths.append(w)
                totalContentWidth += w
            }
        }

        let remainingWidth = max(0, context.rect.width - totalContentWidth)
        let spacerBase = spacerCount > 0 ? remainingWidth / spacerCount : 0
        var spacerRemainder = spacerCount > 0 ? remainingWidth % spacerCount : 0

        var x = context.rect.x
        for (i, child) in children.enumerated() {
            if case .primitive(.spacer) = child.kind {
                let extra = spacerRemainder > 0 ? 1 : 0
                spacerRemainder -= extra
                x += spacerBase + extra
                continue
            }
            let w = childWidths[i]
            let childRect = Rect(x: x, y: context.rect.y, width: max(1, w), height: context.rect.height)
            let childContext = RenderContext(style: context.style, rect: childRect)
            render(child, into: &buffer, context: childContext)
            x += w
        }
    }

    static func renderZStack(_ children: [AttributeNode], into buffer: inout CellBuffer, context: RenderContext) {
        // All children occupy the full rect — last child renders on top
        for child in children {
            render(child, into: &buffer, context: context)
        }
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

        case .frame(let width, let height):
            if let w = width { ctx.rect.width = min(w, ctx.rect.width) }
            if let h = height { ctx.rect.height = min(h, ctx.rect.height) }
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

        case .onKeyPress:
            // Handler is registered on FocusEngine during graph update,
            // not during rendering. Just pass through.
            render(child, into: &buffer, context: ctx)

        case .onAppear:
            render(child, into: &buffer, context: ctx)

        case .onClick:
            render(child, into: &buffer, context: ctx)

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

    // MARK: - Measurement

    public static func measureWidth(_ node: AttributeNode) -> Int {
        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                // Fast path: single span (99% of cases) — no allocation
                if spans.count == 1 {
                    return spans[0].text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
                }
                // Multi-span: need to join
                return spans.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
            case .spacer, .empty: return 0
            case .divider: return 1
            case .progressBar: return 20
            case .spinner(let frame, let style):
                return style.frames[frame % style.frames.count].count
            }

        case .layout(let info):
            switch info.kind {
            case .vstack:
                return node.children.map { measureWidth($0) }.max() ?? 0
            case .hstack:
                return node.children.map { measureWidth($0) }.reduce(0, +)
            case .zstack:
                return node.children.map { measureWidth($0) }.max() ?? 0
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

    public static func measureHeight(_ node: AttributeNode, proposedWidth: Int) -> Int {
        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                if spans.count == 1 {
                    return spans[0].text.split(separator: "\n", omittingEmptySubsequences: false).count
                }
                return spans.map(\.text).joined().split(separator: "\n", omittingEmptySubsequences: false).count
            case .spacer: return 1
            case .divider: return 1
            case .empty: return 0
            case .progressBar: return 1
            case .spinner: return 1
            }

        case .layout(let info):
            switch info.kind {
            case .vstack:
                return node.children.map { measureHeight($0, proposedWidth: proposedWidth) }.reduce(0, +)
            case .hstack:
                return node.children.map { measureHeight($0, proposedWidth: proposedWidth) }.max() ?? 0
            case .zstack:
                return node.children.map { measureHeight($0, proposedWidth: proposedWidth) }.max() ?? 0
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

    // MARK: - Focus Rendering

    /// Draw focus indicators after the main render pass.
    /// Keyboard focus: highlighted border/underline on the focused node's rect.
    /// Mouse hover: subtle highlight on hovered node's rect.
    public static func renderFocusIndicators(into buffer: inout CellBuffer, focusEngine: FocusEngine) {
        // Keyboard focus — bold cyan left edge indicator
        if let focusedID = focusEngine.keyboardFocusID,
           let root = findRootForFocus(in: buffer),
           let node = focusEngine.findNode(id: focusedID, in: root) {
            let r = node.rect
            // Draw focus indicator: cyan left bar
            let focusStyle = Style(foreground: .cyan, background: nil, bold: true, italic: false, underline: false)
            for y in r.y..<min(r.y + r.height, buffer.height) {
                guard r.x > 0 else { continue }
                buffer[r.x - 1, y] = Cell(character: "▎", style: focusStyle)
            }
        }

        // Mouse hover — dim highlight on hovered node
        if let hoverID = focusEngine.mouseHoverID,
           hoverID != focusEngine.keyboardFocusID,
           let root = findRootForFocus(in: buffer),
           let node = focusEngine.findNode(id: hoverID, in: root) {
            let r = node.rect
            let hoverStyle = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: true)
            for y in r.y..<min(r.y + r.height, buffer.height) {
                guard r.x > 0 else { continue }
                buffer[r.x - 1, y] = Cell(character: "▏", style: hoverStyle)
            }
        }
    }

    /// Render focus indicators using the graph root directly.
    public static func renderFocusIndicators(into buffer: inout CellBuffer, focusEngine: FocusEngine, root: AttributeNode?) {
        guard let root else { return }

        // Keyboard focus — cyan left edge bar
        if let focusedID = focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: focusedID, in: root) {
            let r = node.rect
            let focusStyle = Style(foreground: .cyan, background: nil, bold: true, italic: false, underline: false)
            for y in r.y..<min(r.y + r.height, buffer.height) {
                guard r.x > 0 else { continue }
                buffer[r.x - 1, y] = Cell(character: "▎", style: focusStyle)
            }
        }

        // Mouse hover — subtle underline bar (only if different from keyboard focus)
        if let hoverID = focusEngine.mouseHoverID,
           hoverID != focusEngine.keyboardFocusID,
           let node = focusEngine.findNode(id: hoverID, in: root) {
            let r = node.rect
            let hoverStyle = Style(foreground: .gray, background: nil, bold: false, italic: false, underline: false)
            for y in r.y..<min(r.y + r.height, buffer.height) {
                guard r.x > 0 else { continue }
                buffer[r.x - 1, y] = Cell(character: "▏", style: hoverStyle)
            }
        }
    }

    // Temporary: buffer doesn't carry graph root, so this is unused
    private static func findRootForFocus(in buffer: CellBuffer) -> AttributeNode? {
        nil
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
