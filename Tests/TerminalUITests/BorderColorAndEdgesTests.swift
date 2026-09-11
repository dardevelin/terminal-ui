import Testing
@testable import TerminalUI

// `.border(_:color:edges:)` exists for the frame that carries meaning rather
// than enclosure: the single coloured rail marking a chat message's author and
// focus state. Two things the old four-sided, foreground-inheriting border
// could not express — a frame stated separately from its content, and a frame
// that costs one column instead of a whole ring.
//
// The invariant tying the three passes together: a drawn edge costs exactly
// one cell, and an undrawn one costs nothing. Measurement, layout inset, and
// render all have to agree on that or the content lands off by a cell.

@MainActor
@Suite struct BorderColorAndEdgesTests {

    private func render(
        _ view: some TerminalView,
        width: Int,
        height: Int
    ) -> CellBuffer {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        return buffer
    }

    private func row(_ buffer: CellBuffer, _ y: Int, width: Int) -> String {
        var text = ""
        for x in 0..<width { text.append(buffer[x, y].character) }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    private func graph(_ view: some TerminalView) -> AttributeGraph {
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
        return graph
    }

    // MARK: - Colour

    @Test func borderColorAppliesToTheFrameOnly() {
        let view = Text("hi").foreground(.white).border(.rounded, color: .cyan)
        let buffer = render(view, width: 6, height: 3)
        #expect(buffer[0, 0].character == "╭")
        #expect(buffer[0, 0].style.foreground == .cyan)
        // The content keeps its own colour — a tinted frame must not bleed
        // into what it encloses.
        #expect(buffer[1, 1].character == "h")
        #expect(buffer[1, 1].style.foreground == .white)
    }

    /// The historical behaviour: no colour means the frame inherits whatever
    /// foreground surrounds it. Pinned so adding the parameter did not quietly
    /// change every existing `.border()` call.
    @Test func borderWithoutColorInheritsTheForeground() {
        let view = Text("hi").border(.rounded).foreground(.green)
        let buffer = render(view, width: 6, height: 3)
        #expect(buffer[0, 0].style.foreground == .green)
    }

    // MARK: - Edges

    @Test func leadingEdgeDrawsOneColumnRail() {
        let buffer = render(Text("body").border(.heavy, edges: .leading), width: 8, height: 1)
        #expect(row(buffer, 0, width: 8) == "┃body")
    }

    @Test func leadingRailCostsExactlyOneColumn() {
        // Content is 4 wide; the rail adds 1 and no rows.
        let bordered = graph(Text("body").border(.heavy, edges: .leading))
        #expect(GraphMeasurer.measureWidth(bordered.root!) == 5)
        #expect(GraphMeasurer.measureHeight(bordered.root!, proposedWidth: 8) == 1)
    }

    @Test func fullRingStillCostsTwoOnEachAxis() {
        let bordered = graph(Text("body").border())
        #expect(GraphMeasurer.measureWidth(bordered.root!) == 6)
        #expect(GraphMeasurer.measureHeight(bordered.root!, proposedWidth: 10) == 3)
    }

    /// A lone horizontal edge is a rule, not a rule with corner pieces on its
    /// ends — corners belong only where two drawn edges actually meet.
    @Test func topEdgeAloneDrawsAnUnbrokenRule() {
        let buffer = render(Text("ab").border(.rounded, edges: .top), width: 4, height: 2)
        #expect(row(buffer, 0, width: 4) == "────")
        #expect(row(buffer, 1, width: 4) == "ab")
    }

    @Test func cornersAppearOnlyWhereTwoEdgesMeet() {
        let buffer = render(Text("ab").border(.rounded, edges: [.top, .leading]),
                            width: 5, height: 2)
        // Top-left is a real corner; top-right is not, so the top run passes
        // straight through it.
        #expect(buffer[0, 0].character == "╭")
        #expect(buffer[4, 0].character == "─")
        #expect(buffer[0, 1].character == "│")
    }

    @Test func verticalPairDrawsBothRailsAndNoRules() {
        let buffer = render(Text("ab").border(.rounded, edges: .horizontal),
                            width: 4, height: 1)
        // `.horizontal` is the leading/trailing pair, matching SwiftUI's
        // Edge.Set naming — the axis the pair spans, not the edges' own axis.
        #expect(row(buffer, 0, width: 4) == "│ab│")
    }

    @Test func emptyEdgeSetDrawsNothingAndCostsNothing() {
        let bordered = graph(Text("body").border(.rounded, edges: []))
        #expect(GraphMeasurer.measureWidth(bordered.root!) == 4)
        let buffer = render(Text("body").border(.rounded, edges: []), width: 6, height: 1)
        #expect(row(buffer, 0, width: 6) == "body")
    }

    // MARK: - The three passes agreeing

    /// Layout insets only the sides that are drawn. A top-only border must
    /// push the content down one row and not indent it.
    @Test func contentIsInsetOnlyOnDrawnEdges() {
        let buffer = render(Text("x").border(.rounded, edges: .top), width: 3, height: 2)
        #expect(buffer[0, 1].character == "x")
    }

    @Test func bottomEdgeLeavesContentAtTheTop() {
        let buffer = render(Text("x").border(.rounded, edges: .bottom), width: 3, height: 2)
        #expect(buffer[0, 0].character == "x")
        #expect(buffer[0, 1].character == "─")
    }

    /// Zero is the "unconstrained" sentinel the scroll-position walk uses;
    /// subtracting the frame from it would make a bordered subtree report a
    /// nonsense width downstream.
    @Test func zeroProposedWidthPassesThroughTheFrame() {
        let bordered = graph(Text("body").border())
        #expect(GraphMeasurer.measureHeight(bordered.root!, proposedWidth: 0) > 0)
    }

    /// A rail narrower than its own frame must not draw — and must not crash.
    @Test func aFrameWithNoRoomForItsEdgesDrawsNothing() {
        let buffer = render(Text("").border(.rounded), width: 1, height: 1)
        #expect(buffer[0, 0].character == " ")
    }
}
