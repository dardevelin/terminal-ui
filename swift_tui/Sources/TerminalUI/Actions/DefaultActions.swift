// Framework-supplied default actions and the scope that bundles them
// for the runtime to install at the root of every app's tree. Each
// default carries a stable ID so apps that want to override only need
// to bind the same chord to a different action; user scopes sit inner
// to the framework defaults so the standard innermost-wins rule
// shadows them automatically.

extension Action {
    /// Quit the application. The framework's runtime supplies the
    /// actual quit closure when it installs the default scope; tests
    /// pass a no-op or counter handler.
    public static func quit(perform: @Sendable @escaping () -> Void) -> Action {
        Action(
            id: "app.quit",
            title: .literal("Quit"),
            description: .literal("Exit the application"),
            perform: perform
        )
    }

    /// Dismiss the topmost modal or, when none is present, quit. The
    /// framework's runtime resolves the dismiss-vs-quit branch when
    /// it supplies the closure.
    public static func dismissOrQuit(perform: @Sendable @escaping () -> Void) -> Action {
        Action(
            id: "app.dismissOrQuit",
            title: .literal("Dismiss or Quit"),
            description: .literal("Dismiss the topmost modal, or quit if none"),
            perform: perform
        )
    }
}

extension ActionScope {
    /// Build the default framework action scope with bindings the
    /// runtime installs at the root of every app's tree:
    ///
    ///   * Ctrl+C → `Action.quit`
    ///   * Esc    → `Action.dismissOrQuit`
    ///
    /// Apps override individual defaults by attaching their own
    /// `.actions { ... }` modifier inner to the root — the standard
    /// innermost-wins dispatch rule shadows the default automatically.
    /// Apps can also pass a custom dismiss handler when the default
    /// "dismiss the topmost modal, then quit" is wrong for their UX.
    public static func frameworkDefaults(
        quit: @Sendable @escaping () -> Void,
        dismissOrQuit: @Sendable @escaping () -> Void = {}
    ) -> ActionScope {
        ActionScope {
            Action.quit(perform: quit)
                .bound(to: .keyboard(.character("c"), [.ctrl]))
            Action.dismissOrQuit(perform: dismissOrQuit)
                .bound(to: .keyboard(.escape, []))
        }
    }
}
