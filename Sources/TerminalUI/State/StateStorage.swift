import Observation

/// Observable state container owned by the attribute graph.
/// When `value` is mutated, the Observation framework fires change
/// notifications, which the graph uses to mark the owning node dirty.
///
/// The leaf of the state chain: `@TerminalState` allocates one per slot
/// (wrapped in a `StateSlot` keyed by source location) and parks it on the
/// owning `AttributeNode`, where it survives body re-evaluations. A class
/// rather than a value so a `Binding` captured in a handler closure mutates
/// the same storage the next body evaluation reads.
@Observable
public final class StateStorage<Value> {
    /// The stored value. Mutation fires the Observation change callback,
    /// which marks the owning node dirty and schedules a re-render.
    public var value: Value

    /// Wraps an initial value in observable storage.
    public init(_ value: Value) {
        self.value = value
    }
}

/// Type-erased protocol for state storage, so graph nodes can hold
/// heterogeneous state without generics.
public protocol AnyStateStorage: AnyObject {
    /// The property name this slot backs — the lookup key on the owning
    /// node.
    var key: String { get }
}

/// Concrete state slot keyed by name.
public final class StateSlot<Value>: AnyStateStorage {
    /// The property name this slot backs.
    public let key: String
    /// The observable box holding the value; mutations mark the owning
    /// node dirty.
    public let storage: StateStorage<Value>

    /// Creates a slot seeded with the property's initial value.
    public init(key: String, initialValue: Value) {
        self.key = key
        self.storage = StateStorage(initialValue)
    }
}
