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
    /// Actions paired with input bindings — the dispatchable set.
    public let boundActions: [BoundAction]
    /// Actions reachable only by ID — readout-visible, no device
    /// dispatch.
    public let unboundActions: [Action]
    /// Nested scopes from sub-views; populated by the focus walker.
    public let children: [ActionScope]

    /// Creates a scope from explicit action lists; all default to empty.
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
    ///
    /// Legacy overload: pass through to the context-aware variant with
    /// an empty `ActionContext`. Bindings without a `whenContext:` /
    /// `whenContextContains:` requirement match unconditionally, so
    /// existing callers keep their behaviour.
    public func boundAction(for binding: InputBinding) -> BoundAction? {
        boundAction(for: binding, context: ActionContext())
    }

    /// Look up the bound action for an input binding within the given
    /// `ActionContext`. Bindings carrying a `contextRequirement` (set
    /// via `bound(to:whenContext:)` / `bound(to:whenContextContains:)`)
    /// only match when their predicate is satisfied by `context`;
    /// requirement-less bindings always match.
    ///
    /// Order matters — the first matching binding wins. Callers that
    /// declare both a context-scoped and a default binding for the same
    /// chord should list the context-scoped one first so it shadows the
    /// fallback when its predicate is satisfied.
    public func boundAction(for binding: InputBinding, context: ActionContext) -> BoundAction? {
        for entry in boundActions where entry.binding == binding && entry.action.isEnabled {
            if let requirement = entry.contextRequirement, !requirement.matches(context) {
                continue
            }
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
    /// An action paired with an input binding — dispatchable.
    case bound(BoundAction)
    /// A bare action — readout-visible, fired by ID only.
    case unbound(Action)
}

/// Result builder so `.actions { ... }` reads declaratively. Accepts
/// `Action` (becomes `.unbound`) and `BoundAction` (becomes `.bound`).
@resultBuilder
public enum ActionBuilder {
    /// Accepts a bare `Action`, collected as `.unbound`.
    public static func buildExpression(_ action: Action) -> [ActionScopeFragment] {
        [.unbound(action)]
    }

    /// Accepts a `BoundAction` (from `Action.bound(to:)`), collected as
    /// `.bound`.
    public static func buildExpression(_ bound: BoundAction) -> [ActionScopeFragment] {
        [.bound(bound)]
    }

    /// Concatenates the block's per-expression fragment lists in source
    /// order.
    public static func buildBlock(_ fragments: [ActionScopeFragment]...) -> [ActionScopeFragment] {
        fragments.flatMap { $0 }
    }

    /// Flattens `for` loop iterations into one fragment list.
    public static func buildArray(_ fragments: [[ActionScopeFragment]]) -> [ActionScopeFragment] {
        fragments.flatMap { $0 }
    }

    /// `if` without `else`: `nil` contributes no fragments.
    public static func buildOptional(_ fragments: [ActionScopeFragment]?) -> [ActionScopeFragment] {
        fragments ?? []
    }

    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first: [ActionScopeFragment]) -> [ActionScopeFragment] {
        first
    }

    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second: [ActionScopeFragment]) -> [ActionScopeFragment] {
        second
    }
}
