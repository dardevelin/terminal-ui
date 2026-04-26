/// Tree of actions a view defines. The framework walks the focus
/// chain to root and aggregates the visible scope at any point;
/// shortcuts are GTK accelerators in spirit — attached to the widget,
/// dispatched by tree-walk.
///
/// A scope holds:
/// - `boundActions` — actions paired with input bindings; dispatchable.
/// - `unboundActions` — actions reachable by ID only; readout-visible
///   but not bound to any device. MCP / debugger / scripting can still
///   fire them via `action(by:)`.
/// - `children` — nested scopes from sub-views (populated by the
///   focus walker, not by `@ActionBuilder`).
public struct ActionScope: Sendable {
    public let boundActions: [BoundAction]
    public let unboundActions: [Action]
    public let children: [ActionScope]

    public init(
        boundActions: [BoundAction] = [],
        unboundActions: [Action] = [],
        children: [ActionScope] = []
    ) {
        self.boundActions = boundActions
        self.unboundActions = unboundActions
        self.children = children
    }

    /// Build a scope declaratively via `@ActionBuilder`.
    public init(@ActionBuilder _ build: () -> [ActionScopeFragment]) {
        let fragments = build()
        var bound: [BoundAction] = []
        var unbound: [Action] = []
        for fragment in fragments {
            switch fragment {
            case .bound(let b):    bound.append(b)
            case .unbound(let a):  unbound.append(a)
            }
        }
        self.boundActions = bound
        self.unboundActions = unbound
        self.children = []
    }

    /// Look up the bound action for an input binding. Disabled actions
    /// are excluded — they still surface in readouts (help / menu) so
    /// the user sees the chord, but firing it is a no-op.
    public func boundAction(for binding: InputBinding) -> BoundAction? {
        for entry in boundActions where entry.binding == binding && entry.action.isEnabled {
            return entry
        }
        return nil
    }

    /// Look up an action by ID — for MCP / debugger / scripting / test
    /// harness invocations that don't go through any input device.
    /// Disabled actions are still returned; the caller decides whether
    /// to fire (the perform closure is still callable).
    public func action(by id: ActionID) -> Action? {
        for entry in boundActions where entry.action.id == id {
            return entry.action
        }
        for action in unboundActions where action.id == id {
            return action
        }
        return nil
    }

    /// Every action in the scope, bound or not. Readout consumers
    /// (HelpOverlay, CommandPalette, MenuBar, AccessibilityRotor) walk
    /// this to render their listings.
    public var allActions: [Action] {
        boundActions.map(\.action) + unboundActions
    }

    /// Combine an outer (parent) scope with an inner (child) scope.
    /// Inner wins on binding conflicts — an editor's Ctrl+C overrides
    /// the app's Ctrl+C while the editor has focus. ID lookups search
    /// inner first too.
    public static func combined(outer: ActionScope, inner: ActionScope) -> ActionScope {
        ActionScope(
            boundActions: inner.boundActions + outer.boundActions,
            unboundActions: inner.unboundActions + outer.unboundActions,
            children: outer.children + inner.children
        )
    }
}

/// Fragment emitted by `@ActionBuilder` — either a `BoundAction` (an
/// action paired with an input binding) or a bare `Action` (reachable
/// by ID, surfaces in readouts, no device dispatch). Internal —
/// callers see only the result builder, never the fragment type.
public enum ActionScopeFragment: Sendable {
    case bound(BoundAction)
    case unbound(Action)
}

/// Result builder so `.actions { ... }` reads declaratively. Accepts
/// `Action` (becomes `.unbound`) and `BoundAction` (becomes `.bound`).
@resultBuilder
public enum ActionBuilder {
    public static func buildExpression(_ action: Action) -> [ActionScopeFragment] {
        [.unbound(action)]
    }

    public static func buildExpression(_ bound: BoundAction) -> [ActionScopeFragment] {
        [.bound(bound)]
    }

    public static func buildBlock(_ fragments: [ActionScopeFragment]...) -> [ActionScopeFragment] {
        fragments.flatMap { $0 }
    }

    public static func buildArray(_ fragments: [[ActionScopeFragment]]) -> [ActionScopeFragment] {
        fragments.flatMap { $0 }
    }

    public static func buildOptional(_ fragments: [ActionScopeFragment]?) -> [ActionScopeFragment] {
        fragments ?? []
    }

    public static func buildEither(first: [ActionScopeFragment]) -> [ActionScopeFragment] {
        first
    }

    public static func buildEither(second: [ActionScopeFragment]) -> [ActionScopeFragment] {
        second
    }
}
