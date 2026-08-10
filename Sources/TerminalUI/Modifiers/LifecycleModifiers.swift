/// Type-erasure for `OnChangeModifier<Value>` so the graph's modifier
/// dispatch can pattern-match without naming the value type. The graph
/// stores the last seen value as `Any`; this protocol lets the modifier
/// compare current-vs-stored and decide whether to fire.
public protocol _OnChangeModifierProtocol {
    /// If the previously stored value differs from the current value, fire
    /// the action and return the new value to store. If they match, return
    /// `current` unchanged. `previous == nil` means "never observed before"
    /// — by SwiftUI convention, that does NOT fire the action; only changes
    /// after the initial render do.
    func compareAndFire(previous: Any?) -> Any
}

/// View modifier that calls a closure when a value changes.
public struct OnChangeModifier<Value: Equatable>: ViewModifier, _OnChangeModifierProtocol {
    public typealias ModifierType = Value
    /// The observed value as of this frame's body evaluation.
    public let value: Value
    /// Called as `action(old, new)` when the value differs from the
    /// previous frame's.
    public let action: (Value, Value) -> Void

    /// Compares the graph-stored previous value against ``value``, firing
    /// ``action`` on a change; returns the value to store for next frame.
    /// `previous == nil` (first observation) records without firing.
    public func compareAndFire(previous: Any?) -> Any {
        guard let prev = previous as? Value else {
            // First observation — record the value but do not fire. Mirrors
            // SwiftUI's `onChange(of:)` semantics: only mutations from this
            // initial value trigger the action.
            return value
        }
        if prev != value {
            action(prev, value)
        }
        return value
    }
}

/// View modifier that calls a closure when the view first appears.
public struct OnAppearModifier: ViewModifier {
    public typealias ModifierType = Bool
    /// Runs once when the view enters the graph.
    public let action: () -> Void
}

/// View modifier that calls a closure when the view disappears.
public struct OnDisappearModifier: ViewModifier {
    public typealias ModifierType = Bool
    /// Runs when the view leaves the graph (not on app quit).
    public let action: () -> Void
}

extension TerminalView {
    /// Call `action(old, new)` when `value` changes between frames. The
    /// initial value observed on first render does not fire — only
    /// subsequent changes do, matching SwiftUI's `onChange(of:)`.
    public func onChange<V: Equatable>(of value: V, perform action: @escaping (V, V) -> Void) -> ModifiedView<Self, OnChangeModifier<V>> {
        ModifiedView(content: self, modifier: OnChangeModifier(value: value, action: action))
    }

    /// Call `action` once when the view enters the graph — first render, or
    /// re-insertion after an `if` branch switch or `.id` change. The place
    /// for one-shot setup; for async work that should also cancel on
    /// disappear, prefer `.task { }`.
    public func onAppear(perform action: @escaping () -> Void) -> ModifiedView<Self, OnAppearModifier> {
        ModifiedView(content: self, modifier: OnAppearModifier(action: action))
    }

    /// Call `action` when the view leaves the graph — its branch switched
    /// away, its `ForEach` row vanished, or its `.id` changed. Not called on
    /// app quit; teardown that must run at exit belongs in `onEvent(_:)`.
    public func onDisappear(perform action: @escaping () -> Void) -> ModifiedView<Self, OnDisappearModifier> {
        ModifiedView(content: self, modifier: OnDisappearModifier(action: action))
    }
}

/// Type-erasure for `TaskModifier<ID>` so the graph can start and restart the
/// work without naming the identity type.
public protocol _TaskModifierProtocol {
    /// Start the work if this node has none running, or if the identity it was
    /// started for has changed. Cancels the outgoing task before replacing it.
    ///
    /// Uncontracted isolation, like every other lifecycle modifier: the graph
    /// builds and updates on the MainActor, which is the invariant that lets
    /// `AttributeNode` be `@unchecked Sendable` in the first place.
    func startIfNeeded(on node: AttributeNode)
}

/// View modifier that owns async work for as long as the view is on screen.
///
/// SwiftUI parity: `View.task { }` and `View.task(id:)`. The work starts when
/// the view appears and is cancelled when it leaves — the framework's answer
/// to "load this when shown, stop when it goes away", which otherwise every
/// app writes by hand with a detached `Task` that outlives its view.
public struct TaskModifier<ID: Hashable>: ViewModifier, _TaskModifierProtocol {
    public typealias ModifierType = Bool
    /// Restart identity: the task cancels and restarts when this changes.
    /// `nil` (the `.task { }` form) starts once and is left alone.
    public let id: ID?
    /// Priority the task is spawned with.
    public let priority: TaskPriority
    /// The async work, MainActor-isolated so it can touch `@Observable`
    /// models directly.
    public let action: @MainActor () async -> Void

    /// Starts the work on `node` if none is running or its identity
    /// changed; cancels the outgoing task before replacing it.
    public func startIfNeeded(on node: AttributeNode) {
        let identity = id.map { AnyHashable($0) }
        // Same identity and still running: nothing to do. A `.task` without an
        // id has identity nil, which matches on every frame — so it starts
        // once and is left alone, which is the whole point.
        if node.lifecycleTask != nil, node.lifecycleTaskID == identity { return }

        node.lifecycleTask?.cancel()
        node.lifecycleTaskID = identity
        let work = action
        // `@MainActor` on the work, not `@Sendable`: the runtime is
        // MainActor-isolated end to end, so an app can touch its `@Observable`
        // model inside `.task` the way it does in `onAppear` — no hop, no
        // wrapper. Awaits inside still suspend and resume as usual.
        node.lifecycleTask = Task(priority: priority) { @MainActor in await work() }
    }
}

extension TerminalView {
    /// Run async work for as long as this view is on screen. The task is
    /// started when the view appears and cancelled when it disappears.
    ///
    /// ```swift
    /// Text(model.status)
    ///     .task { await model.load() }
    /// ```
    ///
    /// Mutating `@Observable` state from inside wakes the render loop, so the
    /// screen follows the work without the app scheduling a redraw.
    public func task(
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @MainActor () async -> Void
    ) -> ModifiedView<Self, TaskModifier<Never>> {
        ModifiedView(content: self, modifier: TaskModifier(id: nil, priority: priority, action: action))
    }

    /// Run async work tied to `id`: cancelled and restarted whenever `id`
    /// changes, cancelled for good when the view disappears. The shape for
    /// "load the thing this view is currently showing".
    public func task<ID: Hashable>(
        id: ID,
        priority: TaskPriority = .userInitiated,
        _ action: @escaping @MainActor () async -> Void
    ) -> ModifiedView<Self, TaskModifier<ID>> {
        ModifiedView(content: self, modifier: TaskModifier(id: id, priority: priority, action: action))
    }
}
