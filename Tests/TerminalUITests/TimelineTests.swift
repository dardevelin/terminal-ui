import Foundation
import Testing
@testable import TerminalUI

// HYP-302 — Timeline animation primitive. Two concrete timelines:
// FrameTimeline (advances integer frame counter at fps) and
// CurveTimeline (eased 0..1 progress over a Duration). Both
// `@Observable` so views observing `currentFrame` re-render as
// the timeline advances.
//
// Tests use a clock-injected init so tests can advance virtual
// time without sleeping. Production code uses the real clock.

@Suite("Timeline — FrameTimeline + CurveTimeline + AnimationPhase")
@MainActor
struct TimelineTests {

    // MARK: - FrameTimeline

    @Test("frame timeline starts in idle phase, frame 0")
    func frameTimelineStartsIdle() {
        let timeline = FrameTimeline(frames: 4, fps: 10)
        #expect(timeline.phase == .idle)
        #expect(timeline.currentFrame == 0)
    }

    @Test("start transitions to running")
    func frameTimelineStartTransitionsToRunning() {
        let timeline = FrameTimeline(frames: 4, fps: 10)
        timeline.start()
        #expect(timeline.phase == .running)
    }

    @Test("frame advances proportionally to elapsed time at fps")
    func frameAdvancesAtFps() {
        let clock = TestClock()
        let timeline = FrameTimeline(frames: 8, fps: 10, clock: clock)
        timeline.start()
        // 0.0s → frame 0
        #expect(timeline.currentFrame == 0)
        clock.advance(by: .milliseconds(100))  // 1/fps
        #expect(timeline.currentFrame == 1)
        clock.advance(by: .milliseconds(300))  // +3 frames
        #expect(timeline.currentFrame == 4)
    }

    @Test("repeating timeline wraps to 0 after last frame")
    func repeatingTimelineWraps() {
        let clock = TestClock()
        let timeline = FrameTimeline(frames: 4, fps: 10, repeats: true, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(500))  // 5 frames into a 4-frame cycle
        // Frame 5 % 4 = 1.
        #expect(timeline.currentFrame == 1)
    }

    @Test("non-repeating timeline finishes at last frame")
    func nonRepeatingTimelineFinishes() {
        let clock = TestClock()
        let timeline = FrameTimeline(frames: 4, fps: 10, repeats: false, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(500))  // past last frame
        #expect(timeline.currentFrame == 3, "should clamp to last frame")
        #expect(timeline.phase == .finished)
    }

    @Test("pause halts advancement; resume continues from same frame")
    func pauseAndResume() {
        let clock = TestClock()
        let timeline = FrameTimeline(frames: 8, fps: 10, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(200))  // frame 2
        timeline.pause()
        #expect(timeline.phase == .paused)
        let pausedFrame = timeline.currentFrame
        clock.advance(by: .milliseconds(500))  // would be frame 7 if running
        #expect(timeline.currentFrame == pausedFrame, "paused timeline shouldn't advance")
        timeline.resume()
        #expect(timeline.phase == .running)
        clock.advance(by: .milliseconds(100))  // one more frame
        #expect(timeline.currentFrame == pausedFrame + 1)
    }

    @Test("reset returns to frame 0 and idle phase")
    func resetReturnsToZero() {
        let clock = TestClock()
        let timeline = FrameTimeline(frames: 8, fps: 10, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(300))
        timeline.reset()
        #expect(timeline.currentFrame == 0)
        #expect(timeline.phase == .idle)
    }

    // MARK: - CurveTimeline

    @Test("curve timeline starts at progress 0")
    func curveTimelineStartsAtZero() {
        let timeline = CurveTimeline(duration: .milliseconds(500))
        #expect(timeline.progress == 0.0)
        #expect(timeline.phase == .idle)
    }

    @Test("linear curve progresses at constant rate")
    func linearCurveProgressesLinearly() {
        let clock = TestClock()
        let timeline = CurveTimeline(duration: .milliseconds(500), curve: .linear, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(250))  // half the duration
        #expect(timeline.progress >= 0.49 && timeline.progress <= 0.51,
                "linear at 50% time should be 50% progress; got \(timeline.progress)")
    }

    @Test("easeIn starts slow")
    func easeInStartsSlow() {
        let clock = TestClock()
        let timeline = CurveTimeline(duration: .milliseconds(500), curve: .easeIn, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(125))  // 25% time
        // easeIn at 25% time should be < 25% progress (slow start).
        #expect(timeline.progress < 0.25,
                "easeIn at 25% time should be < 25% progress; got \(timeline.progress)")
    }

    @Test("easeOut starts fast")
    func easeOutStartsFast() {
        let clock = TestClock()
        let timeline = CurveTimeline(duration: .milliseconds(500), curve: .easeOut, clock: clock)
        timeline.start()
        clock.advance(by: .milliseconds(125))  // 25% time
        // easeOut at 25% time should be > 25% progress (fast start).
        #expect(timeline.progress > 0.25,
                "easeOut at 25% time should be > 25% progress; got \(timeline.progress)")
    }

    @Test("curve timeline finishes when duration elapses")
    func curveTimelineFinishes() {
        let clock = TestClock()
        let timeline = CurveTimeline(duration: .milliseconds(500), curve: .linear, clock: clock)
        timeline.start()
        clock.advance(by: .seconds(1))
        #expect(timeline.progress == 1.0)
        #expect(timeline.phase == .finished)
    }

    // MARK: - Timeline protocol unifies concrete types

    @Test("FrameTimeline and CurveTimeline both conform to Timeline")
    func bothConformToTimelineProtocol() {
        let frame: any Timeline = FrameTimeline(frames: 4, fps: 10)
        let curve: any Timeline = CurveTimeline(duration: .milliseconds(500))
        #expect(frame.phase == .idle)
        #expect(curve.phase == .idle)
    }
}

// MARK: - Test clock

/// Deterministic clock for testing. Advance virtual time without
/// sleeping. Production code uses the wall-clock default.
@MainActor
final class TestClock: TimelineClock {
    private var elapsed: Duration = .zero
    func now() -> Duration { elapsed }
    func advance(by delta: Duration) {
        elapsed += delta
    }
}
