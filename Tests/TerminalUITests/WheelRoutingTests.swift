import Testing
@testable import TerminalUI

// The wheel is not a key. It climbs from the view under the pointer to the
// first that moves for it — a scroll view on its axis, or a view that
// scrolls itself (List, TreeView, DiffView) — and only what moved counts as
// taken, so the end of an inner list hands the wheel to the view holding it.
// Delivered as ↑/↓ it moved a list's selection, a text field's caret, and
// fired any `.onKeyPress(.up)` above — history recall among them.

private final class Box: @unchecked Sendable {
    var keys: [Key] = []
    var selection: Int? = 0
}

@MainActor
private final class Screen<Content: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let view: Content
    let width: Int
    let height: Int

    init(width: Int = 30, height: Int = 8, _ view: Content) {
        self.view = view
        self.width = width
        self.height = height
        draw()
    }

    var root: AttributeNode { graph.root! }

    @discardableResult
    func draw() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: root)
        return buffer.rowTexts
    }

    @discardableResult
    func wheel(_ key: Key, at x: Int, _ y: Int, steps: Int = 1) -> Bool {
        engine.routeWheel(KeyEvent(key: key), root: root, x: x, y: y, policy: .clickToLock, steps: steps)
    }

    func scrollNodes() -> [AttributeNode] {
        var found: [AttributeNode] = []
        func walk(_ node: AttributeNode) {
            if case .layout(let info) = node.kind, case .scroll = info.kind { found.append(node) }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }
}

private struct Row: Identifiable { let id: Int }

@Suite("The wheel climbs to what moves for it")
@MainActor
struct WheelRoutingTests {

    @Test func anOnKeyPressAboveThePointerNeverHearsTheWheel() {
        let box = Box()
        let screen = Screen(VStack(spacing: 0) {
            ForEachWithID(0..<3, id: \.self) { row in Text("row \(row)").focusable() }
        }
        .onKeyPress { event in
            box.keys.append(event.key)
            return .handled
        })
        screen.wheel(.down, at: 1, 1)
        #expect(box.keys.isEmpty, "a wheel reached onKeyPress as \(box.keys)")
    }

    @Test func aWheelOverAListScrollsItWithoutMovingTheSelection() {
        let box = Box()
        let screen = Screen(height: 4, List((0..<20).map(Row.init),
                                            selection: Binding(get: { box.selection }, set: { box.selection = $0 }),
                                            visibleCount: 4) { row in Text("item \(row.id)") })
        #expect(screen.wheel(.down, at: 3, 1, steps: 3))
        let rows = screen.draw()
        #expect(box.selection == 0, "the wheel moved the selection")
        #expect(!rows.contains { $0.contains("item 0") }, "the list should have scrolled: \(rows)")
    }

    @Test func aListAtItsEndHandsTheWheelToTheScrollViewHoldingIt() {
        let box = Box()
        let screen = Screen(height: 6, ScrollView(.vertical) {
            VStack(spacing: 0) {
                List((0..<3).map(Row.init), selection: Binding(get: { box.selection }, set: { box.selection = $0 }),
                     visibleCount: 3) { row in Text("item \(row.id)") }
                ForEachWithID(0..<20, id: \.self) { row in Text("after \(row)") }
            }
        })
        #expect(screen.wheel(.down, at: 3, 1), "a list with nothing to scroll should pass the wheel on")
        #expect(screen.scrollNodes().first?.scrollOffset == 1)
    }

    @Test func aVerticalWheelOverAHorizontalScrollerReachesTheVerticalOneAroundIt() {
        let screen = Screen(height: 6, ScrollView(.vertical) {
            VStack(spacing: 0) {
                ScrollView(.horizontal) { Text(String(repeating: "wide ", count: 20)) }
                    .frame(height: 1)
                ForEachWithID(0..<20, id: \.self) { row in Text("row \(row)") }
            }
        })
        #expect(screen.wheel(.down, at: 3, 0))
        let outer = screen.scrollNodes().first { node in
            if case .layout(let info) = node.kind, case .scroll(.vertical) = info.kind { return true }
            return false
        }
        #expect(outer?.scrollOffset == 1)
    }

    @Test func aSidewaysWheelScrollsAHorizontalScroller() {
        let screen = Screen(height: 3, ScrollView(.horizontal) { Text(String(repeating: "wide ", count: 20)) })
        #expect(screen.wheel(.right, at: 3, 0))
        #expect(screen.scrollNodes().first?.scrollOffset == 1)
    }

    @Test func aDiffViewStopsAtItsLastPage() {
        let lines = (0..<10).map { DiffLine(id: $0, kind: .unchanged, text: "line \($0)",
                                            oldLineNumber: $0 + 1, newLineNumber: $0 + 1) }
        let screen = Screen(height: 4, DiffView(lines: lines, visibleHeight: 4))
        screen.wheel(.down, at: 3, 1, steps: 50)
        let rows = screen.draw()
        #expect(rows.last?.contains("line 9") == true, "the last line should sit on the last row: \(rows)")
    }
}

private final class Editing: @unchecked Sendable {
    var text = (0..<30).map { "line \($0)" }.joined(separator: "\n")
    var state = TextAreaState()
}

@Suite("The wheel scrolls a text area's view, not its caret")
@MainActor
struct TextAreaWheelTests {

    @Test func theWheelScrollsTheLinesAndLeavesTheCaretAndSelection() {
        let editing = Editing()
        editing.state.selection = TextAreaSelection(start: .zero, end: TextAreaCursor(row: 0, col: 4))
        let before = editing.state
        let screen = Screen(height: 5, TextArea(text: Binding(get: { editing.text }, set: { editing.text = $0 }),
                                                state: Binding(get: { editing.state }, set: { editing.state = $0 }),
                                                visibleHeight: 5))
        #expect(screen.wheel(.down, at: 2, 1, steps: 3))
        let rows = screen.draw()
        #expect(rows.first?.hasPrefix("line 3") == true, "\(rows)")
        #expect(editing.state.cursor == before.cursor)
        #expect(editing.state.selection == before.selection)
    }

    @Test func typingBringsTheCaretBackIntoView() {
        let editing = Editing()
        let screen = Screen(height: 5, TextArea(text: Binding(get: { editing.text }, set: { editing.text = $0 }),
                                                state: Binding(get: { editing.state }, set: { editing.state = $0 }),
                                                visibleHeight: 5))
        screen.wheel(.down, at: 2, 1, steps: 10)
        screen.draw()
        editing.state.cursor = TextAreaCursor(row: 0, col: 1)
        let rows = screen.draw()
        #expect(rows.first?.hasPrefix("line 0") == true, "a moved caret is shown again: \(rows)")
    }
}

@Suite("The wheel beside an inspector")
@MainActor
struct InspectorWheelTests {

    // An inspector holds the keyboard, and a click beside it reaches
    // nothing. The wheel only moves the view: the transcript beside a review
    // scrolls, as it does beside Claude Code's /diff panel. A dialog's dim
    // still takes it.
    @Test func scrollsTheContentBesideIt() {
        let screen = Screen(width: 40, height: 6, ScrollView(.vertical) {
            VStack(spacing: 0) { ForEachWithID(0..<30, id: \.self) { row in Text("row \(row)") } }
        }
        .inspector(isPresented: .constant(true)) { Text("panel").focusable().frame(width: 12) })
        #expect(screen.wheel(.down, at: 2, 2))
        #expect(screen.scrollNodes().first?.scrollOffset == 1)
    }

    @Test func aDialogsDimStillTakesIt() {
        let screen = Screen(width: 40, height: 6, ScrollView(.vertical) {
            VStack(spacing: 0) { ForEachWithID(0..<30, id: \.self) { row in Text("row \(row)") } }
        }
        .modal(isPresented: true) { Text("dialog").focusable() })
        #expect(!screen.wheel(.down, at: 0, 0))
    }
}
