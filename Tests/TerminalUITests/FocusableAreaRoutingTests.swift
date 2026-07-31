import Testing
@testable import TerminalUI

// Making a whole area focusable is how an app gives the focus engine something
// to cycle to — a sidebar, a pane, a region. The area then sits above
// everything inside it, and both mouse paths used to stop there:
//
//   * a click focused the area and never reached the row under the cursor,
//     because the search for a click handler started at the focusable rather
//     than at the deepest thing beneath the pointer;
//   * a wheel was offered to the area first, and an area that reads arrows as
//     "move my selection" consumed it — so wheeling over the list inside moved
//     the selection instead of scrolling the list.
//
// Both are settled by depth: the deepest thing under the cursor answers first.
// A control inside a scroll view is deeper than it, so the control is asked
// first and one that ignores the wheel falls through to the pane holding it.

@MainActor
private final class Recorder {
    var clicks = 0
    var selection = 0
}

@MainActor
private func buildArea(_ recorder: Recorder) -> (AttributeGraph, FocusEngine) {
    let view = VStack {
        ScrollView(.vertical) {
            VStack {
                ForEachWithID(Array(0..<30), id: \.self) { index in
                    Text("row-\(index)")
                        .onClick { [recorder] _, _ in recorder.clicks += 1 }
                }
            }
        }
    }
    .focusable()
    .onKeyPress { [recorder] event in
        switch event.key {
        case .up, .down:
            recorder.selection += 1
            return .handled
        default:
            return .ignored
        }
    }

    let graph = AttributeGraph()
    let engine = FocusEngine()
    var buffer = CellBuffer(width: 20, height: 6)
    let rect = Rect(x: 0, y: 0, width: 20, height: 6)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    engine.rebuildIndex(root: graph.root!)
    return (graph, engine)
}

@Suite("A focusable area does not swallow what is inside it")
@MainActor
struct FocusableAreaRoutingTests {

    @Test("clicking a row inside a focusable area fires the row's handler")
    func clickReachesTheRow() {
        let recorder = Recorder()
        let (graph, engine) = buildArea(recorder)

        engine.handleMouseClick(x: 2, y: 1, root: graph.root!)

        #expect(recorder.clicks == 1, "the row under the cursor is deeper than the area")
        #expect(engine.keyboardFocusID != nil, "and the area still takes focus")
    }

    @Test("wheeling over the list inside scrolls it rather than moving a selection")
    func wheelReachesTheScrollView() {
        let recorder = Recorder()
        let (graph, engine) = buildArea(recorder)
        guard let scrollNode = engine.findScrollNodeAt(x: 2, y: 1, root: graph.root!) else {
            Issue.record("test setup failed: no scroll node under the cursor")
            return
        }

        let handled = GraphContext.$currentFocusEngine.withValue(engine) {
            engine.routeWheel(KeyEvent(key: .down), root: graph.root!, x: 2, y: 1, policy: .clickToLock)
        }

        #expect(handled)
        #expect(scrollNode.scrollOffset > 0, "the wheel belongs to the list under the cursor")
        #expect(recorder.selection == 0, "and not to the area's arrow handling")
    }
}
