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

private struct Row: Identifiable {
    let id: Int
    let label: String
}

// #5 reproduction — "list was showing partial elements instead of
// all until focused (render bug ?)". Render a small List into a buffer
// WITHOUT focusing anything and assert every row's leading char made it
// into the cells.

@Suite("List — renders every row when unfocused")
@MainActor
struct ListPartialRenderTests {

    @Test("5-element List at matching height renders all rows unfocused")
    func listRendersAllRows() {
        resetGraphContext()
        let rows = [
            Row(id: 1, label: "alpha"),
            Row(id: 2, label: "beta"),
            Row(id: 3, label: "gamma"),
            Row(id: 4, label: "delta"),
            Row(id: 5, label: "epsilon"),
        ]
        let graph = AttributeGraph()
        graph.update(from: List(rows, visibleCount: 5) { Text($0.label) })
        var buffer = CellBuffer(width: 20, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Each row is "▸ <label>" or "  <label>" — the label's first char
        // lives at column 2. Check rows 0..4 carry the expected leading
        // chars (a, b, g, d, e).
        let expectedLeads: [(Int, Character)] = [
            (0, "a"), (1, "b"), (2, "g"), (3, "d"), (4, "e")
        ]
        for (row, ch) in expectedLeads {
            #expect(buffer[2, row].character == ch,
                    "row \(row) should start with '\(ch)', got '\(buffer[2, row].character)'")
        }
    }

    @Test("List without explicit visibleCount fits to container height")
    func listFitsContainer() {
        resetGraphContext()
        let rows = [
            Row(id: 1, label: "one"),
            Row(id: 2, label: "two"),
            Row(id: 3, label: "three"),
        ]
        let graph = AttributeGraph()
        graph.update(from: List(rows) { Text($0.label) })
        var buffer = CellBuffer(width: 20, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        #expect(buffer[2, 0].character == "o")
        #expect(buffer[2, 1].character == "t")
        #expect(buffer[2, 2].character == "t")
    }
}
