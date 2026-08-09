import Testing
@testable import TerminalUI

// `.background` must paint the subtree's entire rect — including cells the
// content never writes — or full-screen themed apps (an editor chrome, a
// dashboard with panel backgrounds) show terminal-default holes wherever a
// row is blank. Pinned because the render path colors cells as it writes
// them: if a future change stops filling blank cells, this is the test
// that says so.

@MainActor
@Suite struct BackgroundFillTests {
    @Test func backgroundPaintsEveryCellOfTheRect() {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 12, height: 4)
        let rect = Rect(x: 0, y: 0, width: 12, height: 4)
        let view = VStack {
            Text("hi")
            Spacer()
        }
        .background(.blue)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        for y in 0..<4 {
            for x in 0..<12 {
                #expect(buffer[x, y].style.background == .blue,
                        "cell (\(x),\(y)) missed the background fill")
            }
        }
    }
}
