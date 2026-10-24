import Observation
import Testing
@testable import TerminalUI

// SwiftUI's DisclosureGroup: a label that shows or hides its content. Here
// the label row is one Tab stop; Enter, Space or a click flips it, and →
// opens and ← closes it, as a row of a tree does. A pane of a stacked panel
// folds away with one — a review's file list above the diff it chooses.

@Observable
private final class Folding {
    var isExpanded = true
}

@MainActor
private struct Harness {
    let folding = Folding()
    let engine = FocusEngine()
    let graph = AttributeGraph()

    var view: some TerminalView {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: Binding(get: { folding.isExpanded },
                                                set: { folding.isExpanded = $0 })) {
                Text("first file")
                Text("second file")
            } label: {
                Text("2 files changed")
            }
            Text("below")
        }
    }

    /// Rebuilds and draws, as a frame does, and returns the rows.
    @discardableResult
    func frame() -> [String] {
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
        var buffer = CellBuffer(width: 30, height: 6)
        let rect = Rect(x: 0, y: 0, width: 30, height: 6)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        engine.rebuildIndex(root: graph.root!)
        // The runtime focuses the first control at launch; so does this.
        if engine.keyboardFocusID == nil { engine.focusNext() }
        return buffer.rowTexts
    }

    func press(_ key: Key) {
        _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
    }
}

@Suite("A disclosure group folds its content away")
@MainActor
struct DisclosureGroupTests {

    @Test func expandedItShowsItsContentUnderTheLabel() {
        let harness = Harness()
        let rows = harness.frame()
        #expect(rows[0] == "▾ 2 files changed", "\(rows)")
        #expect(rows[1] == "first file")
        #expect(rows[3] == "below")
    }

    @Test func collapsedOnlyTheLabelIsLeft() {
        let harness = Harness()
        harness.folding.isExpanded = false
        let rows = harness.frame()
        #expect(rows[0] == "▸ 2 files changed", "\(rows)")
        #expect(rows[1] == "below", "what follows moves up into the room")
    }

    @Test func enterAndSpaceFlipIt() {
        let harness = Harness()
        harness.frame()
        harness.press(.enter)
        #expect(!harness.folding.isExpanded)
        harness.frame()
        harness.press(.character(" "))
        #expect(harness.folding.isExpanded)
    }

    @Test func rightOpensAndLeftCloses() {
        let harness = Harness()
        harness.frame()
        harness.press(.left)
        #expect(!harness.folding.isExpanded)
        harness.frame()
        harness.press(.left)
        #expect(!harness.folding.isExpanded, "← on a closed group leaves it closed")
        harness.frame()
        harness.press(.right)
        #expect(harness.folding.isExpanded)
    }

    @Test func theLabelRowSpansTheGroupsWidth() {
        let harness = Harness()
        let rows = harness.frame()
        // The rows are 30 wide; the label's row reaches the last cell.
        let row = harness.engine.collectFocusables(harness.graph.root!).first!.rect
        #expect(row.width == 30, "\(row) \(rows)")
    }

    @Test func aLabelLaidOutAsARowReachesTheEdge() {
        let folding = Folding()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: DisclosureGroup(isExpanded: Binding(get: { folding.isExpanded },
                                                                   set: { folding.isExpanded = $0 })) {
                Text("content")
            } label: {
                HStack(spacing: 1) {
                    Text("path").flexible(.horizontal)
                    Text("[end]")
                }
            })
        }
        var buffer = CellBuffer(width: 30, height: 3)
        let rect = Rect(x: 0, y: 0, width: 30, height: 3)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        #expect(buffer.text(row: 0).hasSuffix("[end]") && buffer.text(row: 0).count == 30,
                "\(buffer.rowTexts)")
    }

    @Test func theLabelIsOneTabStop() {
        let harness = Harness()
        harness.frame()
        #expect(harness.engine.collectFocusables(harness.graph.root!).count == 1)
    }
}
