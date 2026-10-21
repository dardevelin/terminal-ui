import Testing
@testable import TerminalUI

// A scroll view sizes its content by measuring it, and measurements are
// cached on the nodes. When a `ForEach` gained or lost elements the cache
// above it was kept, so the scroll view went on drawing the content at the
// size it had before: a line appended to a log was laid out, and never shown.

private struct Entry: Identifiable {
    let id: Int
}

private struct IdentifiedLog: TerminalView {
    let count: Int
    var body: some TerminalView {
        ScrollView {
            VStack(spacing: 0) {
                ForEach((0..<count).map(Entry.init)) { entry in Text("line \(entry.id)") }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct KeyedLog: TerminalView {
    let count: Int
    var body: some TerminalView {
        ScrollView {
            VStack(spacing: 0) {
                ForEachWithID(Array(0..<count), id: \.self) { index in Text("line \(index)") }
            }
        }
        .scrollIndicators(.hidden)
    }
}

@MainActor
private func show(_ graph: AttributeGraph, _ view: some TerminalView) -> [String] {
    var buffer = CellBuffer(width: 10, height: 4)
    let rect = Rect(x: 0, y: 0, width: 10, height: 4)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<4).map { y in
        var line = String((0..<10).map { buffer[$0, y].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}

@Suite("Content that grows or shrinks is measured again")
@MainActor
struct GrownContentMeasureTests {

    @Test func anIdentifiedForEachThatGrowsIsDrawnWhole() {
        let graph = AttributeGraph()
        _ = show(graph, IdentifiedLog(count: 1))
        #expect(show(graph, IdentifiedLog(count: 3)) == ["line 0", "line 1", "line 2", ""])
    }

    @Test func aKeyedForEachThatGrowsIsDrawnWhole() {
        let graph = AttributeGraph()
        _ = show(graph, KeyedLog(count: 1))
        #expect(show(graph, KeyedLog(count: 3)) == ["line 0", "line 1", "line 2", ""])
    }

    @Test func aForEachThatShrinksLeavesNothingBehind() {
        let graph = AttributeGraph()
        _ = show(graph, KeyedLog(count: 3))
        #expect(show(graph, KeyedLog(count: 1)) == ["line 0", "", "", ""])
    }
}
