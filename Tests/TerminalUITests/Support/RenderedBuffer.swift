@testable import TerminalUI

/// `view` drawn once into a `width` × `height` terminal, as a running app
/// would draw it: the environment knows the terminal's size and the root is
/// offered all of it, which width and geometry readers measure against.
/// `theme`, when given, is the app's.
@MainActor
func renderedBuffer(_ view: some TerminalView, width: Int, height: Int,
                    theme: (any Theme)? = nil) -> CellBuffer {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    var environment = EnvironmentValues()
    if let theme {
        environment.theme = theme
    }
    environment.terminalSize = TerminalSize(cols: width, rows: height)
    GraphContext.$currentEnvironment.withValue(environment) {
        GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    return buffer
}

extension CellBuffer {
    /// Row `y` as text, its trailing blanks dropped.
    func text(row y: Int) -> String {
        var line = String((0..<width).map { self[$0, y].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    /// Every row as text, trailing blanks dropped.
    var rowTexts: [String] { (0..<height).map { text(row: $0) } }
}
