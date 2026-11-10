import Foundation
import Testing
@testable import TerminalUIMaps
#if canImport(MapKit)
import TerminalUIIO
#endif

/// Against the real servers, only with `TERMINALUI_MAPS_LIVE=1`: the
/// default run makes no network calls.
@Suite(.enabled(if: liveNetworkEnabled, "set TERMINALUI_MAPS_LIVE=1 to reach the real servers"),
       .serialized)
struct LiveTests {
    private static let constancia = GeoCoordinate(latitude: 39.4758, longitude: -8.3357)
    private static let userAgent = "TerminalUIMaps-tests/0.1 (TerminalUI maps experiment)"

    @Test func openFreeMapServesConstancia() async throws {
        let source = OpenFreeMapTileSource(userAgent: Self.userAgent)
        let info = try await source.info()
        #expect(info.zoomRange.upperBound == 14)
        #expect(info.attribution.contains("OpenStreetMap"))
        let tile = try await source.tile(TileID(containing: Self.constancia, zoom: 14))
        guard case .vector(let vector) = tile?.content else {
            Issue.record("expected a vector tile")
            return
        }
        #expect(vector[layer: "place"]?.features.contains { $0.properties["name"] == "Constância" } == true)
    }

    @Test func nominatimFindsConstancia() async throws {
        let search = NominatimSearch(userAgent: Self.userAgent)
        let places = try await search.search("Constância, Portugal", near: nil)
        let first = try #require(places.first)
        #expect(abs(first.coordinate.latitude - Self.constancia.latitude) < 0.05)
        #expect(abs(first.coordinate.longitude - Self.constancia.longitude) < 0.05)
    }

    @Test func osrmRoutesAcrossTown() async throws {
        let route = try await OSRMRoutes(baseURL: OSRMRoutes.demoURL, userAgent: Self.userAgent).route(
            from: Self.constancia, to: GeoCoordinate(latitude: 39.4637, longitude: -8.3195), mode: .driving)
        #expect(route.distance > 0)
        #expect(route.coordinates.count >= 2)
        #expect(!route.steps.isEmpty)
    }

    #if canImport(MapKit)
    @Test func mapKitSearchFindsConstancia() async throws {
        let places = try await MapKitSearch().search("Constância", near: GeoRect(covering: [Self.constancia]))
        #expect(!places.isEmpty)
    }

    @Test func mapKitRoutesAcrossTown() async throws {
        let route = try await MapKitRoutes().route(
            from: Self.constancia, to: GeoCoordinate(latitude: 39.4637, longitude: -8.3195), mode: .driving)
        #expect(route.distance > 0)
        #expect(route.coordinates.count >= 2)
    }

    @Test func mapKitSnapshotsATile() async throws {
        let tile = try await MapKitSnapshotSource(pixelsPerTile: 64).tile(TileID(containing: Self.constancia,
                                                                                 zoom: 13))
        guard case .raster(let image) = tile?.content else {
            Issue.record("expected a raster tile")
            return
        }
        #expect(image.width == 64 && image.height == 64)
        #expect(Set(stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] }).count > 1)
    }
    #endif
}
