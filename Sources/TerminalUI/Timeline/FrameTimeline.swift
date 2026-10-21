import Foundation
import Observation

// Frame-stepped timeline. Advances an integer frame
// counter at a fixed fps. Useful for frame-by-frame animations
// (Spinner glyph cycle, animated image frames, MorseTicker dot
// scan) where the consumer renders the N-th frame from a fixture
// array.

/// Advances a 0..<frames integer counter at a fixed fps. When
/// `repeats` is true the counter wraps; otherwise it clamps at the
/// last frame and the timeline transitions to `.finished`.
@Observable
@MainActor
public final class FrameTimeline {
    /// Total frame count; ``currentFrame`` ranges over `0..<frames`.
    public let frames: Int
    /// Frames advanced per second of clock time.
    public let fps: Int
    /// `true` wraps the counter; `false` clamps at the last frame and
    /// finishes.
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

    /// Creates a frame-stepped timeline; call ``start()`` to begin.
    /// `clock` `nil` uses a fresh ``WallClock`` (tests inject a
    /// deterministic one).
    public init(frames: Int, fps: Int, repeats: Bool = true, clock: (any TimelineClock)? = nil) {
        self.frames = frames
        self.fps = fps
        self.repeats = repeats
        self.clock = clock ?? WallClock()
    }

    /// The frame index for the current clock time, computed on demand.
    /// 0 before ``start()``; wraps or clamps per ``repeats``.
    public var currentFrame: Int {
        guard let startedAt else { return 0 }
        let elapsed = elapsedRunning(referenceStart: startedAt)
        let totalFrames = Int(elapsed.seconds * Double(fps))
        if repeats {
            return frames > 0 ? totalFrames % frames : 0
        } else {
            return min(totalFrames, max(0, frames - 1))
        }
    }

    public var phase: AnimationPhase {
        if explicitPhase == .paused { return .paused }
        if startedAt == nil { return .idle }
        if !repeats {
            // Finished when we've crossed the duration covering all frames.
            guard let startedAt else { return .idle }
            let elapsed = elapsedRunning(referenceStart: startedAt)
            let totalFrames = Int(elapsed.seconds * Double(fps))
            if totalFrames >= frames { return .finished }
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
        // Add the time spent paused to the accumulator so the
        // timeline picks up where it left off.
        pausedAccumulated += clock.now() - pausedAt
        self.pausedAt = nil
    }

    public func reset() {
        explicitPhase = .idle
        startedAt = nil
        pausedAt = nil
        pausedAccumulated = .zero
    }

    /// Effective elapsed time, deducting any paused intervals.
    /// When currently paused, freezes at the moment of the pause.
    private func elapsedRunning(referenceStart: Duration) -> Duration {
        let now = explicitPhase == .paused ? (pausedAt ?? clock.now()) : clock.now()
        let raw = now - referenceStart
        return raw - pausedAccumulated
    }
}

extension Duration {
    /// Convert to seconds as a Double. Used by timelines to compute
    /// frame counts or progress fractions.
    var seconds: Double {
        let (whole, attoseconds) = self.components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
