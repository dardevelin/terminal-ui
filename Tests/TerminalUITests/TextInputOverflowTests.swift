import Testing
@testable import TerminalUI

// TextInput overflow must virtual-scroll so the tail + cursor
// remain visible, regardless of how the containing layout sizes the rect.
// These assertions cover the rect actually granted to the input, not what
// GeometryReader reported, so they catch the prior `-3` breathing-room bug
// that was subtracting cells the renderer was already giving back via the
// rect-clip enforcement in GraphRenderer.

@Suite("TextInput — overflow scrolls tail into view")
@MainActor
struct TextInputOverflowTests {

    /// Rendered focused: the cursor these cases place is drawn only while
    /// the field holds focus.
    private func renderInput(value: String, prompt: String = "", width: Int) -> CellBuffer {
        var text = value
        let binding = Binding(get: { text }, set: { text = $0 })
        let view = TextInput(prompt, text: binding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var focused = EnvironmentValues()
        focused.focusedID = focusableID(in: graph.root!)
        var buffer = CellBuffer(width: width, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: width, height: 1))
        GraphContext.$currentEnvironment.withValue(focused) {
            graph.update(from: view)
            GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        }
        return buffer
    }

    private func focusableID(in node: AttributeNode) -> NodeID? {
        if node.isFocusable { return node.id }
        return node.children.lazy.compactMap { focusableID(in: $0) }.first
    }

    @Test("long value ends with cursor at right-most content cell")
    func longValueShowsTailPlusCursor() {
        // 40 chars into a 10-wide input. Tail should end with a cursor `│`,
        // preceded by the last typed chars.
        let value = String(repeating: "a", count: 20) + "tail"
        let buffer = renderInput(value: value, width: 10)
        // Last cell is the cursor glyph.
        #expect(buffer[9, 0].character == "│",
                "rightmost cell should be cursor, got '\(buffer[9, 0].character)'")
        // A recognizable tail char is visible just before the cursor.
        #expect(buffer[8, 0].character == "l",
                "'tail' final char should sit one cell left of cursor, got '\(buffer[8, 0].character)'")
    }

    @Test("short value fits without clipping")
    func shortValueFits() {
        let buffer = renderInput(value: "abc", width: 10)
        #expect(buffer[0, 0].character == "a")
        #expect(buffer[1, 0].character == "b")
        #expect(buffer[2, 0].character == "c")
        #expect(buffer[3, 0].character == "│",
                "cursor should sit right after typed text, got '\(buffer[3, 0].character)'")
    }

    @Test("prompt reserves cells but still leaves room for value")
    func promptCoexistsWithValue() {
        let buffer = renderInput(value: "hi", prompt: "> ", width: 10)
        #expect(buffer[0, 0].character == ">")
        #expect(buffer[1, 0].character == " ")
        #expect(buffer[2, 0].character == "h")
        #expect(buffer[3, 0].character == "i")
        #expect(buffer[4, 0].character == "│",
                "cursor expected at col 4 (prompt + 'hi'), got '\(buffer[4, 0].character)'")
    }
}
