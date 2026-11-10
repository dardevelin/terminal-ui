import Foundation
import TerminalUI
import TerminalUIMaps

/// Top-level singleton — the framework's `@main` entry needs static access,
/// as Coder's and Chat's do. `nonisolated(unsafe)` is safe for the same
/// reason as theirs: the runtime reads and changes it only on the main
/// actor, in bodies, handlers and `@MainActor` tasks.
nonisolated(unsafe) let maps = MapsModel(launch: LaunchOptions.parse(CommandLine.arguments))

@main
struct MapsMain: TerminalAppProtocol {
    /// `q` quits only with no panel open, where no text field can want it;
    /// Escape closes the panel, then the place card, and never quits.
    /// Ctrl+C is the framework's quit.
    static func onEvent(_ event: TerminalEvent) -> Bool {
        guard case .key(let key) = event else { return true }
        if key.key == .escape {
            maps.escape()
            return true
        }
        if key.key == .character("q"), key.modifiers.isEmpty, maps.panel == nil {
            return false
        }
        return true
    }

    /// The theme's ground behind the whole terminal, padding included.
    static var windowBackground: Color? { maps.theme.background }

    static func content() -> some TerminalView {
        MapsApp(model: maps)
    }
}
