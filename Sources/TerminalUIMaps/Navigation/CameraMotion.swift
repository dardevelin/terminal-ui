import Foundation

/// What a following camera keeps track of: the traveller it pivots on, the
/// way the map is turned, and how far in it is. The camera itself — its
/// centre lifted so the traveller sits low in the view — follows from these
/// (``FollowCamera/camera(for:current:viewport:)``); animating the pose,
/// not the camera, is what makes the map turn about the traveller rather
/// than about the middle of the screen.
struct FollowPose: Sendable, Equatable {
    var focus: GeoCoordinate
    /// Degrees clockwise from north, as ``MapCamera/bearing``.
    var bearing: Double
    var zoom: Double

    init(focus: GeoCoordinate, bearing: Double, zoom: Double) {
        self.focus = focus
        self.bearing = bearing
        self.zoom = zoom
    }
}

/// How fast ``CameraMotion`` closes on its target.
///
/// Each quantity approaches its target exponentially — a first-order lag,
/// the same whatever the frame rate, since the step a frame takes is
/// `1 − e^(−Δt/τ)` of what is left — and the bearing is held besides to a
/// turn rate, so a reversal is a sweep and not a spin. Navigation SDKs
/// smooth the puck and camera the same way (Mapbox Navigation's
/// `NavigationCameraStateTransition`, MapLibre's `easeTo`); the time
/// constants are chosen by eye on the sample drive.
struct CameraMotionConfiguration: Sendable, Equatable {
    /// Whether the camera eases at all; off, each frame takes the target as
    /// it is — the camera as it was before easing, kept for comparison and
    /// for those who want it.
    var isSmooth = true
    /// Seconds for the bearing to close all but 1/e of a turn.
    var bearingSmoothing = 0.45
    /// The fastest the map turns, degrees a second: a quarter turn in no
    /// less than about 0.75 s.
    var maximumTurnRate = 120.0
    /// Seconds for the focus to close all but 1/e of a correction. Short:
    /// the predicted traveller already moves smoothly, and this only takes
    /// up the difference when a fix disagrees with the prediction.
    var focusSmoothing = 0.15
    /// Seconds for the zoom to close all but 1/e of a change: zoom follows
    /// speed, and should not pump with every fix.
    var zoomSmoothing = 0.8
    /// Farther than this, in metres, the focus jumps rather than flies: a
    /// reroute across town or a new search is not a drive.
    var jumpDistance = 2_000.0

    /// Within these the motion is done and the app may stop drawing frames.
    var settledBearing = 0.25
    var settledDistance = 0.25
    var settledZoom = 0.005

    init() {}
}

/// A following camera's pose, eased frame by frame toward where it should
/// be. A pure value: the app advances it by each frame's elapsed time —
/// from a ``TimelineView`` while ``isSettled(toward:)`` is false — and
/// draws the camera of ``pose``.
struct CameraMotion: Sendable, Equatable {
    var configuration: CameraMotionConfiguration
    private(set) var pose: FollowPose

    init(pose: FollowPose, configuration: CameraMotionConfiguration = CameraMotionConfiguration()) {
        self.pose = pose
        self.configuration = configuration
    }

    /// Takes the pose as it is, with no motion: after the user moves the
    /// map, so that following resumes from where they left it.
    mutating func reset(to pose: FollowPose) {
        self.pose = pose
    }

    /// Moves `seconds` of the way toward `target`.
    mutating func advance(toward target: FollowPose, by seconds: Double) {
        guard seconds > 0 else { return }
        if !configuration.isSmooth || GeoMeasure.distance(pose.focus, target.focus) > configuration.jumpDistance {
            pose = target
            return
        }
        let focusShare = Self.share(of: seconds, smoothing: configuration.focusSmoothing)
        pose.focus = GeoMeasure.interpolate(pose.focus, target.focus, fraction: focusShare)

        let remaining = Self.signedTurn(from: pose.bearing, to: target.bearing)
        let eased = remaining * Self.share(of: seconds, smoothing: configuration.bearingSmoothing)
        let limit = configuration.maximumTurnRate * seconds
        pose.bearing = GeoMeasure.normalizedBearing(pose.bearing + min(max(eased, -limit), limit))

        pose.zoom += (target.zoom - pose.zoom) * Self.share(of: seconds, smoothing: configuration.zoomSmoothing)
    }

    /// Whether the pose is as near `target` as makes no visible difference.
    func isSettled(toward target: FollowPose) -> Bool {
        abs(Self.signedTurn(from: pose.bearing, to: target.bearing)) <= configuration.settledBearing
            && GeoMeasure.distance(pose.focus, target.focus) <= configuration.settledDistance
            && abs(pose.zoom - target.zoom) <= configuration.settledZoom
    }

    /// The share of the remaining distance a first-order lag with time
    /// constant `smoothing` closes in `seconds`.
    private static func share(of seconds: Double, smoothing: Double) -> Double {
        guard smoothing > 0 else { return 1 }
        return 1 - exp(-seconds / smoothing)
    }

    /// The turn from one bearing to another the short way round, in
    /// (−180, 180].
    static func signedTurn(from start: Double, to end: Double) -> Double {
        let turn = GeoMeasure.normalizedBearing(end - start)
        return turn > Self.halfTurn ? turn - Self.fullTurn : turn
    }

    private static let halfTurn = 180.0
    private static let fullTurn = 360.0
}
