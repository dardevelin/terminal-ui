import Foundation
import Synchronization
import Testing
@testable import TerminalUIMaps

/// Every navigation test rides the sample town: the demo's route from the
/// station by the town hall to the library, replayed from a track made
/// along it, on a clock whose sleeps return at once.
@MainActor
private func replay(_ track: [GPXPoint]) -> AsyncThrowingStream<LocationFix, any Error> {
    GPXReplayProvider(timeline: TrackTimeline(track), clock: ManualClock(), startDate: SampleDrive.startDate).fixes()
}

private func fix(_ coordinate: GeoCoordinate, accuracy: Double? = 5, course: Double? = nil, speed: Double? = nil,
                 at seconds: Double = 0) -> LocationFix {
    LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, course: course, speed: speed,
                timestamp: SampleDrive.startDate.addingTimeInterval(seconds), source: .replay)
}

/// A router that fails, and counts how often it was asked.
private final class FailingRouter: RouteProvider {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    func route(from origin: GeoCoordinate, to destination: GeoCoordinate, mode: TravelMode) async throws -> Route {
        calls.withLock { $0 += 1 }
        throw MapServiceError.noRoute("offline")
    }
}

@Suite("Navigation")
@MainActor
struct NavigationTests {
    @Test func aDriveAdvancesThroughEveryStepAndArrives() async throws {
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: SampleRoutes())
        try await controller.follow(replay(SampleDrive.track(along: route)))

        #expect(controller.status == .arrived)
        #expect(controller.history.first == .started(step: 0))
        #expect(controller.history.last == .arrived)
        #expect(controller.history.contains(.reachedStop(1)))
        #expect(!controller.history.contains { if case .leftRoute = $0 { true } else { false } })
        var visited = [0]
        for case .advanced(let from, let to) in controller.history {
            #expect(from == visited.last, "steps advance from where they were")
            visited.append(to)
        }
        // A stop's arrival and the departure from it begin at one point,
        // so the arrival is passed over as the stop is reached; every
        // other step is the current one in turn.
        let starts = try #require(controller.session).stepStarts
        let distinct = route.steps.indices.filter { $0 == starts.count - 1 || starts[$0] < starts[$0 + 1] }
        #expect(visited == distinct, "\(visited)")
        #expect(controller.rerouteCount == 0)
        #expect(controller.recordedTrack.count > 100, "a fix a second is recorded")
    }

    @Test func distanceAndTimeRemainingCountDown() async throws {
        let route = try await SampleDrive.route()
        var session = NavigationSession(route: route)
        let track = SampleDrive.track(along: route)
        var previous = (distance: Double.infinity, duration: Double.infinity)
        for (second, point) in track.enumerated() {
            session.update(fix(point.coordinate, at: Double(second)))
            #expect(session.distanceRemaining <= previous.distance + 1e-6)
            #expect(session.durationRemaining <= previous.duration + 1e-6)
            previous = (session.distanceRemaining, session.durationRemaining)
            if second == 0 {
                // The route's metres are the sample's Mercator ones and
                // the line's the haversine's: a tenth of a percent apart.
                #expect(abs(session.durationRemaining - route.duration) < 1)
                #expect(abs(session.distanceRemaining - route.distance) < route.distance * 0.005)
            }
            if second == 60 {
                // A minute in at the sample's own pace: a minute less to go,
                // and the arrival where the drive will end.
                #expect(abs(session.durationRemaining - (route.duration - 60)) < 2)
                let arrival = try #require(session.estimatedArrival)
                #expect(abs(arrival.timeIntervalSince(SampleDrive.startDate) - route.duration) < 2)
            }
        }
        #expect(session.state == .arrived && session.distanceRemaining < 20)
    }

    @Test func aTravellerAlreadyPastSeveralStepsJumpsToTheirs() async throws {
        let route = try await SampleDrive.route()
        var session = NavigationSession(route: route)
        session.update(fix(route.coordinates[0]))
        // Onto Oak Street, past the town hall: the stop is reached on the way.
        let target = 4
        let along = session.stepStarts[target] + 30
        let events = session.update(fix(session.line.coordinate(atDistance: along), at: 30))
        #expect(events == [.reachedStop(1), .advanced(from: 0, to: target)])
        #expect(session.stepIndex == target)
        #expect(abs(session.distanceToManeuver - (session.stepStarts[target + 1] - along)) < 0.5)
    }

    @Test func aStepAdvancesWithinTenMetresOfItsManoeuvre() async throws {
        let route = try await SampleDrive.route()
        var session = NavigationSession(route: route)
        let turn = session.stepStarts[1]
        session.update(fix(session.line.coordinate(atDistance: turn - 15)))
        #expect(session.stepIndex == 0)
        session.update(fix(session.line.coordinate(atDistance: turn - 8), at: 1))
        #expect(session.stepIndex == 1)
    }

    @Test func aGoodFixFarFromTheRouteIsOffRouteAndAPoorOneIsIgnored() async throws {
        let route = try await SampleDrive.route()
        var session = NavigationSession(route: route)
        session.update(fix(route.coordinates[0]))
        let start = route.coordinates[0]
        // The station is on Station Road, running east-west; 80 m south of
        // it is the railway, no street.
        let south = GeoMeasure.destination(from: start, bearing: 180, distance: 80)
        #expect(session.update(fix(south, accuracy: 25, at: 1)).isEmpty, "a 25 m fix cannot say")
        #expect(session.state == .onRoute)
        #expect(session.update(fix(south, accuracy: nil, at: 2)).isEmpty, "nor one of unknown accuracy")
        let events = session.update(fix(south, accuracy: 8, at: 3))
        #expect(events.count == 1)
        guard case .leftRoute(let deviation) = events.first else {
            Issue.record("expected leftRoute, got \(events)")
            return
        }
        #expect(abs(deviation - 80) < 2)
        #expect(session.update(fix(south, accuracy: 8, at: 4)).isEmpty, "left once, not every fix")
        #expect(session.update(fix(start, at: 5)) == [.rejoinedRoute])
    }

    @Test func within50MetresIsStillOnRoute() async throws {
        let route = try await SampleDrive.route()
        var session = NavigationSession(route: route)
        session.update(fix(route.coordinates[0]))
        let near = GeoMeasure.destination(from: route.coordinates[0], bearing: 180, distance: 45)
        #expect(session.update(fix(near, accuracy: 3, at: 1)).isEmpty)
        #expect(session.state == .onRoute)
    }

    @Test func aWrongTurnIsReroutedAndTheDriveStillArrives() async throws {
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: SampleRoutes())
        let track = SampleDrive.track(along: route, detourAtStep: SampleDrive.detourStep)
        try await controller.follow(replay(track))

        let history = controller.history
        let left = history.firstIndex { if case .leftRoute = $0 { true } else { false } }
        let rerouted = history.firstIndex(of: .rerouted)
        #expect(left != nil && rerouted != nil && left! < rerouted!, "\(history)")
        #expect(controller.rerouteCount >= 1)
        #expect(controller.status == .arrived)
        #expect(history.last == .arrived)
        #expect(history.contains(.reachedStop(1)), "the stop is reached on the new route")
        let session = try #require(controller.session)
        #expect(GeoMeasure.distance(try #require(session.route.coordinates.last), SampleDrive.plan.coordinates[2]) < 400)
        #expect(session.stopsReached == 1)
    }

    @Test func aRerouteAfterTheFirstStopGoesOnlyToTheRest() async throws {
        // Off the route beyond the town hall: the new route goes to the
        // library alone, not back by the town hall.
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: SampleRoutes())
        let session = try #require(controller.session)
        let afterStop = try #require(route.steps.firstIndex { $0.instruction == "Arrive at stop 1" })
        let past = session.line.coordinate(atDistance: session.stepStarts[afterStop] + 60)
        await controller.receive(fix(route.coordinates[0]))
        await controller.receive(fix(past, at: 100))
        #expect(controller.session?.stopsReached == 1)
        let offRoad = GeoMeasure.destination(from: past, bearing: 135, distance: 90)
        await controller.receive(fix(offRoad, at: 110))
        #expect(controller.rerouteCount == 1)
        let rerouted = try #require(controller.session).route
        #expect(!rerouted.steps.contains { $0.instruction.hasPrefix("Arrive at stop") })
    }

    @Test func aFailedRerouteIsSaidAndTriedAgainLater() async throws {
        let route = try await SampleDrive.route()
        let router = FailingRouter()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: router)
        await controller.receive(fix(route.coordinates[0]))
        let south = GeoMeasure.destination(from: route.coordinates[0], bearing: 180, distance: 80)
        await controller.receive(fix(south, at: 1))
        #expect(router.count == 1 && controller.rerouteError != nil && controller.status == .navigating)
        await controller.receive(fix(south, at: 5))
        #expect(router.count == 1, "not again within the retry interval")
        await controller.receive(fix(south, at: 1 + NavigationController.rerouteRetryInterval))
        #expect(router.count == 2)
    }

    @Test func pausedFixesAreIgnoredAndResumingFindsTheStep() async throws {
        let route = try await SampleDrive.route()
        let controller = NavigationController()
        controller.start(route: route, plan: SampleDrive.plan, router: nil)
        await controller.receive(fix(route.coordinates[0]))
        controller.pause()
        let session = try #require(controller.session)
        let later = session.line.coordinate(atDistance: session.stepStarts[4] + 20)
        await controller.receive(fix(later, at: 60))
        #expect(controller.session?.stepIndex == 0 && controller.status == .paused)
        controller.resume()
        await controller.receive(fix(later, at: 61))
        #expect(controller.session?.stepIndex == 4)
        controller.stop()
        #expect(controller.session == nil && controller.status == .idle)
    }

    @Test func aRouteWithoutManoeuvresOrDurationsHasThemInferred() async throws {
        // What MapKit gives: sentences, step starts, and the route's time.
        let sample = try await SampleDrive.route()
        var bare = sample
        bare.steps = sample.steps.map { step in
            RouteStep(instruction: step.instruction, distance: step.distance, duration: 0, coordinate: step.coordinate)
        }
        let inferred = NavigationSession(route: bare)
        let given = NavigationSession(route: sample)
        for index in sample.steps.indices.dropFirst().dropLast()
        where sample.steps[index].maneuver?.kind == .turn && sample.steps[index].distance > 0 {
            #expect(inferred.maneuvers[index].direction == given.maneuvers[index].direction, "step \(index)")
        }
        #expect(inferred.maneuvers.first?.kind == .depart && inferred.maneuvers.last?.kind == .arrive)
        #expect(abs(inferred.durationRemaining - sample.duration) < 1)
    }

    @Test func stepStartsLieOnTheLineInOrder() async throws {
        let session = NavigationSession(route: try await SampleDrive.route())
        #expect(session.stepStarts == session.stepStarts.sorted())
        #expect(session.stepStarts.first == 0)
        #expect(abs((session.stepStarts.last ?? 0) - session.line.length) < 1e-6)
    }
}

@Suite("Following camera")
struct FollowCameraTests {
    private let viewport = DotSize(columns: 100, rows: 30)
    private let here = GeoCoordinate(latitude: 0.02, longitude: 0.02)

    @Test func theTravellerSitsAThirdFromTheBottom() throws {
        let follow = FollowCamera()
        let camera = follow.camera(for: here, course: 45, speed: 10, current: MapCamera(center: here, zoom: 15),
                                   viewport: viewport)
        let point = try #require(camera.screenPoint(for: here, in: viewport))
        #expect(abs(point.x - viewport.width / 2) < 0.01)
        #expect(abs(point.y - viewport.height * 2 / 3) < 0.01)
        #expect(camera.bearing == 45)
        let ahead = try #require(camera.screenPoint(for: GeoMeasure.destination(from: here, bearing: 45, distance: 50),
                                                    in: viewport))
        #expect(abs(ahead.x - point.x) < 0.01 && ahead.y < point.y, "the course points up the screen")
    }

    @Test func atAWalkTheBearingHolds() {
        let follow = FollowCamera()
        let current = MapCamera(center: here, zoom: 15, bearing: 30)
        #expect(follow.camera(for: here, course: 200, speed: 1.2, current: current, viewport: viewport).bearing == 30)
        #expect(follow.camera(for: here, course: nil, speed: 12, current: current, viewport: viewport).bearing == 30)
    }

    @Test func fasterIsFurtherOut() {
        let configuration = FollowCameraConfiguration()
        #expect(configuration.zoom(forSpeed: 0) == 17.5)
        #expect(configuration.zoom(forSpeed: 1) == 17.25)
        #expect(configuration.zoom(forSpeed: 100) == 14.5)
        #expect(configuration.zoom(forSpeed: 8) > configuration.zoom(forSpeed: 25))
    }

    @Test func aPanStopsFollowingUntilRecentred() {
        var follow = FollowCamera()
        follow.userMovedCamera()
        #expect(!follow.isFollowing)
        follow.recentre()
        #expect(follow.isFollowing)
    }
}

@Suite("Navigation wording")
struct NavigationWordingTests {
    @Test(arguments: [(3.0, "now"), (14, "10 m"), (96, "100 m"), (130, "150 m"), (980, "1000 m"), (1_234, "1.2 km")])
    func distancesAreRoundedAsTheyAreSpoken(metres: Double, words: String) {
        #expect(NavigationWording.distance(metres) == words)
    }

    @Test func arrowsPointTheWayOfTheTurn() {
        #expect(NavigationWording.arrow(for: Maneuver(kind: .turn, direction: .left)) == "↰")
        #expect(NavigationWording.arrow(for: Maneuver(kind: .turn, direction: .right)) == "↱")
        #expect(NavigationWording.arrow(for: Maneuver(kind: .arrive)) == "◎")
        #expect(NavigationWording.arrow(for: Maneuver(kind: .roundabout, exit: 2)) == "↻")
    }

    @Test func timesReadAsClockAndMinutes() {
        #expect(NavigationWording.clockTime(SampleDrive.startDate, timeZone: TimeZone(identifier: "UTC")!) == "09:00")
        #expect(NavigationWording.duration(20) == "<1 min")
        #expect(NavigationWording.duration(3_900) == "1 h 5 min")
    }

    @Test func aTravellerArrowPointsTheirWayOnTheScreen() {
        #expect(TravellerMarker.glyph(course: 0, bearing: 0) == "↑")
        #expect(TravellerMarker.glyph(course: 90, bearing: 0) == "→")
        #expect(TravellerMarker.glyph(course: 90, bearing: 90) == "↑", "heading up, the course is up")
        #expect(TravellerMarker.glyph(course: nil, bearing: 0) == "●")
    }
}
