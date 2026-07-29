import Testing
@testable import TerminalUI

// The ▲ ▼ and the scrollbar thumb are drawn to be pressed. They were paint
// with nothing behind them: no node, no hit region, so a click landed on
// whatever content cell happened to sit underneath. Every other affordance
// this framework draws takes a click — a Slider's track, a Toggle's box, a
// Stepper's arrows — and one that doesn't reads as a stuck pane rather than
// as decoration.
//
// The hit region is stamped by the renderer that paints it, so the cells that
// respond are exactly the cells the user can see.

@MainActor
private func scrolling(rows: Int, width: Int, height: Int) -> (AttributeGraph, FocusEngine, AttributeNode) {
    let view = ScrollView(.vertical) {
        VStack {
            ForEachWithID(Array(0..<rows), id: \.self) { index in
                Text("row-\(index)")
            }
        }
    }
    let graph = AttributeGraph()
    let engine = FocusEngine()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    engine.rebuildIndex(root: graph.root!)
    let scrollNode = engine.findScrollNodeAt(x: 0, y: 0, root: graph.root!)!
    return (graph, engine, scrollNode)
}

@Suite("Scroll affordances take clicks")
@MainActor
struct ScrollAffordanceClickTests {

    @Test("clicking the bottom indicator scrolls forward, the top one back")
    func clickingIndicatorsSteps() {
        let (graph, engine, node) = scrolling(rows: 40, width: 20, height: 6)
        guard let affordance = node.scrollAffordanceRect else {
            Issue.record("a scroll view with more content than viewport must claim its track")
            return
        }

        engine.handleMouseClick(x: affordance.x, y: affordance.y + affordance.height - 1,
                                root: graph.root!)
        let afterDown = node.scrollOffset
        #expect(afterDown > 0, "clicking ▼ advances the viewport")

        engine.handleMouseClick(x: affordance.x, y: affordance.y, root: graph.root!)
        #expect(node.scrollOffset < afterDown, "clicking ▲ takes it back")
    }

    @Test("clicking the middle of the track jumps to the middle of the content")
    func clickingTrackJumps() {
        let (graph, engine, node) = scrolling(rows: 40, width: 20, height: 6)
        guard let affordance = node.scrollAffordanceRect else {
            Issue.record("no track claimed")
            return
        }

        engine.handleMouseClick(x: affordance.x, y: affordance.y + affordance.height / 2,
                                root: graph.root!)

        // 40 rows in a 6-row viewport: the far end is 34.
        let maxOffset = 40 - 6
        #expect(node.scrollOffset > maxOffset / 4)
        #expect(node.scrollOffset < maxOffset * 3 / 4)
    }

    // Nothing is drawn when the content fits, so nothing is clickable either —
    // otherwise a column of a short pane would silently swallow clicks meant
    // for the content under it.
    @Test("content that fits claims no track")
    func contentThatFitsClaimsNothing() {
        let (_, _, node) = scrolling(rows: 3, width: 20, height: 6)
        #expect(node.scrollAffordanceRect == nil)
    }

    // The track is painted over the content's last column, so the click has to
    // belong to the scroll view rather than to the row beneath it.
    @Test("a click on the track does not also activate the row under it")
    func trackClickDoesNotActivateContent() {
        var activated = 0
        let view = ScrollView(.vertical) {
            VStack {
                ForEachWithID(Array(0..<40), id: \.self) { index in
                    Text("row-\(index)").onClick { _, _ in activated += 1 }
                }
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

        guard let node = engine.findScrollNodeAt(x: 0, y: 0, root: graph.root!),
              let affordance = node.scrollAffordanceRect else {
            Issue.record("no track claimed")
            return
        }
        // Near the far end of the track, so the press has somewhere to move
        // the viewport to — the top of the track means offset zero.
        engine.handleMouseClick(x: affordance.x, y: affordance.y + affordance.height - 2,
                                root: graph.root!)
        #expect(activated == 0, "the track belongs to the scroll view")
        #expect(node.scrollOffset > 0)
    }
}
