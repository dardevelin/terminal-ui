import Observation
import Testing
@testable import TerminalUI

// A reader builds its content once per width per update, and a body that
// re-evaluates in a drain — state changed by a task, not by input — hands it
// a new closure without an update. The reader must build from that closure:
// it kept the content of the old one, so a status bar fed by a task showed
// the line it had before the task's change until a key forced an update.

@Observable
private final class Line {
    var text = "before"
    var rows = ["one", "two"]
}

private struct Reading: TerminalView {
    let line: Line
    var body: some TerminalView {
        let text = line.text
        WidthReader { _ in Text(text) }
    }
}

private struct Row: Identifiable {
    let id: String
}

private struct Listing: TerminalView {
    let line: Line
    var body: some TerminalView {
        List(line.rows.map(Row.init), visibleCount: 3) { row in Text(row.id) }
    }
}

@MainActor
private func draw(_ graph: AttributeGraph, width: Int = 20, height: Int = 3) -> [String] {
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    Layout.measureAndPlace(graph: graph.root!, in: rect)
    GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    return buffer.rowTexts
}

@Suite("A reader rebuilt by a drain")
@MainActor
struct DrainedReaderTests {
    @Test func aWidthReaderBuildsFromTheClosureADrainHandsIt() {
        let line = Line()
        let graph = AttributeGraph()
        graph.update(from: Reading(line: line))
        #expect(draw(graph)[0] == "before")
        line.text = "after"
        #expect(graph.drain())
        #expect(draw(graph)[0] == "after")
    }

    @Test func aListOfDeclaredHeightShowsTheRowsADrainHandsIt() {
        let line = Line()
        let graph = AttributeGraph()
        graph.update(from: Listing(line: line))
        #expect(draw(graph).contains { $0.contains("two") })
        line.rows = ["three", "four"]
        #expect(graph.drain())
        let rows = draw(graph)
        #expect(rows.contains { $0.contains("four") }, "\(rows)")
        #expect(!rows.contains { $0.contains("two") }, "\(rows)")
    }
}
