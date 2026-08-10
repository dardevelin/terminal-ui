import Observation

/// Reactive state for terminal views.
/// Works like SwiftUI's @State: the value is owned by the graph,
/// persists across body re-evaluations, and triggers re-render on mutation.
///
/// ## Storage identity
///
/// State slots are keyed by source location (`#file:#line:#column`).
/// This gives each `@TerminalState` a stable identity across frames
/// without requiring explicit keys — same source location always maps
/// to the same slot, even when the view body is re-evaluated.
///
/// ## Projected value ($binding)
///
/// Swift property wrappers expose a `projectedValue` via the `$` prefix.
/// `$count` returns a `Binding<Int>` — a two-way reference that can be
/// passed to child views or captured in event handler closures.
///
/// The critical subtlety: `GraphContext.currentNode` is only set during
/// body evaluation. Event handlers (onKeyPress, onClick) fire later,
/// when GraphContext.currentNode is nil. The projected value eagerly
/// captures the node at body evaluation time so the Binding works in
/// both contexts.
///
/// Usage:
/// ```
/// struct Counter: TerminalView {
///     @TerminalState var count = 0
///
///     var body: some TerminalView {
///         Text("Count: \(count)")
///             .onKeyPress { [$count] event in
///                 $count.set($count.get() + 1)  // Works: node captured eagerly
///                 return .handled
///             }
///     }
/// }
/// ```
@propertyWrapper
public struct TerminalState<Value> {
    private let initialValue: Value
    private let key: String

    /// Creates the wrapper with its initial value. The source-location
    /// parameters default to the call site and form the storage-slot key —
    /// callers never pass them explicitly.
    public init(wrappedValue: Value, file: String = #file, line: Int = #line, column: Int = #column) {
        self.initialValue = wrappedValue
        self.key = "\(file):\(line):\(column)"
    }

    /// The current value of the graph-owned slot.
    ///
    /// Reads and writes resolve through `GraphContext.currentNode`, which is
    /// bound only during body evaluation. Outside it — event handlers, timer
    /// callbacks — reads return the initial value and writes are silently
    /// dropped. From a handler, mutate through the projected ``Binding``
    /// (`$value`, projected in `body` and captured into the closure) or hold
    /// state in an `@Observable` class instead.
    public var wrappedValue: Value {
        get {
            guard let node = GraphContext.currentNode else {
                return initialValue
            }
            if let slot = node.stateSlots[key] as? StateSlot<Value> {
                return slot.storage.value
            }
            let slot = StateSlot(key: key, initialValue: initialValue)
            node.stateSlots[key] = slot
            return initialValue
        }
        nonmutating set {
            guard let node = GraphContext.currentNode else { return }
            if let slot = node.stateSlots[key] as? StateSlot<Value> {
                slot.storage.value = newValue
            }
        }
    }

    /// Projected value: `$myState` returns a Binding<Value>.
    ///
    /// Eagerly captures GraphContext.currentNode so the binding works
    /// in handler closures where the context is no longer set.
    /// Falls back to GraphContext.currentNode for direct body-evaluation access.
    public var projectedValue: Binding<Value> {
        let capturedNode = GraphContext.currentNode
        let capturedKey = key
        let fallback = initialValue

        #if DEBUG
        if capturedNode == nil {
            // The user projected `$foo` at a moment when no node was
            // current — almost always inside a `GeometryReader { ... }`
            // closure that runs at GR-rebuild time. The returned
            // binding will fall back to the initial value forever and
            // silently swallow writes. Surface as a framework warning
            // so the bug is loud, not silent.
            DebugStream.shared.emitWarning(
                .bindingProjectedWithoutNode,
                message: "Binding for state '\(capturedKey)' projected with no current node — likely projected inside a deferred closure (GeometryReader). Project the binding in `body` outside the closure and capture it."
            )
        }
        #endif

        if let node = capturedNode, node.stateSlots[capturedKey] == nil {
            node.stateSlots[capturedKey] = StateSlot(key: capturedKey, initialValue: fallback)
        }

        return Binding(
            get: {
                guard let node = capturedNode ?? GraphContext.currentNode else {
                    return fallback
                }
                if let slot = node.stateSlots[capturedKey] as? StateSlot<Value> {
                    return slot.storage.value
                }
                return fallback
            },
            set: { newValue in
                guard let node = capturedNode ?? GraphContext.currentNode else { return }
                if let slot = node.stateSlots[capturedKey] as? StateSlot<Value> {
                    slot.storage.value = newValue
                }
            }
        )
    }
}

/// A two-way reference to state owned elsewhere.
///
/// The value never lives in the binding: every read calls ``get`` and every
/// write calls ``set``, so the binding stays truthful no matter who mutates
/// the underlying storage. Controls take bindings for the values they edit.
/// `@TerminalState`'s projected value (`$count`) produces one; one can also
/// be built directly over any storage the caller owns:
///
/// ```swift
/// Toggle("Telemetry", isOn: Binding(
///     get: { model.telemetry }, set: { model.telemetry = $0 }
/// ))
/// ```
///
/// Hand-built bindings over an `@Observable` model are the reliable choice
/// inside event-handler closures, where `@TerminalState` has no graph context.
/// When projecting `$state` bindings, do so in `body` proper — a projection
/// inside a `GeometryReader { ... }` closure runs outside body evaluation,
/// captures no node, and yields a binding that swallows writes.
public struct Binding<Value> {
    /// Reads the current value from the owning storage.
    public let get: () -> Value
    /// Writes a new value back to the owning storage.
    public let set: (Value) -> Void

    /// Creates a binding from explicit accessor closures over storage the
    /// caller owns.
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    /// The referenced value: reading calls ``get``, assigning calls ``set``.
    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
}
