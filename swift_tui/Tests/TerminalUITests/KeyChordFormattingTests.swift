import Foundation
import Testing
@testable import TerminalUI

// HYP-333 Slice A — Mac-native modifier symbol rendering.
//
// KeyChord pairs a Key + KeyModifiers and renders user-visible strings
// in Apple's symbol convention (`⌥ ⌃ ⇧`) on macOS or Linux/Windows-style
// names (`Alt Ctrl Shift`) elsewhere. Cross-cutting framework concern;
// every chord display in storybook code snippets, future help overlay,
// and command palette consults this helper.

@Suite("KeyChord — modifier rendering for Mac and Linux conventions")
struct KeyChordFormattingTests {

    // MARK: - Symbolic (Apple) rendering

    @Test("symbolic shows Apple symbols, no separator")
    func symbolicShowsAppleSymbols() {
        let chord = KeyChord(.character("r"), [.alt])
        #expect(chord.formatted(.symbolic) == "⌥R", "expected ⌥R, got \(chord.formatted(.symbolic))")
    }

    @Test("multiple modifiers symbolic uses no separator and consistent order")
    func multipleModifiersSymbolicNoSeparator() {
        let chord = KeyChord(.tab, [.ctrl, .shift])
        // Order: Ctrl, Shift (matches Apple's Edit menu convention ⌃⇧).
        #expect(chord.formatted(.symbolic) == "⌃⇧⇥",
                "expected ⌃⇧⇥, got \(chord.formatted(.symbolic))")
    }

    // MARK: - Named (Linux) rendering

    @Test("named shows spelled-out names with + separator")
    func namedShowsLinuxStyle() {
        let chord = KeyChord(.character("r"), [.alt])
        #expect(chord.formatted(.named) == "Alt+R", "expected Alt+R, got \(chord.formatted(.named))")
    }

    @Test("multiple modifiers named uses + separator")
    func multipleModifiersNamedPlusSeparator() {
        let chord = KeyChord(.tab, [.ctrl, .shift])
        #expect(chord.formatted(.named) == "Ctrl+Shift+Tab",
                "expected Ctrl+Shift+Tab, got \(chord.formatted(.named))")
    }

    // MARK: - Automatic resolution

    @Test("automatic resolves to platform default")
    func automaticUsesPlatformDefault() {
        let chord = KeyChord(.character("r"), [.alt])
        let resolved = chord.formatted(.automatic)
        #if os(macOS)
        #expect(resolved == "⌥R", "macOS .automatic must pick symbolic; got \(resolved)")
        #else
        #expect(resolved == "Alt+R", "non-macOS .automatic must pick named; got \(resolved)")
        #endif
    }

    // MARK: - Special keys

    @Test("special keys render distinct named and symbolic forms")
    func escapeArrowsSpecialKeys() {
        #expect(KeyChord(.escape, []).formatted(.named) == "Esc")
        #expect(KeyChord(.escape, []).formatted(.symbolic) == "⎋")
        #expect(KeyChord(.enter, []).formatted(.named) == "Enter")
        #expect(KeyChord(.enter, []).formatted(.symbolic) == "↵")
        #expect(KeyChord(.tab, []).formatted(.named) == "Tab")
        #expect(KeyChord(.tab, []).formatted(.symbolic) == "⇥")
        // Arrows render the same in both styles.
        #expect(KeyChord(.up, []).formatted(.named) == "↑")
        #expect(KeyChord(.up, []).formatted(.symbolic) == "↑")
        #expect(KeyChord(.left, []).formatted(.symbolic) == "←")
        #expect(KeyChord(.right, []).formatted(.symbolic) == "→")
        #expect(KeyChord(.down, []).formatted(.symbolic) == "↓")
    }

    @Test("bare character renders uppercased")
    func bareCharacterUppercased() {
        let chord = KeyChord(.character("a"), [])
        #expect(chord.formatted(.symbolic) == "A")
        #expect(chord.formatted(.named) == "A")
    }

    // MARK: - Env value override

    @Test("ModifierLabelStyle defaults exposed")
    func modifierLabelStyleDefaults() {
        let env = EnvironmentValues()
        #expect(env.modifierLabelStyle == .automatic,
                "default must be .automatic so platform-native rendering applies without explicit configuration")
    }

    @Test("formatted(in:) reads style from environment")
    func formattedInEnvUsesStoredStyle() {
        let chord = KeyChord(.character("r"), [.alt])
        var env = EnvironmentValues()
        env.modifierLabelStyle = .named
        #expect(chord.formatted(in: env) == "Alt+R",
                "explicit .named in env must override platform default")
        env.modifierLabelStyle = .symbolic
        #expect(chord.formatted(in: env) == "⌥R",
                "explicit .symbolic in env must override platform default")
    }
}
