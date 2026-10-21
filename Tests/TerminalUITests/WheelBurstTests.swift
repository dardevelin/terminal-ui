import Testing
@testable import TerminalUI

// A trackpad reports a scroll as a burst of wheel events — hundreds a
// second. Each one found its target under the cursor afresh, walking the
// tree for the focusable, the scroll view and the environment there, three
// times over; a debug build under Thread Sanitizer fell seconds behind and
// stopped answering. A run of identical wheel events in one batch finds its
// target once and moves it by the whole run.

@MainActor
private func scrolledGraph() -> (AttributeGraph, FocusEngine) {
    let view = ScrollView(.vertical) {
        VStack {
            ForEachWithID(0..<40, id: \.self) { i in Text("row \(i)") }
        }
    }
    let graph = AttributeGraph()
    let engine = FocusEngine()
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
    }
    engine.rebuildIndex(root: graph.root!)
    var buffer = CellBuffer(width: 30, height: 5)
    let rect = Rect(x: 0, y: 0, width: 30, height: 5)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    return (graph, engine)
}

@Suite("A burst of wheel events scrolls in one step")
@MainActor
struct WheelBurstTests {

    @Test func severalStepsScrollAsFarAsThatManyEvents() throws {
        let (one, oneEngine) = scrolledGraph()
        let (each, eachEngine) = scrolledGraph()

        _ = oneEngine.routeWheel(KeyEvent(key: .down), root: one.root!, x: 2, y: 1,
                                 policy: .clickToLock, steps: 7)
        for _ in 0..<7 {
            _ = eachEngine.routeWheel(KeyEvent(key: .down), root: each.root!, x: 2, y: 1,
                                      policy: .clickToLock)
        }

        let offset = try #require(oneEngine.findScrollNodeAt(x: 2, y: 1, root: one.root!)).scrollOffset
        let expected = try #require(eachEngine.findScrollNodeAt(x: 2, y: 1, root: each.root!)).scrollOffset
        #expect(offset == expected)
        #expect(offset > 0, "the wheel did not scroll at all")
    }
}
