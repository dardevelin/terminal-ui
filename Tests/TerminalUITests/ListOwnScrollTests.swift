import Observation
import Testing
@testable import TerminalUI

// A List given no scroll binding keeps its own offset, as its documentation
// promises. Without one the window was worked out from the top on every
// frame: moving the selection down scrolled it, and moving back up snapped
// the window to the top while the selection was still in view — and a click
// on a row of a scrolled list chose the row that many places from the top.

private struct Row: Identifiable { let id: Int }

@Observable
private final class Selecting {
    var selected: Int? = 0
}

@MainActor
private struct Harness {
    let selecting = Selecting()
    let engine = FocusEngine()
    let graph = AttributeGraph()

    var view: some TerminalView {
        List((0..<10).map(Row.init), selection: Binding(get: { selecting.selected },
                                                         set: { selecting.selected = $0 }),
             visibleCount: 4) { row in Text("row \(row.id)") }
    }

    @discardableResult
    func frame() -> [String] {
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
        var buffer = CellBuffer(width: 20, height: 4)
        let rect = Rect(x: 0, y: 0, width: 20, height: 4)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        engine.rebuildIndex(root: graph.root!)
        return buffer.rowTexts
    }
}

@Suite("A list without a scroll binding keeps its own offset")
@MainActor
struct ListOwnScrollTests {

    @Test func movingBackUpWithinTheWindowLeavesItWhereItIs() {
        let harness = Harness()
        harness.frame()
        harness.selecting.selected = 6
        let scrolled = harness.frame()
        #expect(scrolled.contains { $0.hasSuffix("row 6") }, "\(scrolled)")
        harness.selecting.selected = 5
        let movedBack = harness.frame()
        let rows = { (screen: [String]) in screen.map { $0.replacingOccurrences(of: "▸", with: " ") } }
        #expect(rows(movedBack) == rows(scrolled), "the window should stay put: \(scrolled) → \(movedBack)")
    }
}
