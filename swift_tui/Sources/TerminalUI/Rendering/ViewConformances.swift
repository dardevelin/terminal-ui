// Connect view types to the renderer's internal protocols.
// This is the glue between the public API and the rendering engine.

// MARK: - VStack children extraction

extension VStack: _VStackProtocol {
    public func collectChildren() -> [Any] {
        extractChildren(from: content)
    }
}

// MARK: - HStack children extraction

extension HStack: _HStackProtocol {
    public func collectChildren() -> [Any] {
        extractChildren(from: content)
    }
}

// MARK: - ForEach as VStack (for old renderer)

extension ForEach: _VStackProtocol {
    public func collectChildren() -> [Any] {
        data.map { content($0) }
    }
}

extension ForEachWithID: _VStackProtocol {
    public func collectChildren() -> [Any] {
        data.map { content($0) }
    }
}

// MARK: - TupleView unpacking

func extractChildren(from value: Any) -> [Any] {
    let mirror = Mirror(reflecting: value)

    // TupleView wraps a tuple in .value
    if let tupleView = value as? any _TupleViewProtocol {
        return tupleView.children()
    }

    // Actual tuple
    if mirror.displayStyle == .tuple {
        return mirror.children.map(\.value)
    }

    // Single view
    return [value]
}

protocol _TupleViewProtocol {
    func children() -> [Any]
}

extension TupleView: _TupleViewProtocol {
    public func children() -> [Any] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .tuple {
            return mirror.children.map(\.value)
        }
        return [value]
    }
}

// MARK: - ModifiedView rendering

extension ModifiedView: _ModifiedViewProtocol {
    public func renderModified(into buffer: inout CellBuffer, context: RenderContext) {
        var ctx = context

        switch modifier {
        case let fg as ForegroundModifier:
            ctx.style.foreground = fg.color
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case let bg as BackgroundModifier:
            ctx.style.background = bg.color
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case is BoldModifier:
            ctx.style.bold = true
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case is ItalicModifier:
            ctx.style.italic = true
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case is UnderlineModifier:
            ctx.style.underline = true
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case let pad as PaddingModifier:
            let padded = ctx.rect.inset(by: pad.amount)
            ctx.rect = padded
            Renderer.renderAny(content, into: &buffer, context: ctx)

        case let bdr as BorderModifier:
            renderBorder(bdr.style, into: &buffer, context: ctx)
            let inner = ctx.rect.inset(by: 1)
            ctx.rect = inner
            Renderer.renderAny(content, into: &buffer, context: ctx)

        default:
            Renderer.renderAny(content, into: &buffer, context: ctx)
        }
    }

    public func measureModifiedWidth() -> Int {
        var base = Renderer.measureWidth(content)
        if modifier is PaddingModifier {
            base += (modifier as! PaddingModifier).amount * 2
        }
        if modifier is BorderModifier {
            base += 2
        }
        return base
    }

    public func measureModifiedHeight(proposedWidth: Int) -> Int {
        var base = Renderer.measureHeight(content, proposedWidth: proposedWidth)
        if modifier is PaddingModifier {
            base += (modifier as! PaddingModifier).amount * 2
        }
        if modifier is BorderModifier {
            base += 2
        }
        return base
    }

    func renderBorder(_ style: BorderStyle, into buffer: inout CellBuffer, context: RenderContext) {
        let r = context.rect
        guard r.width >= 2, r.height >= 2 else { return }

        // Corners
        buffer[r.x, r.y] = Cell(character: style.topLeft, style: context.style)
        buffer[r.x + r.width - 1, r.y] = Cell(character: style.topRight, style: context.style)
        buffer[r.x, r.y + r.height - 1] = Cell(character: style.bottomLeft, style: context.style)
        buffer[r.x + r.width - 1, r.y + r.height - 1] = Cell(character: style.bottomRight, style: context.style)

        // Horizontal edges
        for x in (r.x + 1)..<(r.x + r.width - 1) {
            buffer[x, r.y] = Cell(character: style.horizontal, style: context.style)
            buffer[x, r.y + r.height - 1] = Cell(character: style.horizontal, style: context.style)
        }

        // Vertical edges
        for y in (r.y + 1)..<(r.y + r.height - 1) {
            buffer[r.x, y] = Cell(character: style.vertical, style: context.style)
            buffer[r.x + r.width - 1, y] = Cell(character: style.vertical, style: context.style)
        }
    }
}
