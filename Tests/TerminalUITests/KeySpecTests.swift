import Testing
@testable import TerminalUI

// A keymap file names keys as a person writes them — `ctrl+k`,
// `alt+backspace`, `shift+enter` — and the same spelling lists them back.

@Suite("Key specs — chords written as a person writes them")
struct KeySpecTests {

    private func binding(_ spec: String) throws(KeySpecError) -> InputBinding {
        try InputBinding(keySpec: spec)
    }

    @Test("Modifiers and a key, in any case, in any order")
    func modifiersAndKeys() throws {
        #expect(try binding("ctrl+k") == .keyboard(.character("k"), .ctrl))
        #expect(try binding("Ctrl+K") == .keyboard(.character("k"), .ctrl))
        #expect(try binding("shift+ctrl+z") == .keyboard(.character("z"), [.ctrl, .shift]))
        #expect(try binding("option+left") == .keyboard(.left, .alt))
        #expect(try binding("meta+b") == .keyboard(.character("b"), .alt))
        #expect(try binding("alt+backspace") == .keyboard(.backspace, .alt))
        #expect(try binding("shift+enter") == .keyboard(.enter, .shift))
        #expect(try binding("pagedown") == .keyboard(.pageDown, []))
        #expect(try binding("f5") == .keyboard(.f(5), []))
        #expect(try binding("alt+<") == .keyboard(.character("<"), .alt))
        #expect(try binding("space") == .keyboard(.character(" "), []))
    }

    @Test("Every chord reads back as it was written")
    func roundTrip() throws {
        for spec in ["ctrl+k", "ctrl+shift+z", "alt+left", "shift+enter", "pageup", "F12", "alt+<", "space", "ctrl++"] {
            #expect(try binding(spec).keySpec == spec)
        }
    }

    @Test("Command never reaches an app: the error says what to bind instead")
    func command() {
        #expect(throws: KeySpecError.self) { try binding("cmd+k") }
        do throws(KeySpecError) {
            _ = try binding("cmd+left")
        } catch {
            #expect(error.description.contains("ctrl+a"))
        }
    }

    @Test("An unknown key or modifier is an error that lists the names")
    func unknown() {
        #expect(throws: KeySpecError.self) { try binding("ctl+k") }
        #expect(throws: KeySpecError.self) { try binding("ctrl+escapee") }
        #expect(throws: KeySpecError.self) { try binding("ctrl+") }
        do throws(KeySpecError) {
            _ = try binding("ctrl+escapee")
        } catch {
            #expect(error.description.contains("pagedown"), "the error lists the key names")
        }
    }
}
