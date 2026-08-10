/// A named, addressable behavior the app can perform — Save, Quit,
/// Open Recent, Toggle Help. Decoupled from any input device: the same
/// `Action` fires whether invoked via keyboard chord, mouse click,
/// gesture, voice prompt, accessibility rotor, or programmatic call
/// (debugger / MCP / test harness).
///
/// Actions are values. Two actions with the same `id`, `title`, and
/// `isEnabled` compare equal regardless of their `perform` closure
/// identity — closures are intentionally excluded from equality so
/// readout consumers can dedupe by ID without reasoning about closure
/// captures.
///
/// The action graph is the framework's single source of truth for
/// "what the app can do." HelpOverlay walks it to render a cheat
/// sheet; CommandPalette walks it for fuzzy search; MenuBar walks it
/// for menu hierarchy; AccessibilityRotor walks it for screen-reader
/// listings. Every readout sees the same data, so disabling an action
/// once propagates everywhere.
public struct Action: Identifiable, Sendable {
    /// Stable, process-independent identity — see ``ActionID``.
    public let id: ActionID
    /// Human-facing name shown by every readout: menu rows, palette
    /// entries, help-overlay lines.
    public let title: LocalizedString
    /// Optional longer explanation for readouts with room for one (palette
    /// detail, help text). Nil when the title says enough.
    public let description: LocalizedString?
    /// Whether the action may fire. Readouts still list a disabled action;
    /// the dispatcher skips it, so its bindings go quiet without vanishing.
    public let isEnabled: Bool
    /// The work itself — parameterless and `@Sendable` so every trigger
    /// (chord, click, remote control, test harness) invokes it identically.
    /// Deliberately excluded from `Equatable` comparison.
    public let perform: @Sendable () -> Void

    /// Creates an action. `description` defaults to nil and `isEnabled` to
    /// true, so the common case reads as id–title–closure.
    public init(
        id: ActionID,
        title: LocalizedString,
        description: LocalizedString? = nil,
        isEnabled: Bool = true,
        perform: @Sendable @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.isEnabled = isEnabled
        self.perform = perform
    }
}
