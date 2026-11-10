import Foundation
import TerminalUI

/// The camera of a map that follows a traveller, as a navigation app's
/// does: the traveller carried along the route between fixes, the map
/// turned to their heading and eased through each corner, and drawn back
/// before a junction that would not read at the speed's zoom.
///
/// Hand it each fix with ``receive(_:at:)``, and on every frame of a
/// `TimelineView` let it move the map's camera with
/// ``advance(to:camera:navigation:store:)``, which says whether the camera
/// is still moving — when it is not, the timeline can pause and the app go
/// idle. A pan or a zoom by the user stops the following until
/// ``recentre()``.
///
/// ```swift
/// TimelineView(.animation(paused: !model.isAnimating)) { context in
///     MapView(camera: $model.camera, store: model.store) {
///         model.navigationCamera.routeLines(for: model.navigation)
///         if let traveller = model.navigationCamera.traveller { traveller }
///     }
///     .onChange(of: context.date) { _, date in
///         model.isAnimating = model.navigationCamera.advance(
///             to: date, camera: &model.camera, navigation: model.navigation, store: model.store)
///     }
/// }
/// ```
public struct NavigationCamera: Sendable {
    /// Which way the map faces while following.
    public enum Orientation: Sendable, Equatable, CaseIterable {
        /// Turned so the direction of travel is up.
        case headingUp
        /// North up, as a paper map.
        case northUp
        /// Held at ``NavigationCamera/lockedBearing`` whatever the course:
        /// the map the user turned by hand, as Apple Maps keeps it once
        /// rotated while following.
        case locked
    }

    /// How the traveller moves: the speeds the camera stands back at, when
    /// the map turns heading up, how far ahead it looks and what a junction
    /// needs to read. Set from the route's ``TravelMode``, and switchable
    /// while following.
    public var profile: TravelProfile {
        didSet {
            follow.configuration.apply(profile)
            prediction = TravellerPrediction(configuration: profile.lookAhead)
            junctionZoom = JunctionZoom(profile: profile)
            junctionsKey = nil
        }
    }

    /// How many seconds of the road a second on screen is: 1 for a live
    /// position, a replay's speed for a replay. The traveller is carried
    /// and the camera eased in road time, so a replay is the drive itself
    /// played faster — its junction zoom settled the same seconds of the
    /// road before each junction — while the map turns no faster than the
    /// eye can follow.
    public var timeScale = 1.0

    var follow: FollowCamera
    var motionConfiguration = CameraMotionConfiguration()
    private var motion: CameraMotion?
    private var prediction: TravellerPrediction
    /// The zoom the junctions ahead ask for, and the hold it keeps.
    private var junctionZoom: JunctionZoom
    /// The route's junctions, read again when the route, the profile or
    /// the tiles at hand change.
    private var junctions: [RouteJunction] = []
    private var junctionsKey: JunctionsKey?
    /// Where a browsing map is turning to (``rotate(by:currentBearing:)``,
    /// ``compassTapped(currentBearing:)``).
    private var browseBearing: Double?
    private var lastFix: LocationFix?
    private var fixArrival: Date?
    private var lastFrame: Date?
    /// The traveller as drawn on the last frame, and how far along the
    /// route they were.
    private var shown: (coordinate: GeoCoordinate, course: Double?, distanceAlong: Double?)?

    public init(profile: TravelProfile = .car) {
        self.profile = profile
        follow = FollowCamera(configuration: FollowCameraConfiguration(profile: profile))
        prediction = TravellerPrediction(configuration: profile.lookAhead)
        junctionZoom = JunctionZoom(profile: profile)
    }

    // MARK: - State

    /// Whether the camera follows the traveller: false once the user has
    /// moved the map, until ``recentre()``.
    public var isFollowing: Bool { follow.isFollowing }

    /// Whether a fix has come: until one does there is no traveller to
    /// follow.
    public var hasFix: Bool { lastFix != nil }

    /// Which way the map faces while following.
    public var orientation: Orientation { follow.configuration.orientation }

    /// The bearing a ``Orientation/locked`` map keeps, degrees clockwise
    /// from north.
    public var lockedBearing: Double { follow.configuration.lockedBearing }

    /// Whether the zoom reads the junctions ahead; off, it is the speed's
    /// alone.
    public var zoomsForJunctions: Bool {
        get { follow.configuration.zoomsForJunctions }
        set {
            follow.configuration.zoomsForJunctions = newValue
            junctionZoom.reset()
        }
    }

    /// Whether the camera eases toward each frame's pose or jumps to it.
    public var isSmooth: Bool {
        get { motionConfiguration.isSmooth }
        set { motionConfiguration.isSmooth = newValue }
    }

    /// The traveller as the last frame drew them: carried along the route
    /// since the last fix and facing the route ahead. Nil until a fix.
    public var traveller: TravellerMarker? {
        guard lastFix != nil, let shown else { return nil }
        return TravellerMarker(coordinate: shown.coordinate, course: shown.course)
    }

    // MARK: - Fixes and frames

    /// A fix arrived at `date`: it moves the traveller's anchor, and the
    /// frames that follow carry them on from it.
    public mutating func receive(_ fix: LocationFix, at date: Date = Date()) {
        lastFix = fix
        fixArrival = date
    }

    /// Forget the traveller: the position's source stopped or changed.
    public mutating func clearFix() {
        lastFix = nil
        fixArrival = nil
        shown = nil
    }

    /// One frame at `date`: a browsing map turned toward the bearing asked
    /// for, the traveller carried on, and, while following, `camera` eased
    /// toward them at the zoom the junctions ahead ask for. Returns whether
    /// the camera or the traveller is still moving, so the caller's
    /// timeline goes on drawing frames; false once both have come to rest.
    @MainActor
    public mutating func advance(to date: Date, camera: inout MapCamera, navigation: NavigationController,
                                 store: MapTileStore) -> Bool {
        let elapsed = min(lastFrame.map { date.timeIntervalSince($0) } ?? 0, NavigationCamera.longestFrame)
        lastFrame = date
        let turning = turnBrowsingMap(&camera, by: elapsed)
        guard let lastFix else { return turning }
        let estimate = estimatedTraveller(at: date, fix: lastFix, navigation: navigation)
        shown = estimate
        let moving = navigation.isActive && navigation.status != .paused
            && navigation.session?.state == .onRoute && (lastFix.speed ?? 0) > 0
        let viewport = MapRenderer.viewport(for: store.viewSize)
        guard follow.isFollowing, viewport.width > 0 else { return moving || turning }
        var motion = self.motion ?? CameraMotion(pose: pose(of: camera, viewport: viewport))
        motion.configuration = motionConfiguration
        // The camera runs in road time, so a fast replay keeps its junction
        // holds; but how fast the map turns is for the eye, on screen. A
        // turn rate and smoothing held in screen time keep a 4× replay's
        // corner a sweep the eye can follow, not a flip.
        motion.configuration.maximumTurnRate = motionConfiguration.maximumTurnRate / timeScale
        motion.configuration.bearingSmoothing = motionConfiguration.bearingSmoothing * timeScale
        let speed = lastFix.speed ?? 0
        let zoom = junctionZoom(along: estimate.distanceAlong ?? navigation.session?.distanceAlong, speed: speed,
                                viewport: viewport, navigation: navigation, store: store)
        let target = follow.pose(for: estimate.coordinate, course: estimate.course, speed: speed,
                                 bearing: motion.pose.bearing, zoom: zoom)
        motion.advance(toward: target, by: elapsed * timeScale)
        self.motion = motion
        camera = follow.camera(for: motion.pose, current: camera, viewport: viewport)
        return moving || !motion.isSettled(toward: target)
    }

    /// The route being navigated, split where the traveller is drawn: the
    /// part behind faded, the part ahead in the accent.
    @MainActor
    public func routeLines(for navigation: NavigationController) -> MapContentGroup {
        guard let session = navigation.session else { return MapContentGroup() }
        let (travelled, ahead) = shown?.distanceAlong.map { session.line.split(atDistance: $0) }
            ?? session.travelledAndAhead
        var elements: [MapElement] = []
        if travelled.count >= 2 { elements.append(.polyline(MapPolyline(coordinates: travelled, style: .travelled))) }
        elements.append(.polyline(MapPolyline(coordinates: ahead)))
        return MapContentGroup(elements)
    }

    // MARK: - The user's hand

    /// The user panned or zoomed: stop following until re-centred.
    public mutating func userMovedCamera() {
        follow.userMovedCamera()
        motion = nil
        browseBearing = nil
    }

    /// Follow again, flying back from wherever the user left the map.
    public mutating func recentre() {
        follow.recentre()
        motion = nil
        junctionZoom.reset()
        browseBearing = nil
        lastFrame = nil
    }

    /// Heading up, then north up, then locked at the map's `currentBearing`,
    /// then heading up again; the map turns to the new orientation.
    @discardableResult
    public mutating func cycleOrientation(currentBearing: Double) -> Orientation {
        follow.cycleOrientation(currentBearing: currentBearing)
    }

    /// Turn the map by `degrees` clockwise: while following it is then
    /// locked there, as Apple Maps keeps a map the user turned; while
    /// browsing it turns about its middle over the next frames.
    public mutating func rotate(by degrees: Double, currentBearing: Double) {
        if follow.isFollowing, lastFix != nil {
            follow.rotate(by: degrees, currentBearing: currentBearing)
        } else {
            browseBearing = GeoMeasure.normalizedBearing((browseBearing ?? currentBearing) + degrees)
        }
    }

    /// A tap on the compass: a turned map goes north up; a following map
    /// north up already goes heading up.
    public mutating func compassTapped(currentBearing: Double) {
        if follow.isFollowing, lastFix != nil {
            follow.compassTapped(currentBearing: currentBearing)
        } else if MapCompassReading(bearing: currentBearing).isRotated {
            browseBearing = 0
        }
    }

    // MARK: - Inside a frame

    /// The longest frame the motion integrates: after a stall, the camera
    /// eases on from where it was rather than leaping.
    private static let longestFrame = 0.1

    /// What the junction zoom's cache of a route's junctions was read for.
    private struct JunctionsKey: Equatable {
        var rerouteCount: Int
        var routeLength: Double
        var profile: TravelProfile.Kind
        var tiles: Int
    }

    /// The traveller at `date`: on the route where navigation matched them,
    /// carried along it at the last fix's speed and facing the route ahead,
    /// as Ferrostar and Mapbox draw the puck; else the fix as it came.
    @MainActor
    private func estimatedTraveller(at date: Date, fix: LocationFix, navigation: NavigationController)
        -> (coordinate: GeoCoordinate, course: Double?, distanceAlong: Double?) {
        let estimate = prediction.estimate(for: navigation.session, rerouting: navigation.status == .rerouting,
                                           paused: navigation.status == .paused, fix: fix,
                                           secondsSinceFix: (fixArrival.map { date.timeIntervalSince($0) } ?? 0)
                                               * timeScale,
                                           headingUpSpeed: profile.headingUpSpeed)
        return (estimate.coordinate, estimate.course, estimate.distanceAlong)
    }

    /// The zoom the junctions ahead ask for, or nil — the speed's — with
    /// the switch off or no route.
    @MainActor
    private mutating func junctionZoom(along distance: Double?, speed: Double, viewport: DotSize,
                                       navigation: NavigationController, store: MapTileStore) -> Double? {
        guard follow.configuration.zoomsForJunctions, let session = navigation.session, let distance else {
            return nil
        }
        let key = JunctionsKey(rerouteCount: navigation.rerouteCount, routeLength: session.line.length,
                               profile: profile.kind, tiles: store.revision)
        if key != junctionsKey {
            if junctionsKey.map({ $0.rerouteCount != key.rerouteCount || $0.profile != key.profile }) ?? true {
                junctionZoom.reset()
            }
            let roles = profile.branchRoles
            junctions = JunctionAnalysis.junctions(of: session, rules: profile.legibility) { point, radius in
                store.lines(near: point, within: radius, roles: roles)
            }
            junctionsKey = key
        }
        let fixedBearing: Double? = switch follow.configuration.orientation {
        case .headingUp: nil
        case .northUp: 0
        case .locked: follow.configuration.lockedBearing
        }
        let frame = JunctionFrame(viewport: viewport, travellerHeightShare: follow.configuration.travellerHeightShare,
                                  fixedBearing: fixedBearing)
        return junctionZoom.zoom(at: distance, speed: speed,
                                 speedZoom: follow.configuration.zoom(forSpeed: speed), junctions: junctions,
                                 line: session.line, frame: frame)
    }

    /// A browsing map turned a frame's way toward the bearing asked for;
    /// whether it is still turning.
    private mutating func turnBrowsingMap(_ camera: inout MapCamera, by seconds: Double) -> Bool {
        guard let target = browseBearing else { return false }
        let goal = FollowPose(focus: camera.center, bearing: target, zoom: camera.zoom)
        var turn = CameraMotion(pose: FollowPose(focus: camera.center, bearing: camera.bearing, zoom: camera.zoom),
                                configuration: motionConfiguration)
        turn.advance(toward: goal, by: seconds)
        let settled = turn.isSettled(toward: goal)
        camera.bearing = settled ? target : turn.pose.bearing
        if settled { browseBearing = nil }
        return !settled
    }

    /// The pose a camera shows: the point where the follow camera keeps the
    /// traveller, so that following picks up from wherever the map is.
    private func pose(of camera: MapCamera, viewport: DotSize) -> FollowPose {
        let travellerPoint = DotPoint(x: viewport.width / 2,
                                      y: viewport.height * follow.configuration.travellerHeightShare)
        return FollowPose(focus: camera.coordinate(at: travellerPoint, in: viewport), bearing: camera.bearing,
                          zoom: camera.zoom)
    }
}
