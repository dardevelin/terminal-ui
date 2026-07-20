/// `.disabled(_)` — turn an interactive subtree off.
///
/// Writes `EnvironmentValues.isEnabled` so descendants observing
/// `@TerminalEnvironment(\.isEnabled)` see the propagated state, and
/// the framework gates handler registration + focus tab-order on it.
///
/// Most-restrictive-wins semantics (SwiftUI parity): once a parent
/// disables a subtree, descendants cannot re-enable themselves.
/// Implemented by AND-ing the inherited value with `!disabled` rather
/// than overwriting — so `.disabled(false)` nested inside
/// `.disabled(true)` stays disabled.
public struct DisabledModifier: ViewModifier, _AnyEnvironmentModifier {
    public typealias ModifierType = Bool

    /// `true` when this modifier is disabling its subtree. Stored
    /// rather than the resolved env-value so the public surface
    /// matches the call-site (`.disabled(true)` writes `disabled=true`).
    public let disabled: Bool

    public init(disabled: Bool) {
        self.disabled = disabled
    }

    public func apply(to env: inout EnvironmentValues) {
        env.isEnabled = env.isEnabled && !disabled
    }
}

extension TerminalView {
    /// Disable an interactive subtree. Defaults to `true` (the call site
    /// `.disabled()` reads as "disable this"); pass `false` when binding
    /// to a Bool that may be true or false. Note that `.disabled(false)`
    /// inside an already-disabled ancestor stays disabled — outer wins.
    public func disabled(_ isDisabled: Bool = true) -> ModifiedView<Self, DisabledModifier> {
        ModifiedView(content: self, modifier: DisabledModifier(disabled: isDisabled))
    }
}
