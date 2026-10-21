import Testing
@testable import TerminalUI

// TextInput cursor model — Left/Right insertion-index navigation,
// home/end jumps, and edits at the cursor position rather than always
// at the tail. Without these, a user can only ever append/backspace at
// the right edge — the cursor glyph `│` is purely decorative.
//
// The view stores the cursor as an internal `@TerminalState`, projected
// to a `Binding<Int>` in `body` (NOT inside the GR closure — see
// `feedback_bindings_in_geometryreader.md`). Arrow handlers mutate the
// projected binding; render reads it to position the cursor glyph.

/// Build a TextInput with the given Binding, route it through a
/// FocusEngine with focus on its first focusable, dispatch the keys,
/// return the engine + graph + binding for follow-up assertions.
@MainActor
private func makeFocusedTextInput(textBinding: Binding<String>) -> (FocusEngine, AttributeGraph, TextInput) {
    let view = TextInput(text: textBinding)
    let graph = AttributeGraph()
    let engine = FocusEngine()
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
    }
    engine.rebuildIndex(root: graph.root!)
    engine.focusNext()  // land on first focusable
    return (engine, graph, view)
}

@MainActor
private func send(_ engine: FocusEngine, _ graph: AttributeGraph, _ key: Key) {
    _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
}

@Suite("TextInput cursor — Left/Right insertion-index navigation")
@MainActor
struct TextInputCursorNavigationTests {

    @Test("Right at end clamps — does not advance past length, subsequent typing appends")
    func rightAtEndIsClamped() {
        var value = "abc"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        send(engine, graph, .right)
        send(engine, graph, .character("X"))
        #expect(value == "abcX",
                "Right at end then 'X' should append; got '\(value)'")
    }

    @Test("Left moves cursor back; subsequent character inserts mid-buffer")
    func leftThenInsertMidBuffer() {
        var value = "ac"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        // Cursor starts at end (2). Left → 1. Type 'b' → "abc".
        send(engine, graph, .left)
        send(engine, graph, .character("b"))
        #expect(value == "abc",
                "Left then 'b' should insert mid-buffer producing 'abc'; got '\(value)'")
    }

    @Test("Left clamps at 0 — multiple Lefts past start don't underflow")
    func leftFromStartClamps() {
        var value = "ab"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        for _ in 0..<5 { send(engine, graph, .left) }
        send(engine, graph, .character("X"))
        #expect(value == "Xab",
                "5 Lefts then 'X' should prepend; got '\(value)'")
    }

    @Test("Backspace at cursor removes the char BEFORE the cursor")
    func backspaceMidBuffer() {
        var value = "abXc"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        // Cursor at end (4). Left → 3. Backspace removes index 2 ('X').
        send(engine, graph, .left)
        send(engine, graph, .backspace)
        #expect(value == "abc",
                "Backspace mid-buffer should remove 'X' producing 'abc'; got '\(value)'")
        send(engine, graph, .character("Y"))
        #expect(value == "abYc",
                "Insert at cursor after backspace should produce 'abYc'; got '\(value)'")
    }

    @Test("Backspace at cursor=0 is a no-op")
    func backspaceAtStart() {
        var value = "abc"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        for _ in 0..<5 { send(engine, graph, .left) }
        send(engine, graph, .backspace)
        #expect(value == "abc",
                "Backspace at cursor=0 must not alter the value; got '\(value)'")
    }

    @Test("Home jumps cursor to 0 — next character prepends")
    func homeJumpsToStart() {
        var value = "tail"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        send(engine, graph, .home)
        send(engine, graph, .character("X"))
        #expect(value == "Xtail",
                "Home then 'X' should prepend; got '\(value)'")
    }

    @Test("End jumps cursor to value.count — next character appends")
    func endJumpsToEnd() {
        var value = "head"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let (engine, graph, _) = makeFocusedTextInput(textBinding: textBinding)
        // Move to start, then End, then type — must append.
        send(engine, graph, .home)
        send(engine, graph, .end)
        send(engine, graph, .character("Z"))
        #expect(value == "headZ",
                "Home → End → 'Z' should append; got '\(value)'")
    }
}

@Suite("TextInput cursor — render places cursor glyph at insertion index")
@MainActor
struct TextInputCursorRenderTests {

    @Test("cursor glyph renders at the insertion index, not pinned to the tail")
    func cursorGlyphMidBuffer() {
        var value = "abcd"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding)
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        // Cursor at end (4). Left twice → cursor at 2.
        send(engine, graph, .left)
        send(engine, graph, .left)
        // Re-update so the render reflects post-key state, with focus bound
        // as the runtime binds it — the cursor is drawn only while focused.
        var focused = EnvironmentValues()
        focused.focusedID = engine.keyboardFocusID
        var buffer = CellBuffer(width: 16, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 16, height: 1))
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(focused) {
                graph.update(from: view)
                GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
            }
        }
        var row = ""
        for c in 0..<16 { row.append(buffer[c, 0].character) }
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        // Without cursor model the row is "abcd│"; with cursor model
        // it should be "ab│cd".
        #expect(trimmed.hasPrefix("ab│cd"),
                "expected cursor glyph mid-buffer ('ab│cd…'); got '\(trimmed)'")
    }
}
