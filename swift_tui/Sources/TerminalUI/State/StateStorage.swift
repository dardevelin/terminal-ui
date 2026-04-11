import Observation

/// Observable state container owned by the attribute graph.
/// When `value` is mutated, the Observation framework fires change
/// notifications, which the graph uses to mark the owning node dirty.
@Observable
public final class StateStorage<Value>: @unchecked Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }
}

/// Type-erased protocol for state storage, so graph nodes can hold
/// heterogeneous state without generics.
public protocol AnyStateStorage: AnyObject {
    var key: String { get }
}

/// Concrete state slot keyed by name.
public final class StateSlot<Value>: AnyStateStorage {
    public let key: String
    public let storage: StateStorage<Value>

    public init(key: String, initialValue: Value) {
        self.key = key
        self.storage = StateStorage(initialValue)
    }
}
