import Testing
@testable import TerminalUI

// The same key does the same thing in every text input. Each input kept its
// own editing keys, so Ctrl+A moved to the line start in TextArea and did
// nothing a field away, and Ctrl+K killed nothing anywhere. These cases run
// one table of keys through TextInput, TextArea and PromptInput alike.

/// A text input reduced to what the table needs: type keys into `marked`
/// text — the cursor at its `|` — and read back the text, marked.
private protocol EditingInput: Sendable {
    static var name: String { get }
    static var isMultiline: Bool { get }
    static func press(_ events: [KeyEvent], on marked: String, textEditing: TextEditingContext) -> String
}

private enum TextInputUnderTest: EditingInput {
    static let name = "TextInput"
    static let isMultiline = false

    static func press(_ events: [KeyEvent], on marked: String, textEditing: TextEditingContext) -> String {
        var (text, cursor) = MarkedText.split(marked)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let cursorBinding = Binding(get: { cursor }, set: { cursor = $0 })
        for event in events {
            _ = TextInput.handleKey(event, text: textBinding, cursor: cursorBinding,
                                    maxLength: nil, textEditing: textEditing)
        }
        return MarkedText.mark(text, cursor: cursor)
    }
}

private enum TextAreaUnderTest: EditingInput {
    static let name = "TextArea"
    static let isMultiline = true

    static func press(_ events: [KeyEvent], on marked: String, textEditing: TextEditingContext) -> String {
        var (text, start) = MarkedText.split(marked)
        let position = TextLines.position(of: start, in: TextLines.split(text))
        var state = TextAreaState()
        state.cursor = TextAreaCursor(row: position.row, col: position.col)
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        for event in events {
            _ = TextArea.handleKey(event, text: textBinding, state: stateBinding,
                                   visibleHeight: 10, textEditing: textEditing)
        }
        return MarkedText.mark(text, cursor: TextLines.offset(row: state.cursor.row, col: state.cursor.col,
                                                             in: TextLines.split(text)))
    }
}

private enum PromptInputUnderTest: EditingInput {
    static let name = "PromptInput"
    static let isMultiline = true

    static func press(_ events: [KeyEvent], on marked: String, textEditing: TextEditingContext) -> String {
        var (text, start) = MarkedText.split(marked)
        let position = TextLines.position(of: start, in: TextLines.split(text))
        var state = PromptInputState()
        state.cursorRow = position.row
        state.cursorCol = position.col
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        for event in events {
            _ = PromptInput.handleKey(event, text: textBinding, state: stateBinding, onSubmit: nil,
                                      promptWidth: 2, maxVisibleLines: 10, textEditing: textEditing)
        }
        return MarkedText.mark(text, cursor: TextLines.offset(row: state.cursorRow, col: state.cursorCol,
                                                             in: TextLines.split(text)))
    }
}

private let inputs: [any EditingInput.Type] = [
    TextInputUnderTest.self, TextAreaUnderTest.self, PromptInputUnderTest.self,
]

/// An editing context with a kill buffer of its own, as an app gets from
/// its runtime: the default one is shared, and tests run in parallel.
private func isolatedEditing(_ keymap: TextKeymap = .standard) -> TextEditingContext {
    var environment = EnvironmentValues()
    environment.killBuffer = KillBuffer()
    environment.textKeymap = keymap
    return environment.textEditing
}

private func key(_ key: Key, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: key, modifiers: modifiers)
}

private func ctrl(_ letter: Character) -> KeyEvent { key(.character(letter), .ctrl) }
private func alt(_ letter: Character) -> KeyEvent { key(.character(letter), .alt) }

/// One row of the table: keys pressed on `start`, and the text they leave.
private struct EditCase: CustomTestStringConvertible, Sendable {
    let label: String
    let keys: [KeyEvent]
    let start: String
    let expected: String
    var testDescription: String { label }
}

private let singleLineCases: [EditCase] = [
    EditCase(label: "Ctrl+A to line start", keys: [ctrl("a")], start: "alpha be|ta gamma", expected: "|alpha beta gamma"),
    EditCase(label: "Home to line start", keys: [key(.home)], start: "alpha be|ta gamma", expected: "|alpha beta gamma"),
    EditCase(label: "Ctrl+E to line end", keys: [ctrl("e")], start: "alpha be|ta gamma", expected: "alpha beta gamma|"),
    EditCase(label: "End to line end", keys: [key(.end)], start: "alpha be|ta gamma", expected: "alpha beta gamma|"),
    EditCase(label: "Ctrl+B back a character", keys: [ctrl("b")], start: "alpha be|ta gamma", expected: "alpha b|eta gamma"),
    EditCase(label: "Ctrl+F forward a character", keys: [ctrl("f")], start: "alpha be|ta gamma", expected: "alpha bet|a gamma"),
    EditCase(label: "Alt+B back a word", keys: [alt("b")], start: "alpha be|ta gamma", expected: "alpha |beta gamma"),
    EditCase(label: "Alt+Left back a word", keys: [key(.left, .alt)], start: "alpha be|ta gamma", expected: "alpha |beta gamma"),
    EditCase(label: "Alt+F forward a word", keys: [alt("f")], start: "alpha be|ta gamma", expected: "alpha beta| gamma"),
    EditCase(label: "Ctrl+K kills to line end", keys: [ctrl("k")], start: "alpha be|ta gamma", expected: "alpha be|"),
    EditCase(label: "Ctrl+U kills to line start", keys: [ctrl("u")], start: "alpha be|ta gamma", expected: "|ta gamma"),
    EditCase(label: "Ctrl+W kills back to whitespace", keys: [ctrl("w")], start: "run --flag=x|", expected: "run |"),
    EditCase(label: "Alt+Backspace kills a word", keys: [key(.backspace, .alt)], start: "path/to/file|", expected: "path/to/|"),
    EditCase(label: "Alt+D kills a word forward", keys: [alt("d")], start: "alpha |beta gamma", expected: "alpha | gamma"),
    EditCase(label: "Ctrl+D deletes forward", keys: [ctrl("d")], start: "alpha be|ta", expected: "alpha be|a"),
    EditCase(label: "Backspace deletes back", keys: [key(.backspace)], start: "alpha be|ta", expected: "alpha b|ta"),
    EditCase(label: "Ctrl+Y yanks the last kill", keys: [ctrl("k"), ctrl("a"), ctrl("y")],
             start: "alpha be|ta", expected: "ta|alpha be"),
]

private let multilineCases: [EditCase] = [
    EditCase(label: "Ctrl+A to the current line's start", keys: [ctrl("a")], start: "one\ntw|o\nthree", expected: "one\n|two\nthree"),
    EditCase(label: "Ctrl+E to the current line's end", keys: [ctrl("e")], start: "one\nt|wo\nthree", expected: "one\ntwo|\nthree"),
    EditCase(label: "Ctrl+K kills to the line's end", keys: [ctrl("k")], start: "one\nt|wo\nthree", expected: "one\nt|\nthree"),
    EditCase(label: "Ctrl+K at a line's end joins the next", keys: [ctrl("k")], start: "one|\ntwo", expected: "one|two"),
    EditCase(label: "Ctrl+U at a line's start joins the previous", keys: [ctrl("u")], start: "one\n|two", expected: "one|two"),
    EditCase(label: "Ctrl+P up a row", keys: [ctrl("p")], start: "one\ntw|o", expected: "on|e\ntwo"),
    EditCase(label: "Ctrl+N down a row", keys: [ctrl("n")], start: "o|ne\ntwo", expected: "one\nt|wo"),
    EditCase(label: "Ctrl+Home to the text's start", keys: [key(.home, .ctrl)], start: "one\ntw|o", expected: "|one\ntwo"),
    EditCase(label: "Alt+> to the text's end", keys: [alt(">")], start: "o|ne\ntwo", expected: "one\ntwo|"),
    EditCase(label: "Shift+Enter starts a new line", keys: [key(.enter, .shift)], start: "one|two", expected: "one\n|two"),
    EditCase(label: "Ctrl+Shift+Enter starts a new line", keys: [key(.enter, [.ctrl, .shift])], start: "one|two", expected: "one\n|two"),
]

@Suite("Every text input edits the same way")
struct TextEditingConformanceTests {

    @Test("Single-line editing keys", arguments: singleLineCases)
    fileprivate func singleLine(_ edit: EditCase) {
        for input in inputs {
            let result = input.press(edit.keys, on: edit.start, textEditing: isolatedEditing())
            #expect(result == edit.expected, "\(input.name): \(edit.label)")
        }
    }

    @Test("Multi-line editing keys", arguments: multilineCases)
    fileprivate func multiline(_ edit: EditCase) {
        for input in inputs where input.isMultiline {
            let result = input.press(edit.keys, on: edit.start, textEditing: isolatedEditing())
            #expect(result == edit.expected, "\(input.name): \(edit.label)")
        }
    }

    @Test("A kill in one input can be yanked into another")
    func oneKillBufferPerApp() {
        let textEditing = isolatedEditing()
        _ = TextInputUnderTest.press([ctrl("k")], on: "keep|gone", textEditing: textEditing)
        #expect(PromptInputUnderTest.press([ctrl("y")], on: "|", textEditing: textEditing) == "gone|")
    }

    @Test("An edit with nothing to do passes the key on: Ctrl+D on an empty line")
    func noOpPassesTheKeyOn() {
        var text = ""
        var cursor = 0
        let result = TextInput.handleKey(ctrl("d"), text: Binding(get: { text }, set: { text = $0 }),
                                         cursor: Binding(get: { cursor }, set: { cursor = $0 }),
                                         maxLength: nil, textEditing: isolatedEditing())
        #expect(result == .ignored)
    }

    @Test("A single-line field leaves Return and the rows to the app")
    func singleLineFieldPassesRowsAndReturnOn() {
        var text = "line"
        var cursor = 2
        for event in [key(.enter), key(.up), ctrl("p"), key(.down)] {
            let result = TextInput.handleKey(event, text: Binding(get: { text }, set: { text = $0 }),
                                             cursor: Binding(get: { cursor }, set: { cursor = $0 }),
                                             maxLength: nil, textEditing: isolatedEditing())
            #expect(result == .ignored, "\(event.key)")
        }
    }

    @Test("A prompt can send on Shift+Enter and take Enter as a new line")
    func promptSubmitRebound() {
        let rebound = isolatedEditing(.standard.merging([
            .keyboard(.enter, []): [.insertNewline],
            .keyboard(.enter, .shift): [.submit],
        ]))
        var text = "one"
        var state = PromptInputState()
        state.cursorCol = 3
        var sent: [String] = []
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        func press(_ event: KeyEvent) {
            _ = PromptInput.handleKey(event, text: textBinding, state: stateBinding,
                                      onSubmit: { sent.append($0) },
                                      promptWidth: 2, maxVisibleLines: 10, textEditing: rebound)
        }
        press(key(.enter))
        press(key(.character("2")))
        #expect(text == "one\n2")
        #expect(sent.isEmpty)
        press(key(.enter, .shift))
        #expect(sent == ["one\n2"])
    }

    @Test("An app can rebind a key")
    func rebinding() {
        let rebound = isolatedEditing(.standard.merging([.keyboard(.character("k"), .ctrl): []]))
        for input in inputs {
            let result = input.press([ctrl("k")], on: "alpha|beta", textEditing: rebound)
            #expect(result == "alpha|beta", "\(input.name): an unbound Ctrl+K is ignored")
        }
    }
}

@Suite("A prompt's paste markers move with its text")
struct PromptMarkerTests {

    /// A prompt holding `text`, its cursor at `cursor`, with one collapsed
    /// marker over `marker`.
    private func prompt(_ text: String, cursor: Int, marker: Range<Int>) -> (String, PromptInputState) {
        var state = PromptInputState()
        state.cursorCol = cursor
        state.references = [PasteReference(id: 1, bufferID: 1, start: marker.lowerBound,
                                           length: marker.count)]
        return (text, state)
    }

    private func press(_ events: [KeyEvent], text: inout String, state: inout PromptInputState) {
        let textEditing = isolatedEditing()
        var current = text
        var currentState = state
        let textBinding = Binding(get: { current }, set: { current = $0 })
        let stateBinding = Binding(get: { currentState }, set: { currentState = $0 })
        for event in events {
            _ = PromptInput.handleKey(event, text: textBinding, state: stateBinding, onSubmit: nil,
                                      promptWidth: 2, maxVisibleLines: 10, textEditing: textEditing)
        }
        text = current
        state = currentState
    }

    @Test("A character typed before a marker moves it")
    func typingBeforeAMarker() {
        var (text, state) = prompt("ab<pasted>", cursor: 0, marker: 2..<10)
        press([key(.character("x"))], text: &text, state: &state)
        #expect(text == "xab<pasted>")
        #expect(state.references.first?.start == 3)
    }

    @Test("A new line before a marker moves it")
    func newLineBeforeAMarker() {
        var (text, state) = prompt("ab<pasted>", cursor: 0, marker: 2..<10)
        press([key(.enter, .alt)], text: &text, state: &state)
        #expect(text == "\nab<pasted>")
        #expect(state.references.first?.start == 3)
    }

    @Test("Going into history and back restores the draft's markers")
    func draftMarkersSurviveHistory() {
        var (text, state) = prompt("ab<pasted>", cursor: 10, marker: 2..<10)
        state.history = [PromptInputHistoryEntry(text: "older", buffers: [], references: [])]
        press([key(.up)], text: &text, state: &state)
        #expect(text == "older")
        press([key(.down)], text: &text, state: &state)
        #expect(text == "ab<pasted>")
        #expect(state.references.map(\.start) == [2])
    }
}
