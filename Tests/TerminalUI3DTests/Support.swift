@testable import TerminalUI
import TerminalUI3D

/// `view` drawn once into a `width` × `height` terminal, as a running app
/// would draw it. `theme`, when given, is the app's.
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

    /// Every cell that shows something: not a blank with no background.
    var drawnCells: Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width where self[x, y].character != " " || self[x, y].style.background != nil {
                count += 1
            }
        }
        return count
    }
}

/// A dark theme, with a background a renderer can mix toward.
struct DarkTestTheme: Theme {
    var background: Color = .rgb(24, 24, 30)
    var foreground: Color = .rgb(220, 220, 225)
    var accent: Color = .rgb(90, 170, 250)
    var primary: Color = .rgb(200, 120, 60)
}

/// A light theme, with a background a renderer can mix toward.
struct LightTestTheme: Theme {
    var background: Color = .rgb(248, 246, 240)
    var foreground: Color = .rgb(30, 30, 35)
    var accent: Color = .rgb(30, 100, 200)
    var primary: Color = .rgb(180, 90, 40)
}
