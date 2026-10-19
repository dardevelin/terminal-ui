import Testing
@testable import TerminalUI

// A vertical scroll view laid its content out across the full viewport width
// and then painted the scrollbar over the last column. Whatever the content
// drew there was gone: the last letter of a line that filled the width, or the
// `…` a truncated line ends on — which made a correctly truncated line read as
// one cut off mid-word. The bar now takes a column of its own whenever it can
// appear, and only then.

@MainActor
private func render(_ view: some TerminalView, width: Int, height: Int) -> CellBuffer {
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

private func row(_ buffer: CellBuffer, _ y: Int) -> String {
    String((0..<buffer.width).map { buffer[$0, y].character })
}

/// Ten cells exactly — fills a ten-wide viewport to its last column.
private let fullWidthLine = "aaaa bbbbb"

@Suite("A vertical scrollbar takes its own column instead of covering content")
@MainActor
struct ScrollbarGutterTests {

    private func overflowing(_ first: some TerminalView) -> some TerminalView {
        ScrollView(.vertical) {
            VStack {
                first
                ForEachWithID(Array(0..<10), id: \.self) { index in
                    Text("row \(index)")
                }
            }
        }
    }

    @Test func aLineThatFillsTheWidthLosesNothingToTheBar() {
        let buffer = render(overflowing(Text(fullWidthLine)), width: 10, height: 4)
        // Laid out one column narrower, the line wraps rather than running
        // under the bar.
        #expect(row(buffer, 0).hasPrefix("aaaa     "))
        #expect(row(buffer, 1).hasPrefix("bbbbb    "))
        for y in 0..<buffer.height {
            #expect("│█▲▼".contains(buffer[9, y].character), "column 9 is the bar's, row \(y)")
        }
    }

    @Test func aTruncatedLineKeepsItsEllipsis() {
        let line = Text(String(repeating: "x", count: 30)).wrap(.truncate(.tail))
        let buffer = render(overflowing(line), width: 10, height: 4)
        #expect(row(buffer, 0).hasPrefix("xxxxxxxx…"))
    }

    @Test func contentThatFitsKeepsTheFullWidth() {
        let view = ScrollView(.vertical) { Text(fullWidthLine) }
        let buffer = render(view, width: 10, height: 3)
        #expect(row(buffer, 0) == fullWidthLine)
    }

    @Test func hiddenIndicatorsGiveTheColumnBack() {
        let buffer = render(overflowing(Text(fullWidthLine)).scrollIndicators(.hidden),
                            width: 10, height: 4)
        #expect(row(buffer, 0) == fullWidthLine)
    }
}
