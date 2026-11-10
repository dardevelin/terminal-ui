import Testing
@testable import TerminalUIMaps

@Suite("Sample directions")
struct SampleRoutesTests {
    @Test func aRouteFollowsTheStreetsAndNamesEachOneTaken() async throws {
        // From the station, on Station Road, to the café on High Street.
        let station = SampleTown.places.first { $0.name == "Millbrook Station" }!
        let cafe = SampleTown.places.first { $0.name == "The Copper Kettle" }!
        let route = try await SampleRoutes().route(from: station.coordinate, to: cafe.coordinate, mode: .driving)
        #expect(route.coordinates.count >= 3)
        #expect(route.distance > 800, "the café is some 900 m north of the station by road")
        #expect(route.distance < 2_000)
        #expect(abs(route.duration - route.distance / (30_000.0 / 3_600)) < 1e-6)
        #expect(route.steps.first?.instruction.hasPrefix("Head") == true)
        #expect(route.steps.last?.instruction == "Arrive at the destination")
        #expect(route.steps.contains { $0.instruction.contains("onto") })
        #expect(abs(route.steps.reduce(0) { $0 + $1.distance } - route.distance) < 1e-6)
    }

    @Test func aTurnIsLeftOrRightByWhichWayItBends() {
        #expect(StreetNetwork.turn(from: (0, 1), to: (-1, 0)) == "Turn left")
        #expect(StreetNetwork.turn(from: (0, 1), to: (1, 0)) == "Turn right")
        #expect(StreetNetwork.turn(from: (0, 1), to: (0.1, 1)) == "Continue")
        #expect(StreetNetwork.compass((1, 0)) == "east")
        #expect(StreetNetwork.compass((0, -1)) == "south")
    }

    @Test func aPlaceFarFromTheTownHasNoRoute() async {
        await #expect(throws: MapServiceError.self) {
            try await SampleRoutes().route(from: SampleTown.origin,
                                           to: GeoCoordinate(latitude: 10, longitude: 10), mode: .walking)
        }
    }
}
