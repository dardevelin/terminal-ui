// Prototype renderer — walks the view tree and fills a CellBuffer.
// No attribute graph yet. Full re-render every frame.
// This is the mock we replace later.

public struct RenderContext {
    public var style: Style
    public var rect: Rect

    public init(style: Style = .plain, rect: Rect) {
        self.style = style
        self.rect = rect
    }
}

public enum Renderer {

    public static func render<V: TerminalView>(_ view: V, into buffer: inout CellBuffer, context: RenderContext) {
        let tracer = DevTracer.shared
        tracer.traceLayoutPlace(String(describing: type(of: view)), rect: context.rect)

        switch view {
        case let text as Text:
            renderText(text, into: &buffer, context: context)
        case let vstack as any _VStackProtocol:
            renderVStack(vstack, into: &buffer, context: context)
        case let hstack as any _HStackProtocol:
            renderHStack(hstack, into: &buffer, context: context)
        case let progress as ProgressBar:
            renderProgressBar(progress, into: &buffer, context: context)
        case let spinner as Spinner:
            renderSpinner(spinner, into: &buffer, context: context)
        case is Spacer:
            break
        case is EmptyView:
            break
        default:
            renderModifiedOrComposite(view, into: &buffer, context: context)
        }
    }

    // MARK: - ProgressBar

    static func renderProgressBar(_ bar: ProgressBar, into buffer: inout CellBuffer, context: RenderContext) {
        let width = context.rect.intWidth
        let labelPart: String
        if let label = bar.label {
            labelPart = label + " "
        } else {
            labelPart = ""
        }

        let percentText = " \(Int(bar.value * 100))%"
        let barWidth = max(0, width - labelPart.count - percentText.count)
        let filledCount = Int(Double(barWidth) * bar.value)
        let emptyCount = barWidth - filledCount

        let barText = labelPart
            + String(repeating: bar.filled, count: filledCount)
            + String(repeating: bar.empty, count: emptyCount)
            + percentText

        buffer.write(barText, x: context.rect.intX, y: context.rect.intY, style: context.style)
    }

    // MARK: - Spinner

    static func renderSpinner(_ spinner: Spinner, into buffer: inout CellBuffer, context: RenderContext) {
        buffer.write(spinner.text, x: context.rect.intX, y: context.rect.intY, style: context.style)
    }

    // MARK: - Text

    static func renderText(_ text: Text, into buffer: inout CellBuffer, context: RenderContext) {
        let lines = text.content.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            let y = context.rect.intY + i
            guard y < context.rect.intY + context.rect.intHeight else { break }
            buffer.write(String(line), x: context.rect.intX, y: y, style: context.style)
        }
    }

    // MARK: - VStack

    static func renderVStack(_ vstack: any _VStackProtocol, into buffer: inout CellBuffer, context: RenderContext) {
        let children = vstack.collectChildren()
        guard !children.isEmpty else { return }

        let spacerCount = children.filter { $0 is Spacer }.count

        // Measure actual height of every non-spacer child
        var childHeights: [Double] = []
        var totalContentHeight: Double = 0
        for child in children {
            if child is Spacer {
                childHeights.append(0) // placeholder, filled below
            } else {
                let h = measureHeight(child, proposedWidth: context.rect.width)
                childHeights.append(h)
                totalContentHeight += h
            }
        }

        let remainingHeight = max(0, context.rect.height - totalContentHeight)
        let spacerHeight = spacerCount > 0 ? remainingHeight / Double(spacerCount) : 0

        var y = context.rect.y
        for (i, child) in children.enumerated() {
            if child is Spacer {
                y += spacerHeight
                continue
            }
            let h = childHeights[i]
            let snappedY = y.rounded(.down)
            let snappedH = (y + h).rounded(.down) - snappedY
            let childRect = Rect(x: context.rect.x, y: snappedY, width: context.rect.width, height: max(1, snappedH))
            let childContext = RenderContext(style: context.style, rect: childRect)
            renderAny(child, into: &buffer, context: childContext)
            y += h
        }
    }

    // MARK: - HStack

    static func renderHStack(_ hstack: any _HStackProtocol, into buffer: inout CellBuffer, context: RenderContext) {
        let children = hstack.collectChildren()
        guard !children.isEmpty else { return }

        let spacerCount = children.filter { $0 is Spacer }.count
        let nonSpacerWidths = children.compactMap { child -> Double? in
            if child is Spacer { return nil }
            return measureWidth(child)
        }
        let totalContentWidth = nonSpacerWidths.reduce(0.0, +)
        let remainingWidth = max(0, context.rect.width - totalContentWidth)
        let spacerWidth = spacerCount > 0 ? remainingWidth / Double(spacerCount) : 0.0

        var x = context.rect.x
        for child in children {
            if child is Spacer {
                x += spacerWidth
                continue
            }
            let childWidth = Double(measureWidth(child))
            let snappedX = x.rounded(.down)
            let snappedW = (x + childWidth).rounded(.down) - snappedX
            let childRect = Rect(x: snappedX, y: context.rect.y, width: max(1, snappedW), height: context.rect.height)
            let childContext = RenderContext(style: context.style, rect: childRect)
            renderAny(child, into: &buffer, context: childContext)
            x += childWidth
        }
    }

    // MARK: - Modifiers

    static func renderModifiedOrComposite<V: TerminalView>(_ view: V, into buffer: inout CellBuffer, context: RenderContext) {
        // Check for modifiers via type-erased protocol
        if let modified = view as? any _ModifiedViewProtocol {
            modified.renderModified(into: &buffer, context: context)
            return
        }

        // Composite view — evaluate body
        if !(V.Body.self == Never.self) {
            DevTracer.shared.traceBodyEvaluated(String(describing: V.self))
            render(view.body, into: &buffer, context: context)
        }
    }

    // MARK: - Type-erased rendering

    static func renderAny(_ view: Any, into buffer: inout CellBuffer, context: RenderContext) {
        if let text = view as? Text {
            renderText(text, into: &buffer, context: context)
        } else if let bar = view as? ProgressBar {
            renderProgressBar(bar, into: &buffer, context: context)
        } else if let spinner = view as? Spinner {
            renderSpinner(spinner, into: &buffer, context: context)
        } else if let vstack = view as? any _VStackProtocol {
            renderVStack(vstack, into: &buffer, context: context)
        } else if let hstack = view as? any _HStackProtocol {
            renderHStack(hstack, into: &buffer, context: context)
        } else if view is Spacer || view is EmptyView {
            return
        } else if let modified = view as? any _ModifiedViewProtocol {
            modified.renderModified(into: &buffer, context: context)
        } else if let tv = view as? any TerminalView {
            renderAnyTerminalView(tv, into: &buffer, context: context)
        }
    }

    static func renderAnyTerminalView<V: TerminalView>(_ view: V, into buffer: inout CellBuffer, context: RenderContext) {
        if !(V.Body.self == Never.self) {
            render(view.body, into: &buffer, context: context)
        }
    }

    // MARK: - Measurement (simple prototype)

    static func measureWidth(_ view: Any) -> Double {
        if let text = view as? Text {
            let lines = text.content.split(separator: "\n", omittingEmptySubsequences: false)
            return Double(lines.map(\.count).max() ?? 0)
        }
        if view is ProgressBar {
            return 20 // progress bars are flexible, give a minimum
        }
        if let spinner = view as? Spinner {
            return Double(spinner.text.count)
        }
        if let modified = view as? any _ModifiedViewProtocol {
            return modified.measureModifiedWidth()
        }
        if let vstack = view as? any _VStackProtocol {
            let children = vstack.collectChildren()
            return children.map { measureWidth($0) }.max() ?? 0
        }
        if let hstack = view as? any _HStackProtocol {
            let children = hstack.collectChildren()
            return children.map { measureWidth($0) }.reduce(0, +)
        }
        if view is Spacer || view is EmptyView {
            return 0
        }
        // Composite view — measure its body
        if let tv = view as? any TerminalView {
            return measureBodyWidth(tv)
        }
        return 0
    }

    static func measureBodyWidth<V: TerminalView>(_ view: V) -> Double {
        if V.Body.self == Never.self { return 0 }
        return measureWidth(view.body)
    }

    static func measureHeight(_ view: Any, proposedWidth: Double) -> Double {
        if let text = view as? Text {
            return Double(text.content.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
        if let modified = view as? any _ModifiedViewProtocol {
            return modified.measureModifiedHeight(proposedWidth: proposedWidth)
        }
        if let vstack = view as? any _VStackProtocol {
            let children = vstack.collectChildren()
            return children.map { measureHeight($0, proposedWidth: proposedWidth) }.reduce(0, +)
        }
        if let hstack = view as? any _HStackProtocol {
            let children = hstack.collectChildren()
            return children.map { measureHeight($0, proposedWidth: proposedWidth) }.max() ?? 0
        }
        if view is Spacer {
            return 1 // spacer takes minimum 1 row in measurement
        }
        if view is EmptyView {
            return 0
        }
        // Composite view — measure its body
        if let tv = view as? any TerminalView {
            return measureBodyHeight(tv, proposedWidth: proposedWidth)
        }
        return 1
    }

    static func measureBodyHeight<V: TerminalView>(_ view: V, proposedWidth: Double) -> Double {
        if V.Body.self == Never.self { return 0 }
        return measureHeight(view.body, proposedWidth: proposedWidth)
    }
}

// MARK: - Internal protocols for type-erased dispatch

protocol _VStackProtocol {
    func collectChildren() -> [Any]
}

protocol _HStackProtocol {
    func collectChildren() -> [Any]
}

protocol _ModifiedViewProtocol {
    func renderModified(into buffer: inout CellBuffer, context: RenderContext)
    func measureModifiedWidth() -> Double
    func measureModifiedHeight(proposedWidth: Double) -> Double
}
