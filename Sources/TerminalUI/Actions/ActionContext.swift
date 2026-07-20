// HYP-327 — i3-shaped "modes" without a global state machine.
//
// ActionContext is a stack of mode names. Bindings declare a context
// requirement on construction (`whenContext:` / `whenContextContains:`);
// the dispatcher filters bindings by current context. No mutable mode
// singleton, no separate dispatcher state, no per-binding callback
// shenanigans — the predicate composes through the existing
// `ActionScope.boundAction(for:context:)` lookup the same way any
// other binding metadata does.
//
// Why a stack and not a single string: nested modes work without
// special-casing. Push "resize", push "super-resize" inside it; pop
// returns to "resize". i3's `mode "resize" mode "super"` chain is
// expressible directly. The runtime stores one `ActionContext` value
// in `EnvironmentValues.actionContext`; pushing/popping mutates the
// value via the standard `@Observable` setter.

/// Stack of currently-active context names. Bindings can require a
/// specific context (or any layer of the stack) to be active before
/// they fire. Empty stack = the "default" context (no requirements).
public struct ActionContext: Sendable, Equatable {
    public private(set) var stack: [String]

    /// The currently-topmost context name, or nil if no context is
    /// active. Equivalent to i3's `mode` global string when only one
    /// level deep.
    public var current: String? { stack.last }

    public init(stack: [String] = []) {
        self.stack = stack
    }

    public mutating func push(_ name: String) {
        stack.append(name)
    }

    /// Pop the topmost context. No-op when the stack is empty so the
    /// caller doesn't need to check before calling.
    public mutating func pop() {
        _ = stack.popLast()
    }

    public mutating func clear() {
        stack.removeAll()
    }

    /// True if `name` appears anywhere on the stack — the deeper layers
    /// are still considered "active" for `whenContextContains:` bindings.
    public func contains(_ name: String) -> Bool {
        stack.contains(name)
    }
}

/// Predicate a binding can carry to gate when it fires. Empty (nil
/// requirement) bindings always fire; matched requirements only fire
/// when the runtime's `ActionContext` satisfies the predicate.
///
/// Two flavours map to i3's two natural use cases:
/// * `equalsTop` — "this binding only applies when 'resize' is the
///   currently active mode" (i.e. the topmost stack entry). Matches
///   the i3 `mode "resize"` block semantic.
/// * `containsAny` — "this binding applies as long as 'resize' is on
///   the stack somewhere," letting an outer mode declare bindings
///   that survive entry into nested sub-modes.
public enum ContextRequirement: Sendable, Equatable {
    case equalsTop(String)
    case containsAny(String)

    /// True iff `context` satisfies the predicate.
    public func matches(_ context: ActionContext) -> Bool {
        switch self {
        case .equalsTop(let name):     return context.current == name
        case .containsAny(let name):   return context.contains(name)
        }
    }
}
