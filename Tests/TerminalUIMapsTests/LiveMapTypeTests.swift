import Foundation
import Testing
import TerminalUIIO
@testable import TerminalUIMaps

/// The map types' sources against the real servers, only with
/// `TERMINALUI_MAPS_LIVE=1`.
@Suite(.enabled(if: liveNetworkEnabled, "set TERMINALUI_MAPS_LIVE=1 to reach the real servers"),
       .serialized)
struct LiveMapTypeTests {
    private static let sintra = GeoCoordinate(latitude: 38.7975, longitude: -9.3906)
    private static let boulder = GeoCoordinate(latitude: 40.015, longitude: -105.2705)
    private static let userAgent = "TerminalUIMaps-tests/0.1 (TerminalUI maps experiment)"

    /// A tile's picture, prepared as a map would draw it.
    private func picture(_ source: any MapTileSource, at coordinate: GeoCoordinate, zoom: Int) async throws -> ImageBuffer {
        let id = TileID(containing: coordinate, zoom: zoom)
        let tile = try #require(try await source.tile(id))
        _ = RenderTile(id: id, tile: tile)
        guard case .raster(let image) = tile.content else {
            Issue.record("expected a picture")
            throw CancellationError()
        }
        return image
    }

    @Test func sentinel2Of2016ServesSintraAsAJPEGThePureDecoderReads() async throws {
        let image = try await picture(RasterTileSource.sentinel2Cloudless2016(userAgent: Self.userAgent),
                                      at: Self.sintra, zoom: 14)
        #expect(image.width == 256 && image.height == 256)
        #expect(Set(stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] }).count > 32)
    }

    @Test func usgsServesBoulderAndNotSintra() async throws {
        let source = RasterTileSource.usgsImagery(userAgent: Self.userAgent)
        let image = try await picture(source, at: Self.boulder, zoom: 16)
        #expect(image.width == 256)
        #expect(try await source.tile(TileID(containing: Self.sintra, zoom: 12)) == nil)
    }

    @Test func theOpenChainFillsSintraAtUSGSsDeepestZoom() async throws {
        let image = try await picture(ImageryOption.open(userAgent: Self.userAgent).source, at: Self.sintra, zoom: 16)
        #expect(image.width == 64, "a z14 Sentinel-2 tile's sixteenth")
    }

    @Test func awsTerrainGivesSintrasHills() async throws {
        let id = TileID(containing: Self.sintra, zoom: 13)
        let tile = try #require(try await RasterTileSource.awsTerrain(userAgent: Self.userAgent).tile(id))
        guard case .elevation(let elevation) = tile.content else {
            Issue.record("expected heights")
            return
        }
        // The Serra de Sintra rises to some 500 m from the coast.
        #expect((elevation.metres.max() ?? 0) > 300)
        #expect((elevation.metres.min() ?? 1_000) < 200)
        let content = ElevationContent(elevation, id: id)
        #expect(content.contours.segmentCount > 100)
    }

    @Test func panoramaxHasPhotosByParisHotelDeVille() async throws {
        let imagery = PanoramaxImagery(userAgent: Self.userAgent)
        let image = try #require(try await imagery.images(near: GeoCoordinate(latitude: 48.857, longitude: 2.3514),
                                                          within: 150).first)
        #expect(image.attribution.contains("Panoramax"))
        let photo = try await imagery.photo(of: image)
        #expect(photo.width > 0)
        _ = try await imagery.neighbours(of: image, along: 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[MapillaryImagery.tokenVariable] != nil))
    func mapillaryHasPhotosInParis() async throws {
        let imagery = try MapillaryImagery(userAgent: Self.userAgent)
        let image = try #require(try await imagery.images(near: GeoCoordinate(latitude: 48.857, longitude: 2.3514),
                                                          within: 150).first)
        #expect(try await imagery.photo(of: image).width > 0)
    }

    #if canImport(MapKit)
    @Test func lookAroundHasSintra() async throws {
        let imagery = LookAroundImagery()
        let image = try #require(try await imagery.images(near: GeoCoordinate(latitude: 38.7975, longitude: -9.3885),
                                                          within: 60).first)
        #expect(try await imagery.photo(of: image).width == Int(LookAroundImagery.snapshotSize.width))
    }

    @Test func mapKitSnapshotsImageryAndHybrid() async throws {
        for style in MapKitImagerySource.Style.allCases {
            let image = try await picture(MapKitImagerySource(style: style, pixelsPerTile: 64), at: Self.sintra,
                                          zoom: 14)
            #expect(image.width == 64)
            #expect(Set(stride(from: 0, to: image.rgba.count, by: 4).map { image.rgba[$0] }).count > 8)
        }
    }
    #endif
}
