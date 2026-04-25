import Testing
@testable import TerminalUI

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// reproduces the user's screenshot bug where a List row shrinking
// from "epsilone" to "epsilon" left a stale 'e' in the trailing cell.
//
// Strategy: render a Text at width W, update it to shorter content, render
// again into the SAME buffer (reused between frames — which is what the
// runtime does) and assert trailing cells are cleared.

@Suite("Shrunk content bleed — renderer clears trailing cells")
@MainActor
struct ShrinkBleedTests {

    @Test("Text shrink — trailing cells clear within the rect")
    func textShrinkClearsTail() {
        resetGraphContext()
        let graph = AttributeGraph()
        let rect = Rect(x: 0, y: 0, width: 10, height: 1)
        let ctx = RenderContext(rect: rect)

        var buffer = CellBuffer(width: 10, height: 1)
        graph.update(from: Text("epsilone"))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        #expect(buffer[7, 0].character == "e")  // trailing e of "epsilone"

        // Reuse the same buffer (runtime reuses via previousBuffer, but the
        // delta goes terminal-side — within a single buffer, the renderer
        // itself must overwrite the region it owns).
        graph.update(from: Text("epsilon"))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // Cell 7 previously had 'e' from "epsilone"; new content ends at cell 6.
        // Under a correct renderer, cell 7 is overwritten with a space.
        #expect(buffer[6, 0].character == "n")  // last char of "epsilon"
        #expect(buffer[7, 0].character == " ",
                "cell past end of shrunk text must be cleared (got '\(buffer[7, 0].character)')")
    }

    @Test("VStack row shrink — no stale cells across rows")
    func vstackRowShrinkClears() {
        resetGraphContext()
        let graph = AttributeGraph()
        let rect = Rect(x: 0, y: 0, width: 12, height: 3)
        let ctx = RenderContext(rect: rect)

        var buffer = CellBuffer(width: 12, height: 3)
        graph.update(from: VStack {
            Text("alpha")
            Text("epsilone")
            Text("gamma")
        })
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        #expect(buffer[7, 1].character == "e")  // tail of "epsilone" on row 1

        // Shrink row 1
        graph.update(from: VStack {
            Text("alpha")
            Text("epsilon")
            Text("gamma")
        })
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        #expect(buffer[7, 1].character == " ",
                "VStack row shrink must clear the vacated cell (got '\(buffer[7, 1].character)')")
    }
}
