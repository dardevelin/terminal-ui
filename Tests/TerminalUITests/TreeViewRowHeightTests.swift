import Observation
import Testing
@testable import TerminalUI

// TreeView chose its window as List did, one line a row, and found a clicked
// row by counting lines from its top. A label of several lines overflowed
// the height the tree was given, and a click on a tall row's second line
// chose the row below it.

private struct Node: Identifiable {
    let id: Int
    var children: [Node]?
    var label: String { "node \(id)\n  detail \(id)\n  more \(id)" }
}

@Observable
private final class Selecting {
    var selected: Int? = nil
}

@MainActor
private final class Screen<Content: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let content: Content
    private(set) var droppedWrites = 0

    init(_ content: Content) {
        self.content = content
    }

    var root: AttributeNode { graph.root! }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: content) }
        var buffer = CellBuffer(width: 30, height: 20)
        let rect = Rect(x: 0, y: 0, width: 30, height: 20)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: root)
        droppedWrites = buffer.clipRejectedWrites
        return buffer.rowTexts
    }
}

private let roots = (0..<8).map { Node(id: $0, children: nil) }

@Suite("A tree's rows may be any height")
@MainActor
struct TreeViewRowHeightTests {

    @Test func multiLineLabelsStayWithinTheBudget() {
        let screen = Screen(VStack {
            TreeView(roots, children: \.children, visibleCount: 7) { node in Text(node.label) }
            Text("below")
        })
        let drawn = screen.frame()
        #expect(drawn.firstIndex { $0.contains("below") } == 7, "\(drawn)")
        #expect(drawn[6].contains("▼ 6 more"), "two rows of three lines, then ▼: \(drawn)")
        #expect(screen.droppedWrites == 0)
    }

    @Test func aClickOnATallRowsSecondLineSelectsThatRow() {
        let selecting = Selecting()
        let screen = Screen(TreeView(roots, children: \.children,
                                     selection: Binding(get: { selecting.selected },
                                                        set: { selecting.selected = $0 }),
                                     visibleCount: 10) { node in Text(node.label) })
        let drawn = screen.frame()
        let y = drawn.firstIndex { $0.contains("detail 1") }
        #expect(y == 4, "\(drawn)")
        screen.engine.handleMouseClick(x: 6, y: y ?? 4, root: screen.root)
        screen.frame()
        #expect(selecting.selected == 1, "the click landed on row 1's second line")
    }

    @Test func selectingTheLastRowScrollsItWhollyIntoView() {
        let screen = Screen(TreeView(roots, children: \.children, visibleCount: 8) { node in Text(node.label) })
        screen.frame()
        screen.engine.focusNext()
        #expect(screen.engine.routeKeyEvent(KeyEvent(key: .end), root: screen.root))
        let drawn = screen.frame()
        #expect(drawn[0].contains("▲ 6 more"), "\(drawn)")
        #expect(drawn.contains { $0.contains("more 7") }, "\(drawn)")
    }
}
