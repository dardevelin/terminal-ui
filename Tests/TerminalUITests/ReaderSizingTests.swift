import Testing
@testable import TerminalUI

// A GeometryReader held one subtree built for one size, and measurement read
// whichever subtree the last pass had left. Layout rebuilt it at one size,
// render at another, and the height a parent measured depended on which ran
// last — on the PromptInput page, 5 rows reported at width 39 and 2 at
// width 37, an inversion no honest measurement produces.
//
// The two jobs a reader was doing are now two views. GeometryReader is told
// its size on both axes and claims nothing when measured, as in SwiftUI.
// WidthReader is told its width only and measured by building its content for
// that width — the content cannot read the height it decides, so there is no
// cycle to lose.

private let sentence = "the quick brown fox jumps over the lazy dog again and again"

@MainActor
private func render(_ view: some TerminalView, width: Int, height: Int) -> (AttributeGraph, CellBuffer) {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    return (graph, buffer)
}

/// The first node in the tree that is a reader.
private func reader(in node: AttributeNode) -> AttributeNode? {
    if node.readerSizing != nil { return node }
    for child in node.children {
        if let found = reader(in: child) { return found }
    }
    return nil
}

@Suite("GeometryReader is told its size; WidthReader measures its height")
@MainActor
struct ReaderSizingTests {

    // MARK: - GeometryReader

    /// Asked how tall it is, a greedy reader has no answer of its own —
    /// whatever its content happens to be.
    @Test func aGeometryReaderClaimsNothingWhenMeasured() {
        let (graph, _) = render(GeometryReader { _ in Text(sentence) }, width: 10, height: 8)
        let node = reader(in: graph.root!)!
        #expect(GraphMeasurer.measureHeight(node, proposedWidth: 10) == 0)
        #expect(GraphMeasurer.measureWidth(node) == 0)
    }

    @Test func aGeometryReaderTakesTheHeightItsStackLeaves() {
        let (_, buffer) = render(VStack(spacing: 0) {
            Text("top")
            GeometryReader { size in Text("\(size.width)x\(size.height)") }
            Text("bottom")
        }, width: 12, height: 6)
        #expect(buffer.text(row: 1) == "12x4")
        #expect(buffer.text(row: 5) == "bottom")
    }

    // MARK: - WidthReader

    @Test func aWidthReaderIsAsTallAsItsContentAtItsWidth() {
        let (_, buffer) = render(VStack(spacing: 0) {
            WidthReader { width in Text(sentence).wrap(.wrap) }
            Text("below")
        }, width: 20, height: 8)
        // Whatever the sentence wraps to at twenty columns, what follows
        // starts on the next row.
        let rows = TextLayout.wrapWords(sentence, width: 20).count
        #expect(rows > 1)
        #expect(buffer.text(row: rows - 1) != "")
        #expect(buffer.text(row: rows) == "below")
    }

    @Test func aWidthReaderIsHandedTheWidthItIsGiven() {
        let (_, buffer) = render(HStack(spacing: 0) {
            Text("ab")
            WidthReader { width in Text("w=\(width)") }
        }, width: 12, height: 1)
        #expect(buffer.text(row: 0) == "abw=10")
    }

    /// The inversion this replaces: measuring at alternating widths must give
    /// the same answer for the same width every time, and never more rows at
    /// the wider width.
    @Test func measurementDependsOnTheWidthAskedNotOnTheLastPass() {
        let (graph, _) = render(WidthReader { _ in Text(sentence).wrap(.wrap) }, width: 39, height: 8)
        let node = reader(in: graph.root!)!
        let narrow = GraphMeasurer.measureHeight(node, proposedWidth: 37)
        let wide = GraphMeasurer.measureHeight(node, proposedWidth: 39)
        let narrowAgain = GraphMeasurer.measureHeight(node, proposedWidth: 37)
        #expect(narrow == narrowAgain)
        #expect(narrow >= wide)
        #expect(GraphMeasurer.measureHeight(node, proposedWidth: 10) > narrow)
    }

    /// Building is paid once per width per update: measurement, layout and
    /// render ask about the same width and share the build.
    @Test func aWidthReaderBuildsOncePerWidthPerUpdate() {
        nonisolated(unsafe) var builds = 0
        let view = VStack(spacing: 0) {
            WidthReader { width in
                builds += 1
                return Text("w=\(width)")
            }
        }
        let graph = AttributeGraph()
        let rect = Rect(x: 0, y: 0, width: 16, height: 4)
        func frame() {
            var buffer = CellBuffer(width: 16, height: 4)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            GraphContext.$currentProposedSize.withValue(Size(width: 16, height: 4)) {
                _ = graph.update(from: view)
                frame()
                #expect(builds == 1, "seeded at the width the frame then used")
                frame()
                #expect(builds == 1, "a second frame with nothing changed builds nothing")
                _ = graph.update(from: view)
                frame()
                #expect(builds == 2, "an update may change what the content reads")
            }
        }
    }
}
