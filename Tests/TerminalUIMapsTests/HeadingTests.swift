import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// The map faces the way the traveller goes: the route only leans the
// heading toward a turn ahead, a turn not taken never swings it, and a
// reroute leaves the way they are going.

/// A track's fixes, one a second, with the course and speed a replay
/// gives them.
private func fixes(of track: [GPXPoint]) -> [LocationFix] {
    let timeline = TrackTimeline(track)
    return stride(from: 0.0, through: timeline.duration, by: 1).compactMap { second in
        timeline.sample(at: second).map { sample in
            LocationFix(coordinate: sample.coordinate, horizontalAccuracy: 5, course: sample.course,
                        speed: sample.speed, timestamp: SampleDrive.startDate.addingTimeInterval(second),
                        source: .replay)
        }
    }
}

@Suite("The heading follows the traveller's course")
@MainActor
struct HeadingTests {
    private let prediction = TravellerPrediction()
    private let headingUpSpeed = TravelProfile.car.headingUpSpeed

    @Test("Through the demo's missed turn and its reroute, the map never faces more than 30° off the course")
    func missedTurnKeepsTheCourse() async throws {
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: SampleRoutes())
        let limit = prediction.configuration.maximumAnticipation + 0.5
        var worst = 0.0
        for fix in fixes(of: SampleDrive.track(along: route, detourAtStep: SampleDrive.detourStep)) {
            await controller.receive(fix)
            guard let course = fix.course, (fix.speed ?? 0) >= headingUpSpeed else { continue }
            for since in [0.0, 0.5, 1.0] {
                let estimate = prediction.estimate(for: controller.session, rerouting: controller.status == .rerouting,
                                                   paused: false, fix: fix, secondsSinceFix: since,
                                                   headingUpSpeed: headingUpSpeed)
                let off = abs(GeoMeasure.turn(from: course, to: estimate.course))
                worst = max(worst, off)
                #expect(off <= limit, "\(Int(off))° off a course of \(Int(course))° at \(fix.timestamp)")
            }
            if controller.status == .arrived { break }
        }
        #expect(controller.rerouteCount >= 1, "the turn was missed")
        #expect(worst > 1, "the route still leans the heading into the turns taken")
    }

    @Test("The reroute after the missed turn leaves the way the car is going, not back")
    func rerouteGoesOn() async throws {
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: SampleRoutes())
        var checked = false
        for fix in fixes(of: SampleDrive.track(along: route, detourAtStep: SampleDrive.detourStep)) {
            let before = controller.rerouteCount
            await controller.receive(fix)
            guard controller.rerouteCount > before, !checked, let session = controller.session,
                  let course = fix.course else { continue }
            let leaving = try #require(session.line.bearing(from: 0, to: StepShapes.bearingSpan))
            #expect(abs(GeoMeasure.turn(from: course, to: leaving)) < 90,
                    "the new route leaves at \(Int(leaving))° against a course of \(Int(course))°")
            #expect(!session.needsUTurn)
            #expect(session.maneuvers.dropFirst().first?.direction != .uturn)
            checked = true
        }
        #expect(checked)
    }

    @Test("The sample router turns back only when no way on reaches the destination")
    func sampleRouterLeavesAlongTheBearing() throws {
        // On Church Lane just north of High Street, going north, for the
        // Town Hall to the south-west: the way on is round the block.
        let here = SampleTown.coordinate(east: 0, north: 60)
        let hall = try #require(SampleTown.places.first { $0.name == "Town Hall" }).coordinate
        let back = try SampleRoutes.network.route(from: here, to: hall, mode: .driving)
        let on = try SampleRoutes.network.route(from: here, to: hall, mode: .driving, departing: 0)
        let leaving = try #require(RouteLine(on.coordinates).bearing(from: 0, to: StepShapes.bearingSpan))
        #expect(abs(GeoMeasure.turn(from: 0, to: leaving)) < 1)
        #expect(on.distance > back.distance)
    }

    @Test("A course that leaves the route stops the traveller being carried round its corner")
    func missedCornerUsesTheCourse() throws {
        let ground = Ground()
        let line = RouteLine(ground.line([(0, -200), (0, 0), (-200, 0)]))
        // At the corner, still going north.
        let estimate = prediction.estimate(on: line, distanceAlong: 200, speed: 10, secondsSinceFix: 1, course: 0,
                                           fix: ground.point(0, 5))
        #expect(estimate.distanceAlong == nil)
        #expect(estimate.course == 0)
        #expect(GeoMeasure.distance(estimate.coordinate, ground.point(0, 15)) < 0.5)
        // Before it, the traveller is carried no further than the corner
        // while the course says north.
        let before = prediction.estimate(on: line, distanceAlong: 195, speed: 10, secondsSinceFix: 1.5, course: 0)
        #expect(try #require(before.distanceAlong) <= 200 + prediction.configuration.carryStep + 1e-9)
        #expect(abs(GeoMeasure.turn(from: 0, to: before.course)) <= prediction.configuration.maximumAnticipation)
    }

    @Test("A reroute that must go back starts with a U-turn, until the traveller has turned")
    func uTurnWhenNeeded() throws {
        let ground = Ground()
        let northward = ground.route([(0, -300), (0, 300)])
        var session = NavigationSession(route: northward)
        let at = Date(timeIntervalSince1970: 0)
        session.update(LocationFix(coordinate: ground.point(0, 0), horizontalAccuracy: 5, course: 0, speed: 8,
                                   timestamp: at, source: .replay))
        session.reroute(ground.route([(0, 0), (0, -300)]), course: 0)
        #expect(session.needsUTurn)
        let banner = renderView(NavigationBanner(session: session, status: .navigating), width: 60, height: 5)
        #expect(banner.contains("Make a U-turn"), "\(banner)")
        session.update(LocationFix(coordinate: ground.point(0, -10), horizontalAccuracy: 5, course: 180, speed: 8,
                                   timestamp: at.addingTimeInterval(4), source: .replay))
        #expect(!session.needsUTurn)
    }

    @Test("OSRM is asked to leave along the bearing: bearings on the first coordinate only")
    func osrmBearings() throws {
        let routes = OSRMRoutes(baseURL: OSRMRoutes.demoURL, userAgent: testUserAgent)
        let url = try #require(routes.routeURL(through: [GeoCoordinate(latitude: 0, longitude: 0),
                                                         GeoCoordinate(latitude: 0.01, longitude: 0),
                                                         GeoCoordinate(latitude: 0.02, longitude: 0)],
                                               mode: .driving, departing: 93.6)).absoluteString
        #expect(url.contains("bearings=94,45;;"), "\(url)")
        let none = try #require(routes.routeURL(through: [GeoCoordinate(latitude: 0, longitude: 0),
                                                          GeoCoordinate(latitude: 0.01, longitude: 0)],
                                                mode: .driving)).absoluteString
        #expect(!none.contains("bearings"))
    }

    @Test("OSRM's intersections are read into the steps")
    func osrmIntersections() async throws {
        let body = """
        {"code":"Ok","routes":[{"distance":100,"duration":10,
          "geometry":{"type":"LineString","coordinates":[[0,0],[0.001,0],[0.001,0.001]]},
          "legs":[{"steps":[
            {"distance":50,"duration":5,"name":"A","maneuver":{"type":"depart","location":[0,0]},
             "intersections":[{"location":[0,0],"bearings":[90],"entry":[true],"out":0}]},
            {"distance":50,"duration":5,"name":"B","maneuver":{"type":"turn","modifier":"left","location":[0.001,0]},
             "intersections":[{"location":[0.001,0],"bearings":[0,25,90,270],"entry":[true,true,true,false],
                               "in":3,"out":0}]},
            {"distance":0,"duration":0,"name":"","maneuver":{"type":"arrive","location":[0.001,0.001]}}]}]}]}
        """
        let route = try await OSRMRoutes(transport: StubTransport { _ in .json(body) }).route(
            through: [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0.001, longitude: 0.001)],
            mode: .driving)
        let intersection = try #require(route.steps[1].intersections?.first)
        #expect(intersection.bearings == [0, 25, 90, 270])
        #expect(intersection.inIndex == 3 && intersection.outIndex == 0)
        #expect(intersection.entry == [true, true, true, false])
        #expect(route.steps[2].intersections == nil)
    }
}

@Suite("Five Ways, the sample town's confusing corner")
struct FiveWaysTests {
    @Test("The drive and the ride both go through the five-way, round Kiln Circus and the staggered turns")
    func bothPassTheJunction() async throws {
        for mode in [TravelMode.driving, .cycling] {
            let route = try await SampleFiveWays.route(for: mode)
            let names = route.steps.compactMap(\.name)
            #expect(names.contains("Abbey Lane"), "\(mode): \(names)")
            let roundabout = try #require(route.steps.first { $0.maneuver?.kind == .roundabout })
            #expect(roundabout.maneuver?.exit == 2)
            #expect(roundabout.instruction == "Enter the roundabout and leave at exit 2 onto Eastwood Drive")
            #expect(route.steps.contains { $0.maneuver?.kind == .exitRoundabout })
            let charcoal = try #require(route.steps.firstIndex { $0.name == "Charcoal Lane" })
            #expect(route.steps[charcoal].distance < 25, "the stagger's two turns are 20 m apart")
            #expect(route.steps[charcoal + 1].name == "Copse Road")
        }
    }

    @Test("The bicycle takes the Silver Greenway, which no car may")
    func cyclewayForBicyclesOnly() async throws {
        let ride = try await SampleFiveWays.route(for: .cycling)
        let drive = try await SampleFiveWays.route(for: .driving)
        #expect(ride.steps.contains { $0.name == "Silver Greenway" })
        let church = try #require(SampleFiveWays.stops(for: .cycling).first).coordinate
        let end = try #require(SampleFiveWays.stops(for: .cycling).last).coordinate
        let byCar = try await SampleRoutes().route(from: church, to: end, mode: .driving)
        #expect(!byCar.steps.contains { $0.name == "Silver Greenway" })
        #expect(!drive.steps.contains { $0.name == "Silver Greenway" || $0.name == "Towpath" })
    }

    @Test("At car speed the five-way and the stagger close the camera in; at a bicycle's, less")
    func profilesAtTheJunction() async throws {
        for (mode, profile) in [(TravelMode.driving, TravelProfile.car), (.cycling, .bicycle)] {
            let route = try await SampleFiveWays.route(for: mode)
            let session = NavigationSession(route: route)
            let junctions = JunctionAnalysis.junctions(of: session, rules: profile.legibility) { _, _ in
                SampleTown.streets.filter { $0.allows(mode) }.map { street in
                    street.path.map { SampleTown.coordinate(east: $0.0, north: $0.1) }
                }
            }
            let fiveWay = try #require(junctions.first { $0.maneuver.direction == .left && $0.branches.count == 5 })
            #expect(abs((JunctionLegibility(fiveWay, next: nil, rules: profile.legibility).minimumSeparation ?? 0) - 25) < 1.5)
            let speed = SampleFiveWays.pace(for: mode).cruise
            let speedZoom = FollowCameraConfiguration(profile: profile).zoom(forSpeed: speed)
            let groups = JunctionZoom(profile: profile).groups(
                junctions, on: session.line, after: 0, speed: speed, speedZoom: speedZoom,
                frame: JunctionFrame(viewport: DotSize(columns: 120, rows: 38), travellerHeightShare: 2.0 / 3))
            let group = try #require(groups.first { $0.junctions.contains(junctions.firstIndex(of: fiveWay)!) })
            #expect(group.isTight)
            #expect(group.zoom - speedZoom <= (mode == .driving ? 0.6 : 0.3), "\(mode): \(group.zoom - speedZoom)")
        }
    }

    @Test("The shipped tracks are the ones the code makes, typed with their mode")
    func shippedTracks() async throws {
        for mode in [TravelMode.driving, .cycling] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(SampleFiveWays.trackPath(for: mode))
            let made = try await SampleFiveWays.document(for: mode).xml
            if ProcessInfo.processInfo.environment["TERMINALUI_UPDATE_GOLDENS"] == "1" {
                try Data(made.utf8).write(to: url)
            }
            let shipped = try String(contentsOf: url, encoding: .utf8)
            #expect(shipped == made)
            let document = try GPXDocument(xml: shipped)
            #expect(RoutePlan(gpx: try #require(document.routes.first)).mode == mode)
        }
    }

    @Test("The tracks slow for each turn and cruise between")
    func tracksSlowForTurns() async throws {
        let route = try await SampleFiveWays.route(for: .driving)
        let pace = SampleFiveWays.drivingPace
        let speeds = fixes(of: SampleFiveWays.track(along: route, pace: pace)).compactMap(\.speed)
        #expect(speeds.max()! <= pace.cruise + 0.5)
        #expect(speeds.min()! < pace.turning + 1)
    }
}
