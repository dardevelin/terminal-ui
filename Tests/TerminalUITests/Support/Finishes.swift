import Testing

/// How long a test waits for something that happens in its own time — a
/// task, a thread, a wake — before calling it a regression. A passing run
/// returns as soon as it happens, so only a regression ever waits this long,
/// and the limit is set for CI's three-core runner under Thread Sanitizer,
/// not for a fast Mac: there, a cursor flash waited 8 s for the main actor
/// behind every other test, and a reader thread had not started 200 ms after
/// it was spawned. A test that checks something does *not* happen within a
/// time keeps that time short: that is its point.
let eventualLimit: Duration = .seconds(60)

/// Whether `wait` finishes within `limit`.
func finishes(within limit: Duration, _ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
