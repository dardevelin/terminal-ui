import Foundation
import Testing
@testable import TerminalUI

// KeyChord renders user-visible strings in Apple's symbol convention
// (`⌥ ⌃ ⇧`) on macOS or Linux/Windows-style names (`Alt Ctrl Shift`)
// elsewhere. Cross-cutting framework concern: every chord display in
// storybook code snippets, future help overlay, and command palette
// consults this helper.

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

    // Spec acceptance #8 — the .modifierLabelStyle(_:) view modifier
    // must propagate through the env so descendants render with the
    // overridden style even on a platform whose default disagrees.
    // We exercise the same EnvironmentModifier.apply call the graph
    // renderer makes during view tree traversal: this is the contract
    // every consumer of `formatted(in:)` relies on.
    @Test("modifier override propagates style through environment")
    func envOverridePerSubtree() {
        let chord = KeyChord(.character("r"), [.alt])

        // Start from defaults — `.automatic` resolves to the platform default.
        var env = EnvironmentValues()
        let defaultRender = chord.formatted(in: env)
        #if os(macOS)
        #expect(defaultRender == "⌥R", "macOS default must be symbolic; got \(defaultRender)")
        #else
        #expect(defaultRender == "Alt+R", "non-macOS default must be named; got \(defaultRender)")
        #endif

        // Apply the same modifier .modifierLabelStyle(.named) emits.
        let namedModifier = EnvironmentModifier(
            keyPath: \EnvironmentValues.modifierLabelStyle,
            value: ModifierLabelStyle.named
        )
        namedModifier.apply(to: &env)
        #expect(env.modifierLabelStyle == .named,
                "modifier must mutate env to .named for descendants")
        #expect(chord.formatted(in: env) == "Alt+R",
                "descendants on any platform must render named after override")

        // And the symbolic override on a hypothetically-Linux subtree.
        let symbolicModifier = EnvironmentModifier(
            keyPath: \EnvironmentValues.modifierLabelStyle,
            value: ModifierLabelStyle.symbolic
        )
        symbolicModifier.apply(to: &env)
        #expect(env.modifierLabelStyle == .symbolic)
        #expect(chord.formatted(in: env) == "⌥R",
                "symbolic override must apply on every platform")
    }
}
