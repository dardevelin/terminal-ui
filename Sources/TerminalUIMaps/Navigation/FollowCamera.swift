import Foundation

/// How a camera follows a traveller: heading up once they move faster than
/// a walk, the traveller low on the screen so more of the road ahead
/// shows, and closer the slower they go — each as the traveller's
/// ``TravelProfile`` says.
struct FollowCameraConfiguration: Sendable, Equatable {
    typealias Orientation = NavigationCamera.Orientation

    /// Which way the map faces; switchable while following, the map then
    /// turning to the new orientation.
    var orientation = Orientation.headingUp
    /// The bearing a ``Orientation/locked`` map keeps, degrees clockwise
    /// from north.
    var lockedBearing = 0.0
    /// Whether the zoom reads the junctions ahead (``JunctionZoom``); off,
    /// it is the speed table's alone.
    var zoomsForJunctions = true
    /// Above this speed, in metres a second, the map turns so the course
    /// points up; below it the bearing holds.
    var headingUpSpeed: Double
    /// Where the traveller sits, as a share of the view's height from its
    /// top: a third from the bottom.
    var travellerHeightShare = 2.0 / 3.0
    /// The zoom at each speed, interpolated between.
    var zoomBySpeed: [SpeedZoom]

    init(profile: TravelProfile = .car) {
        headingUpSpeed = profile.headingUpSpeed
        zoomBySpeed = profile.zoomBySpeed
    }

    /// Take a profile's speeds, keeping the orientation and the switches.
    mutating func apply(_ profile: TravelProfile) {
        headingUpSpeed = profile.headingUpSpeed
        zoomBySpeed = profile.zoomBySpeed
    }

    /// The zoom for a speed, held to the table's ends.
    func zoom(forSpeed speed: Double) -> Double {
        guard let first = zoomBySpeed.first, let last = zoomBySpeed.last else { return MapCamera.defaultZoomRange.upperBound }
        guard speed > first.speed else { return first.zoom }
        guard speed < last.speed else { return last.zoom }
        for (lower, upper) in zip(zoomBySpeed, zoomBySpeed.dropFirst()) where speed <= upper.speed {
            let fraction = (speed - lower.speed) / (upper.speed - lower.speed)
            return lower.zoom + (upper.zoom - lower.zoom) * fraction
        }
        return last.zoom
    }
}

/// The camera following a traveller, until the user moves the map.
///
/// The app hands every fix to ``camera(for:course:speed:current:viewport:)``
/// while ``isFollowing``; a pan or a zoom by the user calls
/// ``userMovedCamera()``, and the map stays where they put it until
/// ``recentre()``.
struct FollowCamera: Sendable, Equatable {
    var configuration: FollowCameraConfiguration
    private(set) var isFollowing = true

    init(configuration: FollowCameraConfiguration = FollowCameraConfiguration()) {
        self.configuration = configuration
    }

    mutating func userMovedCamera() {
        isFollowing = false
    }

    mutating func recentre() {
        isFollowing = true
    }

    // MARK: - Orientation

    /// `u`: heading up, then north up, then locked at the bearing the map
    /// has now, then heading up again.
    @discardableResult
    mutating func cycleOrientation(currentBearing: Double) -> FollowCameraConfiguration.Orientation {
        switch configuration.orientation {
        case .headingUp:
            configuration.orientation = .northUp
        case .northUp:
            configuration.orientation = .locked
            configuration.lockedBearing = GeoMeasure.normalizedBearing(currentBearing)
        case .locked:
            configuration.orientation = .headingUp
        }
        return configuration.orientation
    }

    /// Turn a following map by hand, `degrees` clockwise from where it is
    /// headed: it then stays locked there, as Apple Maps stops turning the
    /// map with the course once the user rotates it.
    mutating func rotate(by degrees: Double, currentBearing: Double) {
        let from = configuration.orientation == .locked ? configuration.lockedBearing : currentBearing
        configuration.orientation = .locked
        configuration.lockedBearing = GeoMeasure.normalizedBearing(from + degrees)
    }

    /// What a tap on the compass does to a following map: a turned map
    /// goes north up; one north up already goes heading up. Apple Maps'
    /// compass takes a turned map north up the same way.
    mutating func compassTapped(currentBearing: Double) {
        if MapCompassReading(bearing: currentBearing).isRotated {
            configuration.orientation = .northUp
        } else {
            configuration.orientation = .headingUp
        }
    }

    // MARK: - Poses

    /// The camera that shows a traveller at `coordinate` going `course` at
    /// `speed`: turned so the course is up when they are moving faster than
    /// a walk, else at `current`'s bearing; zoomed for the speed; and
    /// centred so the traveller lands `travellerHeightShare` down the view.
    func camera(for coordinate: GeoCoordinate, course: Double?, speed: Double?, current: MapCamera,
                       viewport: DotSize) -> MapCamera {
        camera(for: pose(for: coordinate, course: course, speed: speed, bearing: current.bearing),
               current: current, viewport: viewport)
    }

    /// Which way the map faces for a traveller going `course` at `speed`
    /// while it faces `bearing` now.
    func facing(course: Double?, speed: Double?, bearing: Double) -> Double {
        switch configuration.orientation {
        case .northUp:
            0
        case .locked:
            configuration.lockedBearing
        case .headingUp:
            course.flatMap { course in (speed ?? 0) >= configuration.headingUpSpeed ? course : nil } ?? bearing
        }
    }

    /// Where the camera should be for a traveller: pivoting on them; facing
    /// as ``facing(course:speed:bearing:)`` says; at `zoom` when one is
    /// given — ``JunctionZoom``'s — else the speed's. ``CameraMotion`` eases
    /// toward it.
    func pose(for coordinate: GeoCoordinate, course: Double?, speed: Double?,
                     bearing: Double, zoom: Double? = nil) -> FollowPose {
        FollowPose(focus: coordinate, bearing: facing(course: course, speed: speed, bearing: bearing),
                   zoom: zoom ?? configuration.zoom(forSpeed: speed ?? 0))
    }

    /// The camera of a pose: `current` turned and zoomed as the pose says,
    /// centred so the pose's focus lands `travellerHeightShare` down the
    /// view.
    func camera(for pose: FollowPose, current: MapCamera, viewport: DotSize) -> MapCamera {
        var camera = current
        camera.bearing = pose.bearing
        camera.zoom = pose.zoom
        camera.center = pose.focus
        // With the traveller in the middle, the point as far above the
        // middle as the traveller is to sit below it becomes the centre.
        let lift = viewport.height * (configuration.travellerHeightShare - FollowCamera.middle)
        camera.center = camera.coordinate(at: DotPoint(x: viewport.width / 2, y: viewport.height / 2 - lift),
                                          in: viewport)
        return camera
    }

    private static let middle = 0.5
}
