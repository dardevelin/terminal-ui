import Testing
@testable import TerminalUIConfig

@Suite("KeyCombo")
struct KeyComboTests {

    @Test("parse single character")
    func parseCharacter() {
        let combo = KeyCombo.parse("a")
        #expect(combo == KeyCombo(key: .character("a")))
    }

    @Test("parse function key")
    func parseFunctionKey() {
        #expect(KeyCombo.parse("F1") == KeyCombo(key: .f(1)))
        #expect(KeyCombo.parse("f2") == KeyCombo(key: .f(2)))
        #expect(KeyCombo.parse("F12") == KeyCombo(key: .f(12)))
    }

    @Test("reject out-of-range function keys")
    func rejectBadFunctionKeys() {
        #expect(KeyCombo.parse("F0") == nil)
        #expect(KeyCombo.parse("F25") == nil)
        #expect(KeyCombo.parse("Fabc") == nil)
    }

    @Test("parse named keys")
    func parseNamedKeys() {
        #expect(KeyCombo.parse("enter")?.key == .enter)
        #expect(KeyCombo.parse("return")?.key == .enter)
        #expect(KeyCombo.parse("tab")?.key == .tab)
        #expect(KeyCombo.parse("escape")?.key == .escape)
        #expect(KeyCombo.parse("esc")?.key == .escape)
        #expect(KeyCombo.parse("backspace")?.key == .backspace)
        #expect(KeyCombo.parse("delete")?.key == .delete)
        #expect(KeyCombo.parse("up")?.key == .up)
        #expect(KeyCombo.parse("down")?.key == .down)
        #expect(KeyCombo.parse("left")?.key == .left)
        #expect(KeyCombo.parse("right")?.key == .right)
        #expect(KeyCombo.parse("home")?.key == .home)
        #expect(KeyCombo.parse("end")?.key == .end)
        #expect(KeyCombo.parse("pageup")?.key == .pageUp)
        #expect(KeyCombo.parse("pagedown")?.key == .pageDown)
    }

    @Test("parse ctrl modifier")
    func parseCtrl() {
        let combo = KeyCombo.parse("ctrl+d")
        #expect(combo == KeyCombo(key: .character("d"), ctrl: true))
    }

    @Test("parse alt modifier aliases")
    func parseAlt() {
        #expect(KeyCombo.parse("alt+x") == KeyCombo(key: .character("x"), alt: true))
        #expect(KeyCombo.parse("opt+x") == KeyCombo(key: .character("x"), alt: true))
        #expect(KeyCombo.parse("option+x") == KeyCombo(key: .character("x"), alt: true))
    }

    @Test("parse shift modifier")
    func parseShift() {
        let combo = KeyCombo.parse("shift+tab")
        #expect(combo == KeyCombo(key: .tab, shift: true))
    }

    @Test("parse multiple modifiers")
    func parseMultipleModifiers() {
        let combo = KeyCombo.parse("ctrl+shift+F2")
        #expect(combo == KeyCombo(key: .f(2), ctrl: true, shift: true))
    }

    @Test("parse alt+enter")
    func parseAltEnter() {
        let combo = KeyCombo.parse("alt+enter")
        #expect(combo == KeyCombo(key: .enter, alt: true))
    }

    @Test("reject unknown modifier")
    func rejectUnknownModifier() {
        #expect(KeyCombo.parse("super+a") == nil)
        #expect(KeyCombo.parse("hyper+a") == nil)
    }

    @Test("meta is Alt, as readline and Emacs name it")
    func metaIsAlt() {
        #expect(KeyCombo.parse("meta+a") == KeyCombo(key: .character("a"), alt: true))
    }

    @Test("reject empty string")
    func rejectEmpty() {
        #expect(KeyCombo.parse("") == nil)
    }

    @Test("reject multi-character key part")
    func rejectMultiCharKey() {
        #expect(KeyCombo.parse("abc") == nil)
    }

    @Test("is case insensitive")
    func caseInsensitive() {
        #expect(KeyCombo.parse("CTRL+D") == KeyCombo(key: .character("d"), ctrl: true))
        #expect(KeyCombo.parse("Ctrl+Shift+f1") == KeyCombo(key: .f(1), ctrl: true, shift: true))
    }

    @Test("description round-trips")
    func descriptionRoundTrip() {
        let originals: [String] = ["a", "F1", "enter", "tab", "up"]
        for s in originals {
            guard let combo = KeyCombo.parse(s) else {
                Issue.record("parse failed for \(s)")
                continue
            }
            #expect(KeyCombo.parse(combo.description) == combo)
        }
    }

    @Test("description with modifiers")
    func descriptionWithModifiers() {
        let combo = KeyCombo(key: .f(2), ctrl: true, shift: true)
        #expect(combo.description == "ctrl+shift+F2")
    }
}
