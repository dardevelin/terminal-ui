import Synchronization

/// Wakes the frame loop when there is something to do.
///
/// Every source of work — an event, a change to observed state, a remote
/// command — calls ``wake()`` from whatever thread it runs on, and the frame
/// loop, with nothing to do, suspends in ``wait()`` instead of polling. A
/// wake that arrives while nobody waits is kept, so work raised between the
/// loop's last check and its wait is never slept through; wakes before a
/// wait are one wake, since the loop drains everything when it runs.
final class WakeSignal: Sendable {
    private struct State {
        var pending = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Wakes the waiting loop, or the next ``wait()`` if none is waiting.
    func wake() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let waiter = state.waiter else {
                state.pending = true
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Forgets a wake nobody waited for. For a loop about to check for work
    /// itself: a wake raised after this still counts.
    func discardPending() {
        state.withLock { $0.pending = false }
    }

    /// Returns once ``wake()`` has been called since the last wait, or the
    /// task is cancelled.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Checked under the lock the cancellation handler takes, and
                // the task is marked cancelled before that handler runs: so
                // either the handler finds this waiter, or this sees the
                // cancellation.
                let resumeNow = state.withLock { state -> Bool in
                    if state.pending || Task.isCancelled {
                        state.pending = false
                        return true
                    }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }
}
