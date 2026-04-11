import Observation

/// Reactive state for terminal views.
/// Works like SwiftUI's @State: the value is owned by the graph,
/// persists across body re-evaluations, and triggers re-render on mutation.
///
/// Usage:
/// ```
/// struct Counter: TerminalView {
///     @TerminalState var count = 0
///
///     var body: some TerminalView {
///         Text("Count: \(count)")
///     }
/// }
/// ```
@propertyWrapper
public struct TerminalState<Value> {
    private let initialValue: Value
    private let key: String

    public init(wrappedValue: Value, file: String = #file, line: Int = #line, column: Int = #column) {
        self.initialValue = wrappedValue
        // Unique key from source location — stable across frames
        self.key = "\(file):\(line):\(column)"
    }

    public var wrappedValue: Value {
        get {
            guard let node = GraphContext.currentNode else {
                return initialValue
            }
            if let slot = node.stateSlots[key] as? StateSlot<Value> {
                return slot.storage.value
            }
            // First evaluation — create storage
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

    public var projectedValue: Binding<Value> {
        // Capture the current node eagerly so the Binding works outside body evaluation
        // (e.g., in onKeyPress/onClick closures where GraphContext.currentNode is nil).
        let capturedNode = GraphContext.currentNode
        let capturedKey = key
        let fallback = initialValue

        // Ensure the state slot exists — projectedValue may be accessed before wrappedValue
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

    // State slot lookup is now O(1) via dictionary keyed by source location.
}

/// A two-way reference to state owned elsewhere.
public struct Binding<Value> {
    public let get: () -> Value
    public let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
}
