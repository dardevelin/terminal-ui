import Foundation
import TerminalUI

/// Top-level singleton — the framework's `@main` entry needs
/// static access. `nonisolated(unsafe)` matches the Storybook /
/// Demo pattern; safe because all reads happen on @MainActor at
/// body-eval time (the @MainActor annotation on GitClientState
/// enforces that at every callsite).
nonisolated(unsafe) let gitClientState = GitClientState(files: Fixtures.defaultFiles())

@main
struct GitClientMain: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        // Quit on `q` or Esc. Every other key falls through to the
        // view tree's .onKeyPress handlers.
        if case .key(let k) = event {
            switch k.key {
            case .character("q"), .escape:
                return false
            default:
                break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        GitClientApp(state: gitClientState)
    }
}
