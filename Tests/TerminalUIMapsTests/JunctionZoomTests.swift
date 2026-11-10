import Foundation
import Testing
@testable import TerminalUIMaps

// Junctions built by hand, in metres east and north of a point near Null
// Island: their roads as lines, as vector tiles would give them, and a
// route through them. The camera's zoom is the speed's at a simple
// junction and closes in at one that would not read, settled before it and
// held still through it.

/// Geometry in metres on a local plane.
struct Ground {
    let plane = LocalPlane(reference: GeoCoordinate(latitude: 0.01, longitude: 0.01))

    func point(_ east: Double, _ north: Double) -> GeoCoordinate { plane.coordinate(east: east, north: north) }
    func line(_ points: [(Double, Double)]) -> [GeoCoordinate] { points.map { point($0.0, $0.1) } }
    /// A road leaving `from` along `bearing` for `length` metres.
    func arm(from: (Double, Double), bearing: Double, length: Double = 200) -> [GeoCoordinate] {
        let radians = bearing * .pi / 180
        return line([from, (from.0 + length * sin(radians), from.1 + length * cos(radians))])
    }

    /// A route along `points` with a step at each of them but the last.
    func route(_ points: [(Double, Double)]) -> Route {
        let coordinates = line(points)
        var steps = coordinates.dropLast().enumerated().map { index, coordinate in
            RouteStep(instruction: "step \(index)", distance: 0, duration: 0, coordinate: coordinate)
        }
        steps.append(RouteStep(instruction: "arrive", distance: 0, duration: 0, coordinate: coordinates.last!))
        return Route(coordinates: coordinates, distance: GeoMeasure.length(of: coordinates),
                     duration: GeoMeasure.length(of: coordinates) / 8, steps: steps)
    }
}

@Suite("Junctions read on a text map")
struct JunctionLegibilityTests {
    private let ground = Ground()
    private let car = TravelProfile.car
    /// 30 km/h, where the car's table gives zoom 16.06.
    private let speed = 30_000.0 / 3_600
    private let viewport = DotSize(columns: 120, rows: 38)

    private func junctions(route: Route, roads: [[GeoCoordinate]], profile: TravelProfile = .car) -> [RouteJunction] {
        JunctionAnalysis.junctions(of: NavigationSession(route: route), rules: profile.legibility) { _, _ in roads }
    }

    private func plan(_ junctions: [RouteJunction], route: Route, viewport: DotSize? = nil,
                      profile: TravelProfile = .car) -> [JunctionGroup] {
        let speedZoom = FollowCameraConfiguration(profile: profile).zoom(forSpeed: speed)
        return JunctionZoom(profile: profile).groups(junctions, on: RouteLine(route.coordinates), after: 0,
                                                     speed: speed, speedZoom: speedZoom,
                                                     frame: JunctionFrame(viewport: viewport ?? self.viewport,
                                                                          travellerHeightShare: 2.0 / 3))
    }

    private var speedZoom: Double { FollowCameraConfiguration(profile: car).zoom(forSpeed: speed) }

    @Test("A simple T reads at the speed's zoom: nothing changes")
    func simpleT() throws {
        let route = ground.route([(-300, 0), (0, 0), (0, 300)])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.arm(from: (0, 0), bearing: 0)]
        let found = junctions(route: route, roads: roads)
        let junction = try #require(found.first)
        #expect(junction.branchSource == .tiles)
        #expect(junction.branches.map { Int($0.rounded()) } == [0, 90, 270])
        let legibility = JunctionLegibility(junction, next: nil, rules: car.legibility)
        #expect(legibility.branchCount == 3)
        #expect(abs((legibility.minimumSeparation ?? 0) - 90) < 1)
        let group = try #require(plan(found, route: route).first)
        #expect(!group.isTight)
        #expect(group.zoom == speedZoom)
    }

    @Test("A five-way junction whose roads part by 25° closes the camera in, by only what it needs")
    func fiveWayZoomsIn() throws {
        let route = ground.route([(-300, 0), (0, 0), (200 * sin(25 * .pi / 180), 200 * cos(25 * .pi / 180))])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.arm(from: (0, 0), bearing: 0),
                     ground.arm(from: (0, 0), bearing: 25), ground.arm(from: (0, 0), bearing: 180)]
        let junction = try #require(junctions(route: route, roads: roads).first)
        #expect(junction.branches.count == 5)
        let legibility = JunctionLegibility(junction, next: nil, rules: car.legibility)
        #expect(abs((legibility.minimumSeparation ?? 0) - 25) < 1)
        let group = try #require(plan([junction], route: route).first)
        #expect(group.isTight)
        #expect(group.zoom > speedZoom + 0.3, "\(group.zoom) against the speed's \(speedZoom)")
        #expect(group.zoom <= speedZoom + JunctionZoom.Configuration().maximumZoomIn)
        // At the zoom held, the two roads 25° apart lie four dots apart
        // 15 m from the node — and no closer in than that needs.
        let metresPerDot = WebMercator.metresPerWorldUnit(atLatitude: 0.01) / MapCamera.dotsPerWorld(atZoom: group.zoom)
        let apart = 2 * car.legibility.mouthLength * sin(12.5 * .pi / 180) / metresPerDot
        #expect(apart >= car.legibility.separationDots - 0.01)
        #expect(apart < car.legibility.separationDots + 0.5)
    }

    @Test("Of a five-way's roads, a 25° pair the route does not take still counts: a driver counts them")
    func complexJunctionCountsEveryPair() throws {
        let route = ground.route([(-300, 0), (0, 0), (0, -300)])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.arm(from: (0, 0), bearing: 0),
                     ground.arm(from: (0, 0), bearing: 25), ground.arm(from: (0, 0), bearing: 180)]
        let junction = try #require(junctions(route: route, roads: roads).first)
        #expect(abs((JunctionLegibility(junction, next: nil).minimumSeparation ?? 0) - 25) < 1)
    }

    @Test("Two turns 20 m apart are held at one zoom that sets them three cells apart, both on screen")
    func twoTurnsTwentyMetresApart() throws {
        let route = ground.route([(-300, 0), (0, 0), (0, 20), (300, 20)])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.line([(0, -100), (0, 120)]),
                     ground.line([(-300, 20), (300, 20)])]
        let found = junctions(route: route, roads: roads)
        #expect(found.count == 2)
        let groups = plan(found, route: route)
        let group = try #require(groups.first)
        #expect(groups.count == 1, "both turns are one hold")
        #expect(group.junctions == 0...1)
        #expect(group.isTight)
        let first = JunctionLegibility(found[0], next: found[1], rules: car.legibility)
        #expect(abs((first.distanceToNext ?? 0) - 20) < 0.5)
        let needed = try #require(first.requiredZoom(atLatitude: 0.01))
        #expect(group.zoom >= needed - 1e-9)
        #expect(try #require(group.fittingZoom) >= group.zoom)

        // Seen from where the hold begins, heading up: both turns on
        // screen, three cell heights apart.
        let settle = JunctionZoom.Configuration().settleDistance(speed)
        let line = RouteLine(route.coordinates)
        let traveller = line.coordinate(atDistance: found[0].distanceAlong - settle)
        let follow = FollowCamera()
        let camera = follow.camera(for: FollowPose(focus: traveller, bearing: 90, zoom: group.zoom),
                                   current: MapCamera(center: traveller, zoom: group.zoom), viewport: viewport)
        let points = found.map { camera.screenPoint(for: $0.coordinate, in: viewport) }
        for point in points {
            #expect((0...viewport.width).contains(point.x) && (0...viewport.height).contains(point.y))
        }
        let apart = ((points[0].x - points[1].x) * (points[0].x - points[1].x)
            + (points[0].y - points[1].y) * (points[0].y - points[1].y)).squareRoot()
        #expect(apart >= car.legibility.spacingCells * Double(BrailleCell.dotRows) - 0.01)
    }

    @Test("A tight junction with the next turn close behind zooms only as far in as keeps that turn on screen")
    func fittingTheFollowingTurn() throws {
        // A 25° fork, then 150 m on a turn off to the side: on a small
        // screen the fork's own zoom would lose the turn.
        let exit: (Double, Double) = (150 * sin(25 * Double.pi / 180), 150 * cos(25 * Double.pi / 180))
        let route = ground.route([(-300, 0), (0, 0), exit, (exit.0 + 200, exit.1)])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.arm(from: (0, 0), bearing: 0),
                     ground.line([(0, 0), exit]), ground.line([(exit.0 - 200, exit.1), (exit.0 + 300, exit.1)])]
        let found = junctions(route: route, roads: roads)
        let small = DotSize(columns: 40, rows: 12)
        let group = try #require(plan(found, route: route, viewport: small).first)
        #expect(group.isTight)
        let fitting = try #require(group.fittingZoom)
        #expect(fitting < group.legibleZoom, "the fork alone would zoom closer")
        #expect(abs(group.zoom - max(fitting, speedZoom - JunctionZoom.Configuration().maximumZoomOut)) < 1e-9)
    }

    @Test("A roundabout reads by its diameter, from the route's arc round it")
    func roundaboutDiameter() throws {
        let ring = (0...12).map { index -> (Double, Double) in
            let bearing = Double(index) * 30 * .pi / 180
            return (12 * sin(bearing), 12 * cos(bearing) + 112)
        }
        // In from the south at the ring's foot, round clockwise to its top
        // and out north: a roundabout step, then the exit.
        let coordinates = ground.line([(0, -200)] + Array(ring[6...12]) + [(0, 324)])
        let route = Route(coordinates: coordinates, distance: GeoMeasure.length(of: coordinates), duration: 60, steps: [
            RouteStep(instruction: "depart", distance: 0, duration: 0, coordinate: coordinates[0]),
            RouteStep(instruction: "roundabout", distance: 0, duration: 0, coordinate: coordinates[1],
                      maneuver: Maneuver(kind: .roundabout, exit: 2)),
            RouteStep(instruction: "exit", distance: 0, duration: 0, coordinate: coordinates[7],
                      maneuver: Maneuver(kind: .exitRoundabout)),
            RouteStep(instruction: "arrive", distance: 0, duration: 0, coordinate: coordinates.last!),
        ])
        let found = junctions(route: route, roads: [])
        let entry = try #require(found.first)
        let diameter = try #require(entry.roundaboutDiameter)
        #expect(diameter > 20 && diameter < 30, "\(diameter) m across a ring of 24")
        let legibility = JunctionLegibility(entry, next: found.dropFirst().first)
        #expect(legibility.minimumSeparation == nil, "the ring is no pair of roads")
        #expect(try #require(legibility.largestMetresPerDot) <= diameter / 12 + 1e-9)
    }

    @Test("The router's intersections are read before the tiles")
    func routerIntersectionsFirst() throws {
        var route = ground.route([(-300, 0), (0, 0), (0, 300)])
        route.steps[1].intersections = [RouteIntersection(coordinate: ground.point(0, 0), bearings: [0, 20, 90, 270],
                                                          inIndex: 3, outIndex: 0)]
        let junction = try #require(junctions(route: route, roads: []).first)
        #expect(junction.branchSource == .router)
        #expect(abs((JunctionLegibility(junction, next: nil).minimumSeparation ?? 0) - 20) < 1e-9)
    }

    @Test("With no roads known, the route's own way in and out are the junction")
    func routeOnly() throws {
        let route = ground.route([(-300, 0), (0, 0), (0, 300)])
        let junction = try #require(junctions(route: route, roads: []).first)
        #expect(junction.branchSource == .route)
        #expect(junction.branches.count == 2)
    }
}

@Suite("The junction zoom's timing")
struct JunctionZoomTimingTests {
    private let ground = Ground()
    private let speed = 30_000.0 / 3_600

    /// The five-way of the legibility tests, at 300 m along a route.
    private func fiveWay() -> (route: Route, junctions: [RouteJunction]) {
        let route = ground.route([(-300, 0), (0, 0), (200 * sin(25 * .pi / 180), 200 * cos(25 * .pi / 180))])
        let roads = [ground.line([(-300, 0), (300, 0)]), ground.arm(from: (0, 0), bearing: 0),
                     ground.arm(from: (0, 0), bearing: 25), ground.arm(from: (0, 0), bearing: 180)]
        return (route, JunctionAnalysis.junctions(of: NavigationSession(route: route)) { _, _ in roads })
    }

    private let frame = JunctionFrame(viewport: DotSize(columns: 120, rows: 38), travellerHeightShare: 2.0 / 3)

    @Test("The zoom is settled seconds before the junction, held still through it, and let go after")
    func settledHeldReleased() {
        let (route, junctions) = fiveWay()
        let line = RouteLine(route.coordinates)
        let speedZoom = FollowCameraConfiguration().zoom(forSpeed: speed)
        let configuration = JunctionZoom.Configuration()
        var zoom = JunctionZoom()
        var zooms: [(along: Double, zoom: Double)] = []
        for along in stride(from: 0.0, through: line.length, by: 1) {
            zooms.append((along, zoom.zoom(at: along, speed: speed, speedZoom: speedZoom, junctions: junctions,
                                           line: line, frame: frame)))
        }
        let node = junctions[0].distanceAlong
        let settled = node - configuration.settleDistance(speed)
        let held = zooms.filter { $0.along >= settled && $0.along <= node + configuration.releaseDistance(speed) }
        let value = held.first!.zoom
        #expect(value > speedZoom + 0.3)
        #expect(held.allSatisfy { $0.zoom == value }, "the zoom moved within the hold")
        #expect(configuration.settleDistance(speed) / speed >= configuration.settleTime + configuration.easingTime - 1e-9,
                "the target final nine seconds out, the camera still by six")
        for (earlier, later) in zip(zooms, zooms.dropFirst()) {
            #expect(abs(later.zoom - earlier.zoom) < 0.05, "a step of \(later.zoom - earlier.zoom) at \(later.along) m")
        }
        let after = node + configuration.releaseDistance(speed) + configuration.transitionDistance(speed) + 1
        #expect(zooms.filter { $0.along > after }.allSatisfy { abs($0.zoom - speedZoom) < 1e-9 })
        #expect(zooms.first!.zoom == speedZoom)
    }

    @Test("Braking through the junction does not change the scale: the hold keeps its zoom")
    func brakingHolds() {
        let (route, junctions) = fiveWay()
        let line = RouteLine(route.coordinates)
        let configuration = FollowCameraConfiguration()
        var zoom = JunctionZoom()
        let node = junctions[0].distanceAlong
        var held: Double?
        for along in stride(from: node - 60, through: node + 10, by: 1) {
            // Slowing from 30 km/h to 10 at the node, where the speed
            // table alone would close in by most of a level.
            let speed = max(2.8, 8.3 - (along - (node - 60)) * 0.09)
            let value = zoom.zoom(at: along, speed: speed, speedZoom: configuration.zoom(forSpeed: speed),
                                  junctions: junctions, line: line, frame: frame)
            if zoom.hold != nil {
                if let held { #expect(value == held, "at \(along) m") } else { held = value }
            }
        }
        #expect(held != nil)
    }

    @Test("A new route behind the hold starts afresh")
    func newRouteResets() {
        let (route, junctions) = fiveWay()
        let line = RouteLine(route.coordinates)
        let speedZoom = FollowCameraConfiguration().zoom(forSpeed: speed)
        var zoom = JunctionZoom()
        _ = zoom.zoom(at: junctions[0].distanceAlong - 1, speed: speed, speedZoom: speedZoom, junctions: junctions,
                      line: line, frame: frame)
        #expect(zoom.hold != nil)
        _ = zoom.zoom(at: 0, speed: speed, speedZoom: speedZoom, junctions: junctions, line: line, frame: frame)
        #expect(zoom.hold == nil)
    }
}

@Suite("Travel profiles")
struct TravelProfileTests {
    @Test("A route's mode picks its profile, and each profile routes in its own mode")
    func modes() {
        for mode in TravelMode.allCases {
            #expect(TravelProfile(mode: mode).travelMode == mode)
        }
        #expect(TravelProfile(mode: .cycling) == .bicycle)
    }

    @Test("Car, bicycle, on foot, and round again")
    func cycling() {
        #expect(TravelProfile.car.next == .bicycle)
        #expect(TravelProfile.bicycle.next == .foot)
        #expect(TravelProfile.foot.next == .car)
    }

    @Test("Slower travellers stand closer, turn heading up sooner, look less far, and are off route sooner")
    func profilesDiffer() {
        let car = FollowCameraConfiguration(profile: .car), bicycle = FollowCameraConfiguration(profile: .bicycle)
        let foot = FollowCameraConfiguration(profile: .foot)
        // Each at its own cruising speed: 50 km/h, 15 km/h, 5 km/h.
        #expect(car.zoom(forSpeed: 13.9) < bicycle.zoom(forSpeed: 4.2))
        #expect(bicycle.zoom(forSpeed: 4.2) < foot.zoom(forSpeed: 1.4))
        #expect(TravelProfile.car.headingUpSpeed > TravelProfile.bicycle.headingUpSpeed)
        #expect(TravelProfile.bicycle.headingUpSpeed > TravelProfile.foot.headingUpSpeed)
        #expect(TravelProfile.car.lookAhead.maximumLookAhead > TravelProfile.bicycle.lookAhead.maximumLookAhead)
        #expect(TravelProfile.car.legibility.mouthLength > TravelProfile.bicycle.legibility.mouthLength)
        #expect(TravelProfile.car.junctionTiming.settleTime > TravelProfile.foot.junctionTiming.settleTime)
        #expect(TravelProfile.car.navigationConfiguration.maximumDeviation == 50)
        #expect(TravelProfile.bicycle.navigationConfiguration.maximumDeviation < 50)
        #expect(!TravelProfile.car.branchRoles.contains(.path))
        #expect(TravelProfile.bicycle.branchRoles.contains(.path))
    }

    @Test("Switching profile keeps the camera's orientation and switches")
    func applyKeepsSwitches() {
        var configuration = FollowCameraConfiguration()
        configuration.orientation = .northUp
        configuration.zoomsForJunctions = false
        configuration.apply(.bicycle)
        #expect(configuration.orientation == .northUp)
        #expect(!configuration.zoomsForJunctions)
        #expect(configuration.zoomBySpeed == TravelProfile.bicycle.zoomBySpeed)
    }
}
