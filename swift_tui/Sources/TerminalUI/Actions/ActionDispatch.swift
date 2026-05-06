/// Dispatches input bindings into action invocations by walking the
/// node up to root, collecting every `_actionScope` it finds, and
/// matching the binding against the aggregate.
///
/// Innermost-first traversal: the leaf's scope is consulted before its
/// ancestors. A focused editor can shadow the app's Ctrl+C without
/// editing the app's scope. Disabled actions do not match (they still
/// surface in readout consumers — help, menu — but firing is gated on
/// `Action.isEnabled`).
///
/// The dispatcher is a static utility — no per-app state. The runtime
/// supplies the focused node; tests supply any node. Same code path.
@MainActor
public enum ActionDispatch {

    /// Walk node→root collecting scopes, look up `binding`, fire the
    /// bound action's `perform` closure if found and enabled. Returns
    /// `true` when the binding fired so the runtime knows to short-
    /// circuit default routing.
    ///
    /// `frameworkDefaults` is appended at the end of the chain (outermost)
    /// so user-supplied bindings shadow framework defaults via the
    /// standard innermost-wins rule. Pass `nil` for tests / scopes
    /// where defaults aren't relevant.
    ///
    /// Context-scoped bindings (HYP-327) consult `node._resolvedEnv?.actionContext`
    /// to filter — bindings declared with `whenContext:` / `whenContextContains:`
    /// only fire when their predicate is satisfied by the current
    /// context stack.
    @discardableResult
    public static func dispatch(
        binding: InputBinding,
        from node: AttributeNode,
        frameworkDefaults: ActionScope? = nil
    ) -> Bool {
        let context = node._resolvedEnv?.actionContext ?? ActionContext()
        #if DEBUG
        // Diagnostic: record every dispatch attempt with the focused
        // node id, the binding, the active context, and the outcome.
        // Lets `swtui enable events` consumers see exactly why a
        // chord did or didn't fire (HYP-341 + family).
        var matched: String? = nil
        defer {
            DevTracer.shared.traceActionDispatch(
                fromNode: node.id.description,
                binding: String(describing: binding),
                context: context.stack.joined(separator: ">"),
                matchedActionID: matched
            )
        }
        #endif
        for scope in scopeChain(from: node, frameworkDefaults: frameworkDefaults) {
            if let bound = scope.boundAction(for: binding, context: context) {
                #if DEBUG
                matched = bound.action.id.description
                #endif
                bound.action.perform()
                return true
            }
        }
        return false
    }

    /// Fire an action by its ID — bypasses any input device. Used by
    /// MCP, the debugger, scripting, and the test harness to invoke
    /// actions without simulating a chord.
    @discardableResult
    public static func invoke(
        id: ActionID,
        from node: AttributeNode,
        frameworkDefaults: ActionScope? = nil
    ) -> Bool {
        for scope in scopeChain(from: node, frameworkDefaults: frameworkDefaults) {
            if let action = scope.action(by: id), action.isEnabled {
                action.perform()
                return true
            }
        }
        return false
    }

    /// All actions reachable from `node` walking up to root. Order:
    /// innermost-first. Readout consumers (HelpOverlay,
    /// CommandPalette, MenuBar, AccessibilityRotor) call this to
    /// render their listings.
    public static func reachableActions(
        from node: AttributeNode,
        frameworkDefaults: ActionScope? = nil
    ) -> [Action] {
        var seen: Set<ActionID> = []
        var result: [Action] = []
        for scope in scopeChain(from: node, frameworkDefaults: frameworkDefaults) {
            for action in scope.allActions where seen.insert(action.id).inserted {
                result.append(action)
            }
        }
        return result
    }

    // MARK: - Internals

    /// Walk `node` up to root yielding each `_actionScope` we find,
    /// innermost first. Nodes without an attached scope are skipped.
    /// `frameworkDefaults`, if provided, is appended at the end so it
    /// behaves as the outermost scope — user bindings shadow defaults.
    private static func scopeChain(
        from node: AttributeNode,
        frameworkDefaults: ActionScope?
    ) -> [ActionScope] {
        var scopes: [ActionScope] = []
        var current: AttributeNode? = node
        while let n = current {
            if let scope = n._actionScope {
                scopes.append(scope)
            }
            current = n.parent
        }
        if let defaults = frameworkDefaults {
            scopes.append(defaults)
        }
        return scopes
    }
}
