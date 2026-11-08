import Testing

/// How long a test waits for a main-actor job to get its turn before calling
/// it a regression. Every `@MainActor` test in the run shares the one main
/// actor: on CI's three-core runner under Thread Sanitizer, a cursor flash
/// waited 8 s for its turn behind them while the loop under test yielded on
/// every pass, and a 5 s limit failed a correct run. A passing run returns
/// as soon as the job runs, so only a regression ever waits this long.
let mainActorTurnLimit: Duration = .seconds(60)

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
