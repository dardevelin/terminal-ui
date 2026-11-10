import Foundation
import Synchronization
import Testing
import TerminalUIIO
@testable import TerminalUIMaps

@Suite("Terrain: Terrarium, hillshade and contours")
struct TerrainTests {
    /// A grid whose heights are `height(x, y)` at each sample.
    private func grid(width: Int = 16, height: Int = 16, _ value: (Int, Int) -> Double) -> ElevationTile {
        var metres: [Float] = []
        for y in 0..<height {
            for x in 0..<width { metres.append(Float(value(x, y))) }
        }
        return ElevationTile(checkedWidth: width, height: height, metres: metres)
    }

    @Test func terrariumDecodesAsMapzenDocumentsIt() {
        // red·256 + green + blue/256 − 32768.
        #expect(Terrarium.metres(red: 128, green: 0, blue: 0) == 0)
        #expect(Terrarium.metres(red: 128, green: 100, blue: 128) == 100.5)
        #expect(Terrarium.metres(red: 127, green: 255, blue: 0) == -1)
        #expect(Terrarium.metres(red: 0, green: 0, blue: 0) == -32_768)
    }

    @Test func terrariumRoundTripsToAQuarterOfACentimetre() throws {
        for height in [-430.25, 0, 1.5, 8_848.86, 123.456] {
            let pixel = Terrarium.pixel(metres: height)
            #expect(abs(Terrarium.metres(red: pixel.red, green: pixel.green, blue: pixel.blue) - height) <= 1.0 / 512)
        }
        let tile = grid(width: 3, height: 2) { x, y in Double(x * 100 + y) - 50 }
        let image = try #require(Terrarium.image(of: tile))
        #expect(Terrarium.elevation(of: image) == tile)
    }

    @Test func aTerrariumPNGDecodesThroughThePureSwiftDecoder() async throws {
        let source = SampleTerrainSource()
        let id = TileID(containing: SampleTown.origin, zoom: 15)
        let bytes = try #require(try await source.tileData(id))
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        guard case .elevation(let tile) = try #require(try await source.tile(id)).content else {
            Issue.record("a terrain source gives heights")
            return
        }
        #expect(tile.width == SampleTerrainSource.samplesPerTile)
        let expected = SampleGround.tile(id, samples: SampleTerrainSource.samplesPerTile)
        let worst = zip(tile.metres, expected.metres).map { abs($0 - $1) }.max() ?? .infinity
        #expect(worst <= 1.0 / 256)
    }

    @Test func flatGroundShadesAsTheSunsAltitudeSays() {
        let lighting = Hillshade.standard
        let shades = lighting.shades(of: grid { _, _ in 120 }, cellSize: 10)
        #expect(shades.allSatisfy { abs(Double($0) - lighting.flat) < 1e-6 })
        #expect(abs(lighting.flat - cos(45 * Double.pi / 180)) < 1e-9)
    }

    @Test func aSlopeFacingTheSunIsLighterAndOneFacingAwayDarker() {
        let lighting = Hillshade.standard
        // Rising to the south-east faces the north-west sun; rising to the
        // north-west faces away.
        let facing = lighting.shades(of: grid { x, y in Double(x + y) * 5 }, cellSize: 10)
        let away = lighting.shades(of: grid { x, y in Double(-x - y) * 5 }, cellSize: 10)
        #expect(Double(facing[8 * 16 + 8]) > lighting.flat)
        #expect(Double(away[8 * 16 + 8]) < lighting.flat)
    }

    @Test func aTilesBorderShadesAsItsMiddleDoes() {
        // A uniform slope: the edge, with a neighbour missing, must not
        // shade differently, or every tile seam would show.
        let shades = Hillshade.standard.shades(of: grid { x, _ in Double(x) * 3 }, cellSize: 10)
        let middle = shades[8 * 16 + 8]
        for index in [0, 15, 8 * 16, 8 * 16 + 15, 15 * 16 + 7] {
            #expect(abs(shades[index] - middle) < 1e-5)
        }
    }

    @Test func aConeTracesOneClosedRingPerLevel() {
        // A cone 0 m at its rim to 97 m at its top: at a 10 m interval,
        // nine rings, the 50 m one an index contour.
        let cone = grid(width: 41, height: 41) { x, y in
            let distance = (Double((x - 20) * (x - 20) + (y - 20) * (y - 20))).squareRoot()
            return max(0, 97 - distance * 5)
        }
        let contours = ContourTracer.trace(cone, interval: 10)
        #expect(!contours.minor.isEmpty)
        #expect(!contours.index.isEmpty)
        // Every segment end lies on the level it traces: within the cone's
        // radius for that level, in unit-square coordinates.
        for start in stride(from: 0, to: contours.index.count, by: ContourTracer.valuesPerSegment) {
            let x = Double(contours.index[start]) * 41 - 0.5 - 20, y = Double(contours.index[start + 1]) * 41 - 0.5 - 20
            let radius = (x * x + y * y).squareRoot()
            #expect(abs(radius - 9.4) < 0.6, "the 50 m ring lies 9.4 samples out: \(radius)")
        }
        // A closed ring: every segment end meets another's.
        var ends: [String: Int] = [:]
        let all = contours.minor + contours.index
        for start in stride(from: 0, to: all.count, by: 2) {
            ends["\(all[start].bitPattern),\(all[start + 1].bitPattern)", default: 0] += 1
        }
        #expect(ends.values.allSatisfy { $0 == 2 }, "\(ends.filter { $0.value != 2 })")
    }

    @Test func aFlatTileHasNoContours() {
        #expect(ContourTracer.trace(grid { _, _ in 37 }, interval: 10).segmentCount == 0)
    }

    @Test func theIntervalWidensAsTheMapZoomsOut() {
        let intervals = (0...18).map { ContourTracer.interval(forZoom: $0) }
        #expect(zip(intervals, intervals.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(ContourTracer.interval(forZoom: 14) == 10)
        #expect(ContourTracer.interval(forZoom: 3) == 1_000)
    }

    @Test func aGridReducesToTheMeansOfItsBlocks() {
        let reduced = grid(width: 4, height: 4) { x, y in Double(x + 4 * y) }.reduced(by: 2)
        #expect(reduced.width == 2)
        #expect(reduced.metres == [2.5, 4.5, 10.5, 12.5])
    }
}

@Suite("Raster tile sources")
struct RasterSourceTests {
    @Test func eoxPutsTheRowBeforeTheColumn() {
        let source = RasterTileSource.sentinel2Cloudless2016(transport: StubTransport { _ in .json("") })
        #expect(source.url(for: TileID(zoom: 14, x: 7812, y: 6233))?.absoluteString
                == "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/14/6233/7812.jpg")
        let terrain = RasterTileSource.awsTerrain(transport: StubTransport { _ in .json("") })
        #expect(terrain.url(for: TileID(zoom: 14, x: 7812, y: 6233))?.absoluteString
                == "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/14/7812/6233.png")
    }

    @Test func aMissingTileIsNoneAndAServerErrorThrows() async throws {
        let missing = RasterTileSource.usgsImagery(transport: StubTransport { _ in
            HTTPResponse(statusCode: 404, body: Array("<html>".utf8))
        })
        #expect(try await missing.tile(TileID(zoom: 10, x: 163, y: 395)) == nil)
        let failing = RasterTileSource.usgsImagery(transport: StubTransport { _ in
            HTTPResponse(statusCode: 500, body: [])
        })
        await #expect(throws: MapServiceError.self) { try await failing.tile(TileID(zoom: 10, x: 163, y: 395)) }
    }

    @Test func usgsIsNotAskedOutsideTheUnitedStates() async throws {
        let transport = StubTransport { _ in HTTPResponse(statusCode: 500, body: []) }
        let source = RasterTileSource.usgsImagery(transport: transport)
        #expect(try await source.tile(TileID(containing: GeoCoordinate(latitude: 38.5, longitude: -8.2), zoom: 12))
                == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func aPNGTileDecodesToItsPicture() async throws {
        // Awaited before #require: the Linux toolchain's Swift Testing does
        // not carry an `await` into the macro's expansion.
        let data = try await SampleImagerySource().tileData(TileID(containing: SampleTown.origin, zoom: 16))
        let png = try #require(data)
        let source = RasterTileSource(name: "test", attribution: "test", template: "https://tiles.test/{z}/{x}/{y}.png",
                                      encoding: .picture, zoomRange: 0...18,
                                      transport: StubTransport { _ in HTTPResponse(statusCode: 200, body: png) },
                                      userAgent: testUserAgent)
        guard case .raster(let image) = try #require(try await source.tile(TileID(zoom: 16, x: 1, y: 1))).content else {
            Issue.record("a picture source gives pictures")
            return
        }
        #expect(image.width == SampleImagerySource.pixelsPerTile)
    }

    @Test func aChainTakesTheFirstSourceThatHasTheTile() async throws {
        let regional = FixedSource(name: "regional", zoomRange: 0...16, colour: 10,
                                   bounds: GeoRect(south: 0, west: 0, north: 10, east: 10))
        let world = FixedSource(name: "world", zoomRange: 0...14, colour: 200)
        let chain = TileSourceChain([regional, world])
        let info = try await chain.info()
        #expect(info.zoomRange == 0...16)
        #expect(info.attribution == "regional · world")
        let inside = TileID(containing: GeoCoordinate(latitude: 5, longitude: 5), zoom: 12)
        #expect(try await chain.tile(inside).flatMap(FixedSource.colour) == 10)
        let outside = TileID(containing: GeoCoordinate(latitude: -40, longitude: 100), zoom: 12)
        #expect(try await chain.tile(outside).flatMap(FixedSource.colour) == 200)
    }

    @Test func aShallowerSourceFillsInDeeperZoomsCutFromItsDeepest() async throws {
        let world = FixedSource(name: "world", zoomRange: 0...14, colour: 0, gradient: true)
        let chain = TileSourceChain([world])
        let parent = TileID(zoom: 14, x: 100, y: 200)
        // Two zooms in, the south-east child of the south-east child: the
        // parent's bottom-right sixteenth.
        let child = TileID(zoom: 16, x: 403, y: 803)
        guard case .raster(let image) = try #require(try await chain.tile(child)).content else {
            Issue.record("a picture")
            return
        }
        #expect(image.width == 4)
        #expect(image.pixel(at: 0, 0).r == 12)
        #expect(image.pixel(at: 0, 0).g == 12)
        #expect(world.requests == [parent])
        _ = try await chain.tile(TileID(zoom: 16, x: 402, y: 803))
        #expect(world.requests == [parent], "the ancestor is kept, not fetched again")
    }

    @Test func cuttingATerrainTileSamplesItsShare() {
        let tile = ElevationTile(checkedWidth: 4, height: 4, metres: (0..<16).map { Float($0) })
        let cut = MapTile.elevation(tile).descendant(TileID(zoom: 1, x: 1, y: 0), of: TileID(zoom: 0, x: 0, y: 0))
        guard case .elevation(let quarter) = cut?.content else {
            Issue.record("heights")
            return
        }
        #expect(quarter.width == 2)
        #expect(quarter.metres == [2, 3, 6, 7])
    }
}

/// A picture source of one colour, or of a gradient where a pixel's red
/// and green are its column and row, that counts what it is asked for.
final class FixedSource: MapTileSource {
    private let sourceInfo: TileSourceInfo
    private let colour: UInt8
    private let gradient: Bool
    private let asked = Mutex<[TileID]>([])
    static let side = 16

    init(name: String, zoomRange: ClosedRange<Int>, colour: UInt8, gradient: Bool = false,
         bounds: GeoRect = TileSourceInfo.world) {
        sourceInfo = TileSourceInfo(name: name, attribution: name, zoomRange: zoomRange, bounds: bounds)
        self.colour = colour
        self.gradient = gradient
    }

    var requests: [TileID] { asked.withLock { $0 } }

    func info() async throws -> TileSourceInfo { sourceInfo }

    func tile(_ id: TileID) async throws -> MapTile? {
        asked.withLock { $0.append(id) }
        var rgba: [UInt8] = []
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                rgba += gradient ? [UInt8(x), UInt8(y), 0, 255] : [colour, colour, colour, 255]
            }
        }
        return .raster(try ImageBuffer(rgba: rgba, width: Self.side, height: Self.side))
    }

    static func colour(of tile: MapTile) -> UInt8? {
        guard case .raster(let image) = tile.content else { return nil }
        return image.pixel(at: 0, 0).r
    }
}
