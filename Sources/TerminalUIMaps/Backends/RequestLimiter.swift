/// Spaces requests out: each caller waits its turn.
protocol RequestPacing: Sendable {
    /// Returns when the caller may send its request.
    func waitForTurn() async throws
}

/// At most one request per `interval`, in the order callers arrive. Each
/// caller is given the next free slot before it sleeps, so callers that
/// arrive together go out one interval apart rather than all at once when
/// a sleep ends. The wait is the clock's `sleep`, which suspends the task
/// and holds no thread.
actor RequestLimiter<LimiterClock: Clock>: RequestPacing where LimiterClock.Duration == Duration {
    private let interval: Duration
    private let clock: LimiterClock
    private var nextSlot: LimiterClock.Instant?

    init(interval: Duration, clock: LimiterClock) {
        self.interval = interval
        self.clock = clock
    }

    func waitForTurn() async throws {
        let now = clock.now
        let slot = nextSlot.map { max($0, now) } ?? now
        nextSlot = slot.advanced(by: interval)
        if slot > now {
            try await clock.sleep(until: slot, tolerance: nil)
        }
    }
}

extension RequestLimiter where LimiterClock == ContinuousClock {
    /// A limiter on the system's continuous clock.
    init(interval: Duration) {
        self.init(interval: interval, clock: ContinuousClock())
    }
}
