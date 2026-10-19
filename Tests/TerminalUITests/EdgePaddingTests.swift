import Testing
@testable import TerminalUI

// Padding was one number applied to all four sides. Every message frame in an
// agent transcript wants it on one side only — a column between a rail and
// the text, two columns where there is no rail — and uniform padding opened a
// blank row above and below each one instead. `.padding(_:_:)` and
// `.padding(EdgeInsets)` say which sides, in SwiftUI's words, and `Edge.Set`
// is now the one name for "which sides" that borders and padding share.

@MainActor
private func render(_ view: some TerminalView, width: Int, height: Int) -> [String] {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        _ = graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<height).map { y in
        var line = String((0..<width).map { buffer[$0, y].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}

@MainActor
private func size(of view: some TerminalView, width: Int) -> (width: Int, height: Int) {
    let graph = AttributeGraph()
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        _ = graph.update(from: view)
    }
    return (GraphMeasurer.measureWidth(graph.root!),
            GraphMeasurer.measureHeight(graph.root!, proposedWidth: width))
}

@Suite("Padding on the sides you name")
@MainActor
struct EdgePaddingTests {

    @Test func leadingPaddingShiftsContentWithoutAddingRows() {
        let rows = render(VStack(spacing: 0) {
            Text("ab").padding(.leading, 2)
            Text("cd")
        }, width: 10, height: 2)
        #expect(rows == ["  ab", "cd"])
    }

    @Test func eachFormInsetsTheSidesItNames() {
        #expect(size(of: Text("ab").padding(.leading, 2), width: 20) == (4, 1))
        #expect(size(of: Text("ab").padding(.horizontal, 1), width: 20) == (4, 1))
        #expect(size(of: Text("ab").padding(.vertical, 1), width: 20) == (2, 3))
        #expect(size(of: Text("ab").padding(EdgeInsets(top: 1, trailing: 3)), width: 20) == (5, 2))
        #expect(size(of: Text("ab").padding(), width: 20) == (4, 3), "uniform padding is unchanged")
    }

    /// The inset narrows the width the child wraps in.
    @Test func textWrapsInsideTheInset() {
        #expect(size(of: Text("aaaa bbbb").padding(.leading, 2), width: 11).height == 1)
        #expect(size(of: Text("aaaa bbbb").padding(.leading, 2), width: 10).height == 2)
    }

    /// The frame every transcript message is drawn in: a rail, a column of
    /// room, then the text — on every row the text wraps to.
    @Test func aRailWithRoomBesideIt() {
        let rows = render(Text("aaaa bbbb")
            .padding(.leading, 1)
            .border(.heavy, color: .red, edges: .leading), width: 7, height: 2)
        #expect(rows == ["┃ aaaa", "┃ bbbb"])
    }

    @Test func borderEdgesAndEdgeSetAreOneType() {
        let border: BorderEdges = .leading
        let edges: Edge.Set = border
        #expect(edges == Edge.Set(.leading))
        #expect(EdgeInsets(.horizontal, 2) == EdgeInsets(leading: 2, trailing: 2))
    }

    @Test func uniformInsetsDescribeThemselvesAsOneNumber() {
        #expect(EdgeInsets(.all, 1).description == "1")
        #expect(EdgeInsets(leading: 2).description == "0,2,0,0")
    }
}
