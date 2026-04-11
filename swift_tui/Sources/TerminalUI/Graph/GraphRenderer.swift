/// Renderer that walks the attribute graph instead of the view tree.
/// Switches on NodeKind enum — no Any, no as?, no protocol conformance checks.
public enum GraphRenderer {

    public static func render(_ node: AttributeNode, into buffer: inout CellBuffer, context: RenderContext) {
        switch node.kind {
        case .primitive(let content):
            renderPrimitive(content, into: &buffer, context: context)

        case .layout(let info):
            renderLayout(node, info: info, into: &buffer, context: context)

        case .modifier(let effect):
            renderModifier(node, effect: effect, into: &buffer, context: context)

        case .viewBody:
            // Composite — just render children
            for child in node.children {
                render(child, into: &buffer, context: context)
            }
        }
    }

    // MARK: - Primitives (enum switch = jump table)

    static func renderPrimitive(_ content: PrimitiveContent, into buffer: inout CellBuffer, context: RenderContext) {
        switch content {
        case .text(let string):
            let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                let y = context.rect.y + i
                guard y < context.rect.y + context.rect.height else { break }
                buffer.write(String(line), x: context.rect.x, y: y, style: context.style)
            }

        case .spacer:
            break

        case .divider:
            // Horizontal line filling the width
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
        let spacerHeight = spacerCount > 0 ? remainingHeight / spacerCount : 0

        var y = context.rect.y
        for (i, child) in children.enumerated() {
            if case .primitive(.spacer) = child.kind {
                y += spacerHeight
                continue
            }
            let h = childHeights[i]
            let childRect = Rect(x: context.rect.x, y: y, width: context.rect.width, height: h)
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
        let spacerWidth = spacerCount > 0 ? remainingWidth / spacerCount : 0

        var x = context.rect.x
        for (i, child) in children.enumerated() {
            if case .primitive(.spacer) = child.kind {
                x += spacerWidth
                continue
            }
            let w = childWidths[i]
            let childRect = Rect(x: x, y: context.rect.y, width: w, height: context.rect.height)
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
            // Identity modifier — doesn't affect rendering
            render(child, into: &buffer, context: ctx)
        }
    }

    static func renderBorder(_ style: BorderStyle, into buffer: inout CellBuffer, context: RenderContext) {
        let r = context.rect
        guard r.width >= 2, r.height >= 2 else { return }

        buffer[r.x, r.y] = Cell(character: style.topLeft, style: context.style)
        buffer[r.x + r.width - 1, r.y] = Cell(character: style.topRight, style: context.style)
        buffer[r.x, r.y + r.height - 1] = Cell(character: style.bottomLeft, style: context.style)
        buffer[r.x + r.width - 1, r.y + r.height - 1] = Cell(character: style.bottomRight, style: context.style)

        for x in (r.x + 1)..<(r.x + r.width - 1) {
            buffer[x, r.y] = Cell(character: style.horizontal, style: context.style)
            buffer[x, r.y + r.height - 1] = Cell(character: style.horizontal, style: context.style)
        }

        for y in (r.y + 1)..<(r.y + r.height - 1) {
            buffer[r.x, y] = Cell(character: style.vertical, style: context.style)
            buffer[r.x + r.width - 1, y] = Cell(character: style.vertical, style: context.style)
        }
    }

    // MARK: - Measurement

    public static func measureWidth(_ node: AttributeNode) -> Int {
        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let s):
                return s.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
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
            case .text(let s):
                return s.split(separator: "\n", omittingEmptySubsequences: false).count
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
}
