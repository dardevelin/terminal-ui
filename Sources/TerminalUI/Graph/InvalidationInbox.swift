import Synchronization

/// The nodes whose observed state changed since the main actor last looked.
///
/// Observation calls `onChange` on whichever thread made the change, and an
/// app may still change an `@Observable` model from a background task. The
/// graph is main-actor state that the frame reads, so an `onChange` closure
/// holds this inbox rather than the graph: it can post a node and do nothing
/// else, and because the inbox is a checked `Sendable`, the compiler keeps
/// it that way. That makes such a change safe, not seen: Observation can
/// miss one that lands while the body reading it runs (see
/// ObservationWindowTests), which is why observed state changes on the main
/// actor.
final class InvalidationInbox: Sendable {
    private let pending = Mutex<[ObjectIdentifier: AttributeNode]>([:])
    /// `!pending.isEmpty`, written under the lock, so the frame loop can ask
    /// whether there is work without taking it.
    private let nonEmpty = Atomic<Bool>(false)
    /// Raised on every post, so a frame loop with nothing to do learns of the
    /// change without polling `hasPending`.
    private let wake: WakeSignal?

    init(wake: WakeSignal?) {
        self.wake = wake
    }

    /// Whether a node has been posted since the last ``take()``.
    var hasPending: Bool {
        nonEmpty.load(ordering: .relaxed)
    }

    /// Records that `node` read state that has since changed. Any thread.
    func post(_ node: AttributeNode) {
        pending.withLock { pending in
            pending[ObjectIdentifier(node)] = node
            nonEmpty.store(true, ordering: .relaxed)
        }
        wake?.wake()
    }

    /// Every node posted since the last call, leaving the inbox empty.
    func take() -> [ObjectIdentifier: AttributeNode] {
        guard hasPending else { return [:] }
        return pending.withLock { pending in
            nonEmpty.store(false, ordering: .relaxed)
            var taken: [ObjectIdentifier: AttributeNode] = [:]
            swap(&taken, &pending)
            return taken
        }
    }

    /// Whether a node posted since the last ``take()`` satisfies
    /// `predicate`, leaving it posted. Called on the main actor, the only
    /// place a node's other properties are read or written.
    func containsPosted(where predicate: (AttributeNode) -> Bool) -> Bool {
        guard hasPending else { return false }
        return pending.withLock { $0.values.contains(where: predicate) }
    }

    #if DEBUG
    /// What ``take()`` would return, without taking it. For tests.
    var posted: [ObjectIdentifier: AttributeNode] {
        pending.withLock { $0 }
    }
    #endif
}
