import Foundation
import Observation

// Eased-progress timeline. Reports `progress` in 0..1
// over a fixed duration with an animation curve applied. Useful
// for transitions (TabView focus indicator slide, Modal fade-in,
// ProgressBar indeterminate sweep) where the consumer interpolates
// a value between two endpoints.

/// Reports `progress` in 0..1 over a fixed duration with easing
/// applied. When the duration elapses the timeline transitions to
/// `.finished`. Repeating timelines reset progress to 0 at the
/// boundary.
@Observable
@MainActor
public final class CurveTimeline {
    /// Wall time one full sweep of `progress` 0 → 1 takes.
    public let duration: Duration
    /// Easing applied to the linear time fraction.
    public let curve: AnimationCurve
    /// `true` wraps progress back to 0 at each boundary; `false` finishes
    /// at 1.
    public let repeats: Bool

    @ObservationIgnored
    private let clock: any TimelineClock
    @ObservationIgnored
    private var startedAt: Duration?
    @ObservationIgnored
    private var pausedAccumulated: Duration = .zero
    @ObservationIgnored
    private var pausedAt: Duration?

    private var explicitPhase: AnimationPhase = .idle

    /// Creates an eased timeline; call ``start()`` to begin. `clock`
    /// `nil` uses a fresh ``WallClock`` (tests inject a deterministic
    /// one).
    public init(
        duration: Duration,
        curve: AnimationCurve = .easeInOut,
        repeats: Bool = false,
        clock: (any TimelineClock)? = nil
    ) {
        self.duration = duration
        self.curve = curve
        self.repeats = repeats
        self.clock = clock ?? WallClock()
    }

    /// Eased progress in `0...1`, computed on demand from the clock.
    /// 0 before ``start()``; repeating timelines wrap at each boundary.
    public var progress: Double {
        guard let startedAt else { return 0.0 }
        let elapsed = elapsedRunning(referenceStart: startedAt).seconds
        let durationSeconds = duration.seconds
        guard durationSeconds > 0 else { return 1.0 }
        let raw = elapsed / durationSeconds
        if repeats {
            // Wrap the time fraction; modf-equivalent for Double.
            let fractional = raw.truncatingRemainder(dividingBy: 1.0)
            return curve.apply(fractional < 0 ? fractional + 1.0 : fractional)
        } else {
            return curve.apply(min(1.0, raw))
        }
    }

    public var phase: AnimationPhase {
        if explicitPhase == .paused { return .paused }
        if startedAt == nil { return .idle }
        if !repeats {
            guard let startedAt else { return .idle }
            let elapsed = elapsedRunning(referenceStart: startedAt).seconds
            if elapsed >= duration.seconds { return .finished }
        }
        return .running
    }

    public func start() {
        explicitPhase = .running
        startedAt = clock.now()
        pausedAccumulated = .zero
        pausedAt = nil
    }

    public func pause() {
        guard explicitPhase == .running else { return }
        explicitPhase = .paused
        pausedAt = clock.now()
    }

    public func resume() {
        guard explicitPhase == .paused, let pausedAt else { return }
        explicitPhase = .running
        pausedAccumulated += clock.now() - pausedAt
        self.pausedAt = nil
    }

    public func reset() {
        explicitPhase = .idle
        startedAt = nil
        pausedAt = nil
        pausedAccumulated = .zero
    }

    private func elapsedRunning(referenceStart: Duration) -> Duration {
        let now = explicitPhase == .paused ? (pausedAt ?? clock.now()) : clock.now()
        let raw = now - referenceStart
        return raw - pausedAccumulated
    }
}
