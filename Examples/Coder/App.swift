import TerminalUI

/// Top-level singleton — the framework's `@main` entry needs static
/// access. `nonisolated(unsafe)` matches the Storybook / GitClient
/// pattern; safe because every read happens on @MainActor at body-eval
/// time, which `CoderState`'s own @MainActor annotation enforces.
nonisolated(unsafe) let coderState = Fixtures.session()

@main
struct CoderMain: TerminalAppProtocol {
    /// Overridden to quit on nothing. The default quits on `q`, and the
    /// prompt owns every printable key: a quit chord on a letter ends the
    /// session at the first word that contains it and hands the rest of the
    /// line to the shell. Ctrl+C is the framework's quit, as it is Crush's;
    /// Escape is `CoderApp`'s.
    static func onEvent(_ event: TerminalEvent) -> Bool {
        true
    }

    /// The theme's ground behind the whole terminal, so the padding a
    /// terminal draws around its grid is Coder's colour rather than a frame
    /// of the terminal's own around it.
    static var windowBackground: Color? { CoderTheme.dark.background }

    /// The user's own editing keys, in `~/.config/coder/keys.toml`.
    static var userKeymap: UserKeymapSource { .configFile(named: "coder") }

    static func content() -> some TerminalView {
        CoderApp(state: coderState)
    }
}
