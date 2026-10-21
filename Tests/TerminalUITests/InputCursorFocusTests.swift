import Testing
@testable import TerminalUI

// A cursor says where keys will go, so a field that does not hold focus must
// not draw one: two fields both showing a cursor leave the user guessing which
// one is listening. TextInput and TextArea drew theirs regardless — the defect
// PromptInput had — and now draw it only while focused.

@MainActor
private final class Harness {
    var text: String
    var areaState = TextAreaState()
    let graph = AttributeGraph()
    private(set) var focus: NodeID?

    init(text: String) { self.text = text }

    var textBinding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    var areaBinding: Binding<TextAreaState> { Binding(get: { self.areaState }, set: { self.areaState = $0 }) }

    func mount(_ view: some TerminalView) {
        GraphContext.$currentEnvironment.withValue(environment) { _ = graph.update(from: view) }
    }

    func setFocused(_ focused: Bool) {
        focus = focused ? focusableID(in: graph.root!) : nil
        graph.focusMoved(to: focus)
        GraphContext.$currentEnvironment.withValue(environment) { _ = graph.drain() }
    }

    func render(width: Int, height: Int) -> CellBuffer {
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentEnvironment.withValue(environment) {
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        return buffer
    }

    func firstRow(width: Int, height: Int = 1) -> String {
        let buffer = render(width: width, height: height)
        var line = String((0..<width).map { buffer[$0, 0].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    private var environment: EnvironmentValues {
        var env = EnvironmentValues()
        env.focusedID = focus
        return env
    }

    private func focusableID(in node: AttributeNode) -> NodeID? {
        if node.isFocusable { return node.id }
        for child in node.children {
            if let id = focusableID(in: child) { return id }
        }
        return nil
    }
}

@Suite("Text fields draw a cursor only while focused")
@MainActor
struct InputCursorFocusTests {

    @Test func aTextInputShowsItsCursorOnlyWhileFocused() {
        let harness = Harness(text: "hi")
        harness.mount(TextInput(text: harness.textBinding))
        #expect(harness.firstRow(width: 10) == "hi")

        harness.setFocused(true)
        #expect(harness.firstRow(width: 10) == "hi│")

        harness.setFocused(false)
        #expect(harness.firstRow(width: 10) == "hi")
    }

    @Test func anUnfocusedTextInputShowsItsPlaceholderWithoutACursor() {
        let harness = Harness(text: "")
        harness.mount(TextInput(text: harness.textBinding, placeholder: "name"))
        #expect(harness.firstRow(width: 10) == "name")

        harness.setFocused(true)
        #expect(harness.firstRow(width: 10) == "│name")
    }

    @Test func aTextAreaShowsItsCursorOnlyWhileFocused() {
        let harness = Harness(text: "ab")
        harness.mount(TextArea(text: harness.textBinding, state: harness.areaBinding, visibleHeight: 1))
        #expect(!hasCursor(harness.render(width: 10, height: 1)))

        harness.setFocused(true)
        #expect(hasCursor(harness.render(width: 10, height: 1)))

        harness.setFocused(false)
        #expect(!hasCursor(harness.render(width: 10, height: 1)))
    }

    @Test func aTextAreaCursorOnACharacterGoesWithFocus() {
        let harness = Harness(text: "ab")
        harness.areaState.cursor = TextAreaCursor(row: 0, col: 0)
        harness.mount(TextArea(text: harness.textBinding, state: harness.areaBinding, visibleHeight: 1))
        harness.setFocused(true)
        #expect(hasCursor(harness.render(width: 10, height: 1)))

        harness.setFocused(false)
        let unfocused = harness.render(width: 10, height: 1)
        #expect(!hasCursor(unfocused))
        #expect(unfocused[0, 0].character == "a")
    }
}

/// A TextArea's cursor is a cell on its cursor background — a reversed
/// character, or a block past the end of the line.
private func hasCursor(_ buffer: CellBuffer) -> Bool {
    (0..<buffer.width).contains { x in buffer[x, 0].style.background == .cyan }
}
