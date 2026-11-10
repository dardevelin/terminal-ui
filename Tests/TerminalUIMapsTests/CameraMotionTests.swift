import Foundation
import Testing
@testable import TerminalUIMaps

// A heading-up map turned to each fix's course as the fix arrived: a track
// rounding a corner between two fixes turned the map a quarter at once. The
// camera now eases toward its target, the short way round and no faster than
// a turn rate, pivoting on the traveller; and the traveller is carried along
// the route between fixes, its heading taken from the route ahead.

@Suite("The camera turns and moves smoothly")
struct CameraMotionTests {
    private let viewport = DotSize(width: 200, height: 120)
    private let origin = GeoCoordinate(latitude: 0.02, longitude: 0.02)

    private func pose(bearing: Double, zoom: Double = 17) -> FollowPose {
        FollowPose(focus: origin, bearing: bearing, zoom: zoom)
    }

    @Test("A turn across north goes the short way round")
    func shortWay() {
        var motion = CameraMotion(pose: pose(bearing: 350))
        motion.advance(toward: pose(bearing: 10), by: 0.1)
        let turned = GeoMeasure.normalizedBearing(motion.pose.bearing - 350)
        #expect(turned > 0 && turned < 20, "turned \(turned)° from 350°")
    }

    @Test("A quarter turn is spread over frames, never taken at once")
    func turnRateLimited() {
        let configuration = CameraMotionConfiguration()
        var motion = CameraMotion(pose: pose(bearing: 0))
        motion.advance(toward: pose(bearing: 90), by: 1.0 / 60)
        #expect(motion.pose.bearing > 0)
        #expect(motion.pose.bearing <= configuration.maximumTurnRate / 60 + 1e-9)
    }

    @Test("The camera settles on its target")
    func settles() {
        var motion = CameraMotion(pose: pose(bearing: 0, zoom: 15))
        let target = FollowPose(focus: GeoMeasure.destination(from: origin, bearing: 45, distance: 30),
                                bearing: 120, zoom: 17)
        #expect(!motion.isSettled(toward: target))
        for _ in 0..<(60 * 5) { motion.advance(toward: target, by: 1.0 / 60) }
        #expect(motion.isSettled(toward: target))
        #expect(abs(motion.pose.bearing - 120) < 1)
        #expect(abs(motion.pose.zoom - 17) < 0.05)
    }

    @Test("Frames of any length reach the same place in the same time")
    func frameRateIndependent() {
        let target = pose(bearing: 60, zoom: 16)
        var fast = CameraMotion(pose: pose(bearing: 0, zoom: 17))
        var slow = fast
        for _ in 0..<60 { fast.advance(toward: target, by: 1.0 / 60) }
        for _ in 0..<10 { slow.advance(toward: target, by: 1.0 / 10) }
        #expect(abs(fast.pose.bearing - slow.pose.bearing) < 3)
        #expect(abs(fast.pose.zoom - slow.pose.zoom) < 0.05)
    }

    @Test("A jump too far to fly is taken at once")
    func farJumpSnaps() {
        var motion = CameraMotion(pose: pose(bearing: 0))
        let far = FollowPose(focus: GeoMeasure.destination(from: origin, bearing: 90, distance: 50_000),
                             bearing: 0, zoom: 17)
        motion.advance(toward: far, by: 1.0 / 60)
        #expect(GeoMeasure.distance(motion.pose.focus, far.focus) < 1)
    }

    @Test("While the map turns, the traveller stays where the follow camera puts them")
    func pivotsOnTraveller() {
        let follow = FollowCamera()
        var motion = CameraMotion(pose: pose(bearing: 0))
        let current = MapCamera(center: origin, zoom: 17)
        for _ in 0..<30 {
            motion.advance(toward: pose(bearing: 90), by: 1.0 / 60)
            let camera = follow.camera(for: motion.pose, current: current, viewport: viewport)
            let drawn = camera.screenPoint(for: origin, in: viewport)
            #expect(abs(drawn.x - viewport.width / 2) < 0.5)
            #expect(abs(drawn.y - viewport.height * follow.configuration.travellerHeightShare) < 0.5)
        }
    }
}

@Suite("The following camera's behaviours switch on and off")
struct FollowCameraSwitchTests {
    private let here = GeoCoordinate(latitude: 0.02, longitude: 0.02)

    @Test("North up keeps the map facing north whatever the course")
    func northUp() {
        var follow = FollowCamera()
        follow.configuration.orientation = .northUp
        #expect(follow.pose(for: here, course: 90, speed: 10, bearing: 45).bearing == 0)
        follow.configuration.orientation = .headingUp
        #expect(follow.pose(for: here, course: 90, speed: 10, bearing: 45).bearing == 90)
    }

    @Test("A pose takes the junctions' zoom when given one, else the speed's alone")
    func junctionZoomOrSpeed() {
        let follow = FollowCamera()
        let bySpeed = follow.configuration.zoom(forSpeed: 10)
        #expect(follow.pose(for: here, course: 90, speed: 10, bearing: 0).zoom == bySpeed)
        #expect(follow.pose(for: here, course: 90, speed: 10, bearing: 0, zoom: bySpeed + 0.5).zoom == bySpeed + 0.5)
    }

    @Test("With easing off, the camera takes its target at once")
    func easingOff() {
        var configuration = CameraMotionConfiguration()
        configuration.isSmooth = false
        var motion = CameraMotion(pose: FollowPose(focus: here, bearing: 0, zoom: 15), configuration: configuration)
        let target = FollowPose(focus: here, bearing: 120, zoom: 17)
        motion.advance(toward: target, by: 1.0 / 60)
        #expect(motion.pose == target)
    }
}

@Suite("The traveller moves between fixes")
struct TravellerPredictionTests {
    /// East 200 m, then north 200 m: a corner at 200 m along.
    private let line: RouteLine = {
        let start = GeoCoordinate(latitude: 0.02, longitude: 0.02)
        let corner = GeoMeasure.destination(from: start, bearing: 90, distance: 200)
        let end = GeoMeasure.destination(from: corner, bearing: 0, distance: 200)
        return RouteLine([start, corner, end])
    }()

    @Test("Half a second after a fix at 10 m/s, the traveller is 5 m further along")
    func carriedAlong() {
        let estimate = TravellerPrediction().estimate(on: line, distanceAlong: 100, speed: 10, secondsSinceFix: 0.5)
        #expect(abs((estimate.distanceAlong ?? -1) - 105) < 1e-6)
        #expect(GeoMeasure.distance(estimate.coordinate, line.coordinate(atDistance: 105)) < 0.01)
    }

    @Test("A late fix does not carry the traveller on without end")
    func predictionCapped() {
        let prediction = TravellerPrediction()
        let estimate = prediction.estimate(on: line, distanceAlong: 100, speed: 10, secondsSinceFix: 30)
        #expect((estimate.distanceAlong ?? .infinity) <= 100 + 10 * prediction.configuration.maximumPrediction + 1e-6)
    }

    @Test("The heading turns before the corner, as the route ahead does")
    func headingLooksAhead() {
        let prediction = TravellerPrediction()
        let farBefore = prediction.estimate(on: line, distanceAlong: 50, speed: 10, secondsSinceFix: 0)
        let justBefore = prediction.estimate(on: line, distanceAlong: 190, speed: 10, secondsSinceFix: 0)
        let after = prediction.estimate(on: line, distanceAlong: 260, speed: 10, secondsSinceFix: 0)
        #expect(abs(farBefore.course - 90) < 1)
        #expect(justBefore.course > 1 && justBefore.course < 89, "\(justBefore.course)° should be mid-turn")
        #expect(abs(after.course) < 1 || abs(after.course - 360) < 1)
    }

    @Test("At the end of the route the traveller stops there")
    func stopsAtEnd() {
        let estimate = TravellerPrediction().estimate(on: line, distanceAlong: 398, speed: 10, secondsSinceFix: 1)
        #expect((estimate.distanceAlong ?? .infinity) <= line.length)
    }
}
