// HYP-302 — `Timeline` marker protocol unifying FrameTimeline and
// CurveTimeline. Useful when consumers want to hold "any timeline"
// without distinguishing between frame-stepped and eased forms.
// Avatar (HYP-303) consumes this for animated-image sources.

@MainActor
public protocol Timeline: AnyObject {
    var phase: AnimationPhase { get }
    func start()
    func pause()
    func resume()
    func reset()
}

extension FrameTimeline: Timeline {}
extension CurveTimeline: Timeline {}
