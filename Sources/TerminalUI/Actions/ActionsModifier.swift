/// Modifier that attaches an `ActionScope` to a view. The framework's
/// input dispatcher walks the focus chain to root collecting these
/// scopes; matched bindings fire the bound action. The scope also
/// surfaces in readouts (HelpOverlay, CommandPalette, MenuBar,
/// AccessibilityRotor) — every consumer reads from the same data.
public struct ActionsModifier: ViewModifier {
    public typealias ModifierType = Void
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
    }
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
