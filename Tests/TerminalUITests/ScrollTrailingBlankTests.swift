import Testing
@testable import TerminalUI

// The ▼ and the thumb answered "is there content below the viewport?" with the
// *measured* extent of the scroll content, which counts rows that draw
// nothing. A pane whose content is padded out — a sidebar with a fixed height,
// a stack ending in a spacer — therefore claimed more to see while sitting on
// its last row, and let the user keep scrolling into blank space.
//
// A user reading that reasonably concludes the pane is stuck and their keys
// are being ignored, which is the opposite of what an affordance is for. The
// question the glyph answers is about what is *drawn*, so it is asked of the
// rendered content rather than of the measurement.

@MainActor
private func renderPaddedContent(viewport height: Int) -> (AttributeNode, CellBuffer) {
    // Five drawn rows inside twenty rows of declared height: the last fifteen
    // are the trailing blanks.
    let view = ScrollView(.vertical) {
        VStack {
            ForEachWithID(Array(0..<5), id: \.self) { index in
                Text("row-\(index)")
            }
        }
        .frame(height: 20)
    }
    let graph = AttributeGraph()
    let engine = FocusEngine()
    var buffer = CellBuffer(width: 12, height: height)
    let rect = Rect(x: 0, y: 0, width: 12, height: height)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    let node = engine.findScrollNodeAt(x: 0, y: 0, root: graph.root!)!
    return (node, buffer)
}

@MainActor
private func redraw(_ node: AttributeNode, root: AttributeNode, height: Int) -> CellBuffer {
    var buffer = CellBuffer(width: 12, height: height)
    let rect = Rect(x: 0, y: 0, width: 12, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        Layout.measureAndPlace(graph: root, in: rect)
        GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    }
    return buffer
}

private func contains(_ buffer: CellBuffer, _ glyph: Character) -> Bool {
    (0..<buffer.height).contains { y in
        (0..<buffer.width).contains { x in buffer[x, y].character == glyph }
    }
}

@Suite("Scroll affordances count drawn content, not declared height")
@MainActor
struct ScrollTrailingBlankTests {

    @Test("the last drawn row on screen means there is nothing more below")
    func lastDrawnRowEndsTheIndicator() {
        let (node, first) = renderPaddedContent(viewport: 3)
        #expect(contains(first, "▼"), "there really is more at the top of the list")

        // Two steps brings row-4, the last drawn row, into a 3-row viewport.
        node.scrollOffset = 2
        let root = node
        var parent: AttributeNode = root
        while let next = parent.parent { parent = next }
        let scrolled = redraw(node, root: parent, height: 3)

        #expect(!contains(scrolled, "▼"),
                "the last row is on screen, so nothing promises more below it")
    }

    @Test("scrolling stops at the last drawn row")
    func offsetStopsAtDrawnContent() {
        let (node, _) = renderPaddedContent(viewport: 3)
        for _ in 0..<20 {
            _ScrollMath.mutateOffset(event: KeyEvent(key: .down), axis: .vertical, node: node)
        }
        // Five drawn rows in a three-row viewport: the far end is two.
        #expect(node.scrollOffset == 2,
                "blank rows below the content are not somewhere to scroll to")
    }
}
