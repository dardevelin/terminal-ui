import Testing
@testable import TerminalUI

// Padding, a border's drawn edges and a frame's width all narrow the space
// their child is laid out in, but measurement asked the child about the outer
// width. A wrapping child inside a border therefore reported fewer rows than it
// drew, and the box came out short with its last line clipped. Fixing it had
// to wait for the GeometryReader cycle it destabilised; it now asks the same
// rule layout uses.

@MainActor
private func measure(_ view: some TerminalView, width: Int) -> Int {
    let graph = AttributeGraph()
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        _ = graph.update(from: view)
    }
    return GraphMeasurer.measureHeight(graph.root!, proposedWidth: width)
}

/// Nine cells: fits one row at nine columns, wraps to two at eight.
private let words = "aaaa bbbb"

@Suite("A modifier's child is measured at the width it is laid out at")
@MainActor
struct InsetMeasurementTests {

    @Test func aBorderedChildIsMeasuredInsideTheBorder() {
        #expect(measure(Text(words).border(), width: 11) == 3)
        #expect(measure(Text(words).border(), width: 10) == 4)
    }

    @Test func aPaddedChildIsMeasuredInsideThePadding() {
        #expect(measure(Text(words).padding(1), width: 11) == 3)
        #expect(measure(Text(words).padding(1), width: 10) == 4)
    }

    @Test func aLeadingRailCostsOneColumnOfWrapWidth() {
        #expect(measure(Text(words).border(edges: .leading), width: 10) == 1)
        #expect(measure(Text(words).border(edges: .leading), width: 9) == 2)
    }

    @Test func aFixedWidthFrameMeasuresItsChildAtThatWidth() {
        #expect(measure(Text(words).frame(width: 8), width: 40) == 2)
    }

    /// What the bug looked like on screen: the box is as tall as what it draws.
    @Test func aBorderedBoxIsTallEnoughForItsWrappedText() {
        let view = VStack(spacing: 0) {
            Text(words).border()
            Text("after")
        }
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 10, height: 6)
        let rect = Rect(x: 0, y: 0, width: 10, height: 6)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            _ = graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        let rows = (0..<6).map { y in String((0..<10).map { buffer[$0, y].character }) }
        #expect(rows[1].contains("aaaa"))
        #expect(rows[2].contains("bbbb"), "the wrapped row is inside the box, not clipped")
        #expect(rows[4].hasPrefix("after"))
    }
}
