import Foundation
import Synchronization

/// Work that blocks in the kernel — a `poll()`, a `read()` — run on a thread
/// of its own, with its result awaited like a task's.
///
/// Swift's cooperative pool has a thread per core, and a task that blocks in
/// a system call holds its thread until the call returns. The input loop
/// blocks between events for the app's whole life: run as a detached task,
/// it held one pool thread for good, and where the pool is one or two
/// threads wide — a small container, a CI runner — timers and every task the
/// app started queued behind it, and a test suite that ran several apps at
/// once deadlocked.
final class BlockingThread<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }

    private let state = Mutex(State())

    /// Starts `work` on a new thread named `name`.
    init(name: String, _ work: @escaping @Sendable () -> Value) {
        // The thread holds this object until the work is done, so a caller
        // that never awaits the value still lets it finish.
        let thread = Thread { [self] in finish(work()) }
        thread.name = name
        thread.start()
    }

    private func finish(_ value: Value) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    /// What the work returned, once it has. One caller awaits it.
    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let finished = state.withLock { state -> Value? in
                    if let value = state.value { return value }
                    state.waiter = continuation
                    return nil
                }
                if let finished { continuation.resume(returning: finished) }
            }
        }
    }
}
