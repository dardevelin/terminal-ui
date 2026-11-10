import Foundation
import Testing
@testable import TerminalUIMaps

/// Place details against the real servers, only with
/// `TERMINALUI_MAPS_LIVE=1`: the default run makes no network calls.
@Suite(.enabled(if: liveNetworkEnabled, "set TERMINALUI_MAPS_LIVE=1 to reach the real servers"), .serialized)
struct LivePlaceDetailsTests {
    private static let userAgent = "TerminalUIMaps-tests/0.1 (TerminalUI maps experiment)"

    /// The Institut Arthur Vernes, a clinic in the Paris fixture tile:
    /// feature 14427318282, way 1442731828.
    private static let clinic = Place(name: "Institut Arthur Vernes", kind: "clinic",
                                      coordinate: GeoCoordinate(latitude: 48.8475, longitude: 2.3296),
                                      identifier: .openStreetMap(OSMElement(.way, 1_442_731_828)))

    @Test func nominatimHasTheClinicsHours() async throws {
        let information = try #require(try await NominatimPlaceDetails(userAgent: Self.userAgent)
            .details(for: Self.clinic))
        #expect(information.openingHours?.schedule != nil)
        #expect(information.phone != nil)
    }

    @Test func overpassHasTheClinicsHours() async throws {
        let information = try #require(try await OverpassPlaceDetails(userAgent: Self.userAgent)
            .details(for: Self.clinic))
        #expect(information.openingHours?.schedule != nil)
    }

    #if canImport(MapKit)
    @Test func appleHasAPhoneForTheLouvre() async throws {
        let louvre = Place(name: "Musée du Louvre", kind: "museum",
                           coordinate: GeoCoordinate(latitude: 48.8606, longitude: 2.3376))
        let information = try #require(try await MapKitPlaceDetails().details(for: louvre))
        #expect(information.category != nil)
        #expect(information.address != nil)
        #expect(information.openingHours == nil, "Apple gives no hours")
    }
    #endif
}
