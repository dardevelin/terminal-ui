import Testing
@testable import TerminalUI

// TextArea undo/redo.
//
// Each text-mutating key (character, enter, backspace, delete,
// selection-replace, paste) pushes a snapshot of (text, cursor,
// selection) BEFORE the mutation. Ctrl+Z restores the prior
// snapshot; Ctrl+Shift+Z (or Ctrl+Y) re-applies a popped snapshot.
//
// Tests follow the live edit path through `TextArea.handleKey` so
// the wiring (snapshot point + Ctrl+Z dispatch) is what's pinned.

/// Reference-typed box so test fixtures can pass `Binding`-shaped
/// access without inout-parameter capture errors. `var text` and
/// `var state` survive the closure escape because the box is a
/// class.
@MainActor
private final class TextAreaFixture {
    var text: String = ""
    var state: TextAreaState = TextAreaState()

    var textBinding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0 })
    }
    var stateBinding: Binding<TextAreaState> {
        Binding(get: { self.state }, set: { self.state = $0 })
    }

    func drive(_ key: KeyEvent) {
        _ = TextArea.handleKey(
            key, text: textBinding, state: stateBinding,
            visibleHeight: 10
        )
    }
}

@Suite("TextArea — undo/redo via Ctrl+Z / Ctrl+Shift+Z")
@MainActor
struct TextAreaUndoRedoTests {

    private func drive(_ fix: TextAreaFixture, key: KeyEvent) {
        fix.drive(key)
    }

    @Test("Ctrl+Z reverts a typed character")
    func undoCharacter() {
        let fix = TextAreaFixture()
        fix.drive(KeyEvent(key: .character("a")))
        #expect(fix.text == "a")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "", "Ctrl+Z reverts the character insertion")
    }

    @Test("Ctrl+Z reverts an Enter (newline insertion)")
    func undoNewline() {
        let fix = TextAreaFixture()
        fix.text = "first"
        fix.state.cursor = TextAreaCursor(row: 0, col: 5)
        fix.drive(KeyEvent(key: .enter))
        #expect(fix.text == "first\n", "Enter inserted newline")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "first", "Ctrl+Z reverts the newline insertion")
    }

    @Test("Ctrl+Z reverts a Backspace")
    func undoBackspace() {
        let fix = TextAreaFixture()
        fix.text = "hello"
        fix.state.cursor = TextAreaCursor(row: 0, col: 5)
        fix.drive(KeyEvent(key: .backspace))
        #expect(fix.text == "hell")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "hello", "Ctrl+Z reverts the backspace")
    }

    @Test("Ctrl+Shift+Z re-applies an undone edit")
    func redoAfterUndo() {
        let fix = TextAreaFixture()
        fix.drive(KeyEvent(key: .character("X")))
        #expect(fix.text == "X")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "")
        fix.drive(KeyEvent(key: .character("z"), modifiers: [.ctrl, .shift]))
        #expect(fix.text == "X", "Ctrl+Shift+Z re-applies the previously-undone insertion")
    }

    @Test("Multiple edits — undo walks back in order")
    func undoMultipleSteps() {
        let fix = TextAreaFixture()
        fix.drive(KeyEvent(key: .character("a")))
        fix.drive(KeyEvent(key: .character("b")))
        fix.drive(KeyEvent(key: .character("c")))
        #expect(fix.text == "abc")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "ab")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "a")
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "")
    }

    @Test("New edit after undo truncates the redo future")
    func newEditTruncatesRedo() {
        let fix = TextAreaFixture()
        fix.drive(KeyEvent(key: .character("a")))
        fix.drive(KeyEvent(key: .character("b")))
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "a")
        fix.drive(KeyEvent(key: .character("X")))
        #expect(fix.text == "aX")
        // Redo MUST be unavailable now — the prior 'b' future was
        // discarded by the new 'X' push.
        fix.drive(KeyEvent(key: .character("z"), modifiers: [.ctrl, .shift]))
        #expect(fix.text == "aX", "Ctrl+Shift+Z is a no-op when redo future was truncated")
    }

    @Test("Ctrl+Z on empty stack is a no-op (no crash)")
    func undoOnEmptyStack() {
        let fix = TextAreaFixture()
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "", "Ctrl+Z on virgin state is a graceful no-op")
    }

    @Test("Cursor + selection round-trip with undo")
    func undoRestoresCursor() {
        let fix = TextAreaFixture()
        fix.text = "hello"
        fix.state.cursor = TextAreaCursor(row: 0, col: 3)
        fix.drive(KeyEvent(key: .character("X")))
        #expect(fix.text == "helXlo")
        #expect(fix.state.cursor.col == 4)
        fix.drive(KeyEvent(key: .character("z"), modifiers: .ctrl))
        #expect(fix.text == "hello")
        #expect(fix.state.cursor.col == 3, "undo restores cursor to pre-edit position")
    }
}
