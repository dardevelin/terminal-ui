import Foundation

// HYP-302 — Timeline animation primitive. Pull-based: each timeline
// computes `currentFrame` / `progress` on demand from a clock,
// rather than being driven by a per-frame registry tick. This keeps
// the framework's existing render loop unchanged — views observing
// a timeline re-render naturally when the renderer next walks them.
//
// Wall-clock-based by default; tests inject a TestClock to advance
// virtual time deterministically.

/// Time source for timelines. Production uses `WallClock`; tests
/// inject a deterministic clock to exercise time-dependent
/// behaviour without sleeping.
@MainActor
public protocol TimelineClock: AnyObject {
    /// Monotonic elapsed time since some fixed reference. Only the
    /// delta between calls matters; the absolute origin is opaque.
    func now() -> Duration
}

/// Wall-clock implementation. Uses `ContinuousClock` internally to
/// avoid drift from system-clock adjustments.
@MainActor
public final class WallClock: TimelineClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = clock.now
    }

    public func now() -> Duration {
        clock.now - origin
    }
}

/// Lifecycle phase of an animated timeline.
public enum AnimationPhase: Sendable, Equatable {
    /// Created but not yet started.
    case idle
    /// Advancing as the clock moves forward.
    case running
    /// Explicitly paused via `pause()`. `resume()` continues from
    /// the same frame.
    case paused
    /// Finished — non-repeating timelines reach this when the
    /// clock passes their duration / last frame.
    case finished
}

/// Animation curve for `CurveTimeline`. Maps linear time fraction
/// (0..1) to eased progress. Names match SwiftUI's defaults so
/// consumer parity is intuitive.
public enum AnimationCurve: Sendable, Equatable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    /// Apply this curve's easing function to a time fraction in
    /// 0..1. Output is also clamped to 0..1.
    public func apply(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        switch self {
        case .linear:
            return clamped
        case .easeIn:
            // Quadratic ease-in: t² — slow start, fast end.
            return clamped * clamped
        case .easeOut:
            // Quadratic ease-out: 1 - (1-t)² — fast start, slow end.
            let inverse = 1.0 - clamped
            return 1.0 - inverse * inverse
        case .easeInOut:
            // Cubic-style smoothstep: 3t² - 2t³.
            return clamped * clamped * (3.0 - 2.0 * clamped)
        }
    }
}
