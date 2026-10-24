import Testing
import Observation
@testable import TerminalUI

// A ForEach builds its rows from its closure while the graph reconciles,
// after the body that holds it has returned, so what the closure read from
// an @Observable model was tracked by no body: a list whose rows read the
// selection kept its old marks when only the selection changed. The
// tutorial's split view showed it, once the split stopped rebuilding its
// panes on every update. What a row closure reads now invalidates the body
// holding the ForEach.

@Observable
private final class Picks {
    var items = [1, 2, 3]
    var selected = 1
}

/// No inputs of its own: equal to itself, so only what it reads redraws it.
private struct Rows: TerminalView {
    let picks: Picks
    var body: some TerminalView {
        VStack(spacing: 0) {
            ForEach(picks.items.map(Row.init)) { row in
                Text(row.id == picks.selected ? "▸ \(row.id)" : "  \(row.id)")
            }
        }
    }
}

private struct Row: Identifiable {
    let id: Int
}

private struct KeyedRows: TerminalView {
    let picks: Picks
    var body: some TerminalView {
        VStack(spacing: 0) {
            ForEachWithID(picks.items, id: \.self) { item in
                Text(item == picks.selected ? "▸ \(item)" : "  \(item)")
            }
        }
    }
}

@MainActor
private func screen(_ graph: AttributeGraph) -> [String] {
    var buffer = CellBuffer(width: 6, height: 3)
    let rect = Rect(x: 0, y: 0, width: 6, height: 3)
    Layout.measureAndPlace(graph: graph.root!, in: rect)
    GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    return (0..<3).map { y in (0..<6).map { String(buffer[$0, y].character) }.joined() }
}

@Suite("What a ForEach row reads redraws it")
@MainActor
struct ForEachRowTrackingTests {

    @Test func aRowReadingTheSelectionRedrawsWhenOnlyTheSelectionChanges() {
        let picks = Picks()
        let graph = AttributeGraph()
        graph.update(from: Rows(picks: picks))
        #expect(screen(graph)[0].hasPrefix("▸ 1"))
        picks.selected = 2
        graph.drain()
        let rows = screen(graph)
        #expect(rows[0].hasPrefix("  1") && rows[1].hasPrefix("▸ 2"), "\(rows)")
    }

    @Test func soDoesAKeyedRow() {
        let picks = Picks()
        let graph = AttributeGraph()
        graph.update(from: KeyedRows(picks: picks))
        picks.selected = 3
        graph.drain()
        #expect(screen(graph)[2].hasPrefix("▸ 3"))
    }

    @Test func aRowReadingTheSelectionRedrawsUnderAnEqualParentUpdate() {
        let picks = Picks()
        let graph = AttributeGraph()
        graph.update(from: Rows(picks: picks))
        picks.selected = 2
        // The frame walks from the root with an equal view: the gate lets
        // the body run because what it read changed.
        graph.update(from: Rows(picks: picks))
        #expect(screen(graph)[1].hasPrefix("▸ 2"))
    }
}
