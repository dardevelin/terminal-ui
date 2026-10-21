// `Timeline` marker protocol unifying FrameTimeline and
// CurveTimeline. Useful when consumers want to hold "any timeline"
// without distinguishing between frame-stepped and eased forms.

/// A running animation source — the common lifecycle shared by
/// ``FrameTimeline`` (frame-stepped) and ``CurveTimeline`` (eased).
/// Hold `any Timeline` when the stepping model doesn't matter.
@MainActor
public protocol Timeline: AnyObject {
    /// Where the timeline is in its lifecycle; see ``AnimationPhase``.
    var phase: AnimationPhase { get }
    /// Begins advancing from the beginning; the phase becomes `.running`.
    func start()
    /// Freezes progress at the current position.
    func pause()
    /// Continues from where ``pause()`` froze; no-op unless paused.
    func resume()
    /// Returns to `.idle` at position zero, ready for a fresh ``start()``.
    func reset()
}

extension FrameTimeline: Timeline {}
extension CurveTimeline: Timeline {}
