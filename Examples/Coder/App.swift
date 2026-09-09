import TerminalUI

/// Top-level singleton — the framework's `@main` entry needs static
/// access. `nonisolated(unsafe)` matches the Storybook / GitClient
/// pattern; safe because every read happens on @MainActor at body-eval
/// time, which `CoderState`'s own @MainActor annotation enforces.
nonisolated(unsafe) let coderState = Fixtures.session()

@main
struct CoderMain: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let key) = event {
            switch key.key {
            case .character("q"), .escape:
                return false
            case .tab:
                coderState.focus = coderState.focus == .prompt ? .transcript : .prompt
            default:
                break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        CoderApp(state: coderState)
    }
}
