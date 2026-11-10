import Foundation
import Testing
@testable import TerminalUIMaps

@Suite("Ground measures")
struct GeoMeasureTests {
    @Test func aDegreeOfLatitudeIsAbout111Kilometres() {
        let metres = GeoMeasure.distance(GeoCoordinate(latitude: 0, longitude: 0),
                                         GeoCoordinate(latitude: 1, longitude: 0))
        #expect(abs(metres - 111_195) < 10)
    }

    @Test func bearingsRunClockwiseFromNorth() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        #expect(abs(GeoMeasure.bearing(origin, GeoCoordinate(latitude: 1, longitude: 0))) < 1e-9)
        #expect(abs(GeoMeasure.bearing(origin, GeoCoordinate(latitude: 0, longitude: 1)) - 90) < 1e-9)
        #expect(abs(GeoMeasure.bearing(origin, GeoCoordinate(latitude: -1, longitude: 0)) - 180) < 1e-9)
        #expect(abs(GeoMeasure.bearing(origin, GeoCoordinate(latitude: 0, longitude: -1)) - 270) < 1e-9)
    }

    @Test func aDestinationIsTheDistanceAwayAtTheBearing() {
        let origin = GeoCoordinate(latitude: 38.5, longitude: -8.2)
        let there = GeoMeasure.destination(from: origin, bearing: 60, distance: 250)
        #expect(abs(GeoMeasure.distance(origin, there) - 250) < 0.01)
        #expect(abs(GeoMeasure.bearing(origin, there) - 60) < 0.01)
    }

    @Test func aTurnIsSignedRightPositive() {
        #expect(GeoMeasure.turn(from: 350, to: 10) == 20)
        #expect(GeoMeasure.turn(from: 10, to: 350) == -20)
        #expect(GeoMeasure.turn(from: 0, to: 180) == -180)
    }

    @Test func theLocalPlaneRoundTrips() {
        let plane = LocalPlane(reference: GeoCoordinate(latitude: 51.5, longitude: -0.12))
        let point = GeoCoordinate(latitude: 51.503, longitude: -0.115)
        let metres = plane.point(point)
        let back = plane.coordinate(east: metres.east, north: metres.north)
        #expect(abs(back.latitude - point.latitude) < 1e-9 && abs(back.longitude - point.longitude) < 1e-9)
        #expect(abs((metres.east * metres.east + metres.north * metres.north).squareRoot()
                    - GeoMeasure.distance(plane.reference, point)) < 0.5)
    }
}

@Suite("Manoeuvres")
struct ManeuverTests {
    @Test(arguments: [(0.0, Maneuver.Direction.straight), (19, .straight), (30, .slightRight), (-30, .slightLeft),
                      (90, .right), (-90, .left), (150, .sharpRight), (-150, .sharpLeft), (178, .uturn)])
    func aTurnAngleFallsInOSRMsBands(angle: Double, direction: Maneuver.Direction) {
        #expect(Maneuver.direction(turningBy: angle) == direction)
    }

    @Test func aBendIsATurnAndStraightOnANewName() {
        let left = Maneuver.inferred(bearingBefore: 0, bearingAfter: 270)
        #expect(left.kind == .turn && left.direction == .left)
        #expect(left.instruction(onto: "Mill Road") == "Turn left onto Mill Road")
        let on = Maneuver.inferred(bearingBefore: 90, bearingAfter: 95)
        #expect(on.kind == .newName && on.instruction(onto: "High Street") == "Continue onto High Street")
        #expect(Maneuver(kind: .turn, direction: .slightRight).instruction(onto: nil) == "Bear right")
    }

    @Test func stepPolylinesGiveMapKitStepsTheirManoeuvres() {
        // North 100 m, then east 100 m, then south: a right turn, then
        // another; the last step is the arrival.
        let plane = LocalPlane(reference: GeoCoordinate(latitude: 0.01, longitude: 0.01))
        let corner = plane.coordinate(east: 0, north: 100), corner2 = plane.coordinate(east: 100, north: 100)
        let end = plane.coordinate(east: 100, north: 0)
        let maneuvers = StepShapes.maneuvers(of: [[plane.reference, corner], [corner, corner2], [corner2, end], [end]])
        #expect(maneuvers.map(\.kind) == [.depart, .turn, .turn, .arrive])
        #expect(maneuvers[1].direction == .right && maneuvers[2].direction == .right)
        #expect(abs(GeoMeasure.turn(from: 0, to: maneuvers[0].bearingAfter ?? 180)) < 0.01, "leaving north")
    }
}

@Suite("Planned routes")
struct RoutePlanTests {
    private func coordinate(_ value: Double) -> GeoCoordinate { GeoCoordinate(latitude: value, longitude: value) }

    @Test func stopsAreAddedMovedAndRemoved() {
        var plan = RoutePlan()
        let first = plan.append("A", at: coordinate(1))
        let second = plan.append("B", at: coordinate(2))
        let third = plan.insert("C", at: coordinate(3), before: 1)
        #expect(plan.waypoints.map(\.name) == ["A", "C", "B"])
        plan.move(second, by: -5)
        #expect(plan.waypoints.map(\.name) == ["B", "A", "C"], "a move is held to the plan's ends")
        plan.move(first, by: 1)
        #expect(plan.waypoints.map(\.name) == ["B", "C", "A"])
        plan.remove(third)
        #expect(plan.waypoints.map(\.id) == [second, first])
        #expect(plan.isRoutable)
        plan.reverse()
        #expect(plan.waypoints.map(\.name) == ["A", "B"])
    }

    @Test func whatIsLeftAfterAStopStartsWhereTheTravellerIs() {
        var plan = RoutePlan()
        for index in 1...3 { plan.append("S\(index)", at: coordinate(Double(index))) }
        let here = coordinate(9)
        #expect(plan.remaining(from: here, after: 0) == [here, coordinate(2), coordinate(3)])
        #expect(plan.remaining(from: here, after: 1) == [here, coordinate(3)])
    }

    @Test func legsJoinIntoOneRouteWithEachStopNamed() async throws {
        let plan = SampleDrive.plan
        let route = try await SampleRoutes().route(through: plan.coordinates, mode: .driving)
        let legs = [try await SampleRoutes().route(from: plan.coordinates[0], to: plan.coordinates[1], mode: .driving),
                    try await SampleRoutes().route(from: plan.coordinates[1], to: plan.coordinates[2], mode: .driving)]
        #expect(abs(route.distance - legs[0].distance - legs[1].distance) < 1e-6)
        #expect(route.steps.count == legs[0].steps.count + legs[1].steps.count)
        #expect(route.steps[legs[0].steps.count - 1].instruction == "Arrive at stop 1")
        #expect(route.steps.last?.instruction == "Arrive at the destination")
        #expect(route.coordinates.first == legs[0].coordinates.first)
        #expect(route.coordinates.last == legs[1].coordinates.last)
    }

    @Test func theSampleNamesItsStreetsAndTurns() async throws {
        let route = try await SampleDrive.route()
        #expect(route.steps.first?.maneuver?.kind == .depart)
        #expect(route.steps.last?.maneuver?.kind == .arrive)
        #expect(route.steps.allSatisfy { $0.maneuver != nil })
        #expect(route.steps.filter { $0.maneuver?.kind != .arrive }.allSatisfy { $0.name != nil })
    }
}

@Suite struct OSRMMultiStopTests {
    private let response = """
    {"code":"Ok","routes":[{"distance":900,"duration":100,
      "geometry":{"type":"LineString","coordinates":[[1,1],[1.001,1],[1.002,1]]},
      "legs":[
        {"steps":[{"distance":450,"duration":50,"name":"A","maneuver":{"type":"depart","bearing_after":90,"location":[1,1]}},
                  {"distance":0,"duration":0,"name":"A","maneuver":{"type":"arrive","bearing_before":90,"location":[1.001,1]}}]},
        {"steps":[{"distance":450,"duration":50,"name":"B","maneuver":{"type":"depart","location":[1.001,1]}},
                  {"distance":0,"duration":0,"name":"","maneuver":{"type":"turn","modifier":"sharp left",
                   "bearing_before":90,"bearing_after":200,"location":[1.0015,1]}},
                  {"distance":0,"duration":0,"name":"","maneuver":{"type":"exotic","location":[1.002,1]}}]}]}]}
    """

    @Test func everyStopGoesInOneRequestAndTheManoeuvresAreKept() async throws {
        let body = response
        let transport = StubTransport { _ in .json(body) }
        let route = try await OSRMRoutes(transport: transport).route(
            through: [GeoCoordinate(latitude: 1, longitude: 1), GeoCoordinate(latitude: 1, longitude: 1.001),
                      GeoCoordinate(latitude: 1, longitude: 1.002)], mode: .driving)
        let url = try #require(transport.requests.first?.url.absoluteString)
        #expect(url.contains("/route/v1/driving/1.0,1.0;1.001,1.0;1.002,1.0?"))
        #expect(transport.requests.count == 1)
        #expect(route.steps[1].instruction == "Arrive at stop 1")
        #expect(route.steps[0].maneuver == Maneuver(kind: .depart, bearingAfter: 90))
        #expect(route.steps[3].maneuver?.direction == .sharpLeft && route.steps[3].maneuver?.bearingAfter == 200)
        #expect(route.steps[4].maneuver?.kind == .turn, "a type OSRM may add later reads as a turn")
        #expect(route.steps[2].name == "B" && route.steps[3].name == nil)
    }
}
