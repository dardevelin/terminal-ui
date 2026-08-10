/// Modifier that attaches an `ActionScope` to a view. The framework's
/// input dispatcher walks the focus chain to root collecting these
/// scopes; matched bindings fire the bound action. The scope also
/// surfaces in readouts (HelpOverlay, CommandPalette, MenuBar,
/// AccessibilityRotor) — every consumer reads from the same data.
public struct ActionsModifier: ViewModifier {
    public typealias ModifierType = Void
    /// The action tree attached to this view, re-stamped on every update.
    public let scope: ActionScope
}

extension ActionsModifier: _LifecycleModifier {
    /// Stamp the scope on the modifier node every render. Reconciliation
    /// may swap one ActionsModifier value for another (the `Action`
    /// closures are reference-typed via @Sendable; the scope is value-
    /// equal only by reference) — refreshing on every update keeps the
    /// dispatcher pointing at the latest closures.
    func onConstructOrUpdate(node: AttributeNode) {
        node._actionScope = scope
        #if DEBUG
        warnIfOptionMetaUnconfirmed(node: node)
        #endif
    }

    #if DEBUG
    /// Warn once per session when a binding needs Option-as-Meta on a terminal
    /// that has not confirmed it delivers that.
    ///
    /// Fires from a hook that runs on every update, so the one-shot behaviour
    /// comes from `emitWarning`'s dedupe of (code, nodeID, message) — and both
    /// of those must be stable. The node ID deliberately is **not** passed:
    /// this reports a property of the terminal, not of a node, and keying on
    /// the path would emit a fresh copy for every row a growing `ForEach`
    /// introduces.
    private func warnIfOptionMetaUnconfirmed(node: AttributeNode) {
        guard let message = Self.optionMetaWarning(
            for: scope, state: Runtime.capabilities.optionAsMetaConfigured
        ) else { return }
        DebugStream.shared.emitWarning(.optionAsMetaUnconfirmed, message: message)
    }

    /// The warning text for this scope, or nil when no warning is warranted.
    ///
    /// Takes the state rather than reading the global so the whole decision —
    /// both the chord search and the capability gate — is testable.
    static func optionMetaWarning(
        for scope: ActionScope,
        state: OptionAsMetaState
    ) -> String? {
        guard state == .unknown else { return nil }
        guard let chord = optionBearingChord(in: scope) else { return nil }
        return """
            Binding \(chord.formatted()) needs Option to arrive as a Meta prefix, \
            which this terminal does not report. Terminal.app: Settings → Profiles \
            → Keyboard → "Use Option as Meta key". iTerm2: Settings → Profiles → \
            Keys → Left/Right Option = "Esc+". Kitty needs no setting. Suppress with \
            DebugStream.shared.suppressWarning(.optionAsMetaUnconfirmed).
            """
    }

    /// The first keyboard binding in `scope` that carries the Option/Alt
    /// modifier. One warning per scope, not one per binding.
    static func optionBearingChord(in scope: ActionScope) -> KeyChord? {
        for bound in scope.boundActions {
            if case .keyboard(let key, let modifiers) = bound.binding,
               modifiers.contains(.alt) {
                return KeyChord(key, modifiers)
            }
        }
        return nil
    }
    #endif
}

extension TerminalView {
    /// Attach an action scope to this view. Inside the closure, declare
    /// `Action`s and `BoundAction`s using the `@ActionBuilder` DSL:
    ///
    /// ```swift
    /// VStack { ... }
    ///     .actions {
    ///         Action(id: "app.quit", title: .literal("Quit")) { quit() }
    ///             .bound(to: .keyboard(.character("c"), [.ctrl]))
    ///         Action(id: "menu.refresh", title: .literal("Refresh")) { refresh() }
    ///     }
    /// ```
    ///
    /// Bound actions dispatch from any registered input device.
    /// Unbound actions surface in readouts and are reachable by ID
    /// from MCP / debugger / scripting / test harness without
    /// simulating any input.
    public func actions(
        @ActionBuilder _ build: () -> [ActionScopeFragment]
    ) -> ModifiedView<Self, ActionsModifier> {
        ModifiedView(content: self, modifier: ActionsModifier(scope: ActionScope(build)))
    }
}
