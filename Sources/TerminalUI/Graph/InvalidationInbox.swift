import Synchronization

/// The nodes whose observed state changed since the main actor last looked.
///
/// Observation calls `onChange` on whichever thread made the change, and an
/// app may change an `@Observable` model from a background task, as SwiftUI
/// allows. The graph is main-actor state that the frame reads, so an
/// `onChange` closure holds this inbox rather than the graph: it can post a
/// node and do nothing else, and because the inbox is a checked `Sendable`,
/// the compiler keeps it that way.
final class InvalidationInbox: Sendable {
    private let pending = Mutex<[ObjectIdentifier: AttributeNode]>([:])
    /// `!pending.isEmpty`, written under the lock, so the frame loop can ask
    /// whether there is work without taking it.
    private let nonEmpty = Atomic<Bool>(false)

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

    #if DEBUG
    /// What ``take()`` would return, without taking it. For tests.
    var posted: [ObjectIdentifier: AttributeNode] {
        pending.withLock { $0 }
    }
    #endif
}
