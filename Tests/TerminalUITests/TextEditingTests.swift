import Testing
@testable import TerminalUI

// Text editing is one set of named commands — readline's, Emacs's, Cocoa's
// standard key bindings — performed by one engine over the text every input
// shares: a string and a cursor offset into it. Each input used to carry its
// own subset, so Ctrl+K worked in none of them, Ctrl+A in one, and the same
// key meant different things a field apart.

private func buffer(_ marked: String, atomic: [Range<Int>] = []) -> TextEditingBuffer {
    let (text, cursor) = MarkedText.split(marked)
    return TextEditingBuffer(text: Array(text), cursor: cursor, atomicRanges: atomic)
}

private func marked(_ buffer: TextEditingBuffer) -> String {
    MarkedText.mark(buffer.text, cursor: buffer.cursor)
}

/// Performs `command` on `marked` and returns the result, marked.
private func after(_ command: TextEditCommand, _ start: String,
                   atomic: [Range<Int>] = [], killBuffer: KillBuffer = KillBuffer()) -> String {
    var edited = buffer(start, atomic: atomic)
    _ = edited.perform(command, killBuffer: killBuffer)
    return marked(edited)
}

@Suite("Text editing commands — one engine for every input")
struct TextEditingCommandTests {

    @Test("Line start and end are the current line's, not the text's")
    func lineStartAndEnd() {
        #expect(after(.moveToLineStart, "alpha beta\ngam|ma") == "alpha beta\n|gamma")
        #expect(after(.moveToLineEnd, "alpha beta\ngam|ma") == "alpha beta\ngamma|")
        #expect(after(.moveToLineEnd, "al|pha beta\ngamma") == "alpha beta|\ngamma")
    }

    @Test("Word movement goes by letters and digits, as Emacs's forward-word")
    func wordMovement() {
        #expect(after(.moveWordForward, "|alpha beta") == "alpha| beta")
        #expect(after(.moveWordForward, "alpha| beta") == "alpha beta|")
        #expect(after(.moveWordForward, "alpha|\ngamma") == "alpha\ngamma|")
        #expect(after(.moveWordBackward, "alpha beta|") == "alpha |beta")
        #expect(after(.moveWordBackward, "alpha |beta") == "|alpha beta")
        #expect(after(.moveWordBackward, "path/to/file|") == "path/to/|file")
    }

    @Test("Moving past either end hits a wall")
    func walls() {
        var start = buffer("|ab")
        #expect(start.perform(.moveBackward, killBuffer: KillBuffer()) == .hitWall(.leftEdge))
        var end = buffer("ab|")
        #expect(end.perform(.moveForward, killBuffer: KillBuffer()) == .hitWall(.rightEdge))
    }

    @Test("Ctrl+K kills to the end of the line; at its end, the line break")
    func killToLineEnd() {
        #expect(after(.deleteToLineEnd, "alpha |beta\ngamma") == "alpha |\ngamma")
        #expect(after(.deleteToLineEnd, "alpha beta|\ngamma") == "alpha beta|gamma")
        #expect(after(.deleteToLineEnd, "alpha beta|") == "alpha beta|")
    }

    @Test("Ctrl+U kills to the start of the line; at its start, the line break")
    func killToLineStart() {
        #expect(after(.deleteToLineStart, "alpha\ngam|ma") == "alpha\n|ma")
        #expect(after(.deleteToLineStart, "alpha\n|gamma") == "alpha|gamma")
        #expect(after(.deleteToLineStart, "|alpha") == "|alpha")
    }

    @Test("Ctrl+W kills back to whitespace: a whole path or flag at once")
    func killToWhitespace() {
        #expect(after(.deleteToWhitespaceBackward, "cd ~/src/app --flag=x|") == "cd ~/src/app |")
        #expect(after(.deleteToWhitespaceBackward, "ab cd  |") == "ab |")
    }

    @Test("Alt+Backspace and Alt+D kill one word")
    func killWord() {
        #expect(after(.deleteWordBackward, "path/to/file|") == "path/to/|")
        #expect(after(.deleteWordForward, "|alpha beta") == "| beta")
    }

    @Test("Characters delete one at a time, and nothing past either end")
    func characterDeletes() {
        #expect(after(.deleteBackward, "ab|c") == "a|c")
        #expect(after(.deleteForward, "ab|c") == "ab|")
        #expect(after(.deleteBackward, "|abc") == "|abc")
        #expect(after(.deleteForward, "abc|") == "abc|")
    }

    @Test("Yank puts back the last kill, at the cursor")
    func yank() {
        let killBuffer = KillBuffer()
        var edited = buffer("alpha |beta")
        _ = edited.perform(.deleteToLineEnd, killBuffer: killBuffer)
        edited.cursor = 0
        _ = edited.perform(.yank, killBuffer: killBuffer)
        #expect(marked(edited) == "beta|alpha ")
    }

    @Test("A kill reports the range it replaced, for inputs that track offsets")
    func editReportsItsRange() {
        var edited = buffer("alpha |beta")
        #expect(edited.perform(.deleteToLineEnd, killBuffer: KillBuffer())
                == .edited(replaced: 6..<10, insertedCount: 0))
    }

    @Test("An atomic range is deleted whole or not at all")
    func atomicRangesDelete() {
        let marker = 2..<7
        #expect(after(.deleteBackward, "ab[XYZ]|cd", atomic: [marker]) == "ab|cd")
        #expect(after(.deleteForward, "ab|[XYZ]cd", atomic: [marker]) == "ab|cd")
        #expect(after(.deleteToLineEnd, "ab[X|YZ]cd", atomic: [marker]) == "ab|")
    }

    @Test("The cursor steps over an atomic range, never into it")
    func atomicRangesMove() {
        let marker = 2..<7
        #expect(after(.moveForward, "ab|[XYZ]cd", atomic: [marker]) == "ab[XYZ]|cd")
        #expect(after(.moveBackward, "ab[XYZ]|cd", atomic: [marker]) == "ab|[XYZ]cd")
    }

    @Test("An edit keeps the atomic ranges after it in step with the text")
    func atomicRangesFollowEdits() {
        var edited = buffer("x|y[XYZ]", atomic: [3..<8])
        _ = edited.perform(.deleteBackward, killBuffer: KillBuffer())
        #expect(edited.atomicRanges == [2..<7])
    }

    @Test("A move that goes nowhere still moved; an edit with nothing to do did not")
    func noOps() {
        var start = buffer("|ab")
        #expect(start.perform(.moveToLineStart, killBuffer: KillBuffer()) == .moved)
        #expect(start.perform(.deleteBackward, killBuffer: KillBuffer()) == .unchanged)
        #expect(start.perform(.yank, killBuffer: KillBuffer()) == .unchanged)
    }

    @Test("A command no input declares is the app's")
    func unknownCommand() {
        var edited = buffer("a|b")
        #expect(edited.perform("openPalette", killBuffer: KillBuffer()) == .unsupported)
    }
}

@Suite("TextKeymap — the standard bindings are readline's")
struct TextKeymapTests {

    private func command(_ key: Key, _ modifiers: KeyModifiers = []) -> TextEditCommand? {
        TextKeymap.standard.command(for: KeyEvent(key: key, modifiers: modifiers))
    }

    @Test("Each command has the keys Claude Code, Crush and readline give it")
    func standardBindings() {
        #expect(command(.character("a"), .ctrl) == .moveToLineStart)
        #expect(command(.home) == .moveToLineStart)
        #expect(command(.character("e"), .ctrl) == .moveToLineEnd)
        #expect(command(.end) == .moveToLineEnd)
        #expect(command(.character("k"), .ctrl) == .deleteToLineEnd)
        #expect(command(.character("u"), .ctrl) == .deleteToLineStart)
        #expect(command(.character("w"), .ctrl) == .deleteToWhitespaceBackward)
        #expect(command(.backspace, .alt) == .deleteWordBackward)
        #expect(command(.character("d"), .alt) == .deleteWordForward)
        #expect(command(.character("d"), .ctrl) == .deleteForward)
        #expect(command(.character("b"), .alt) == .moveWordBackward)
        #expect(command(.left, .alt) == .moveWordBackward)
        #expect(command(.character("f"), .alt) == .moveWordForward)
        #expect(command(.right, .alt) == .moveWordForward)
        #expect(command(.character("y"), .ctrl) == .yank)
        #expect(command(.character("z"), .ctrl) == .undo)
        #expect(command(.character("z"), [.ctrl, .shift]) == .redo)
    }

    @Test("A typed character is not a command")
    func plainCharacters() {
        #expect(command(.character("k")) == nil)
    }

    @Test("Shift with a movement key is the movement, extending a selection")
    func shiftedMovement() {
        #expect(command(.left, .shift) == .moveBackward)
        #expect(command(.character("k"), [.ctrl, .shift]) == nil)
    }
}
