import Foundation
import Testing
@testable import TerminalUIMaps

@Suite struct ProtobufTests {
    @Test(arguments: [UInt64(0), 1, 127, 128, 300, 16_384, UInt64(UInt32.max), UInt64.max])
    func varintsRoundTrip(value: UInt64) throws {
        var writer = ProtobufWriter()
        writer.writeVarint(value)
        var reader = ProtobufReader(writer.bytes)
        #expect(try reader.readVarint() == value)
        #expect(reader.isAtEnd)
    }

    @Test func varint300IsTheGuidesExample() {
        var writer = ProtobufWriter()
        writer.writeVarint(300)
        #expect(writer.bytes == [0xAC, 0x02])
    }

    @Test func zigZagMapsSmallMagnitudesToSmallNumbers() {
        #expect([0, -1, 1, -2, 2].map { ZigZag.encode(Int32($0)) } == [0, 1, 2, 3, 4])
        #expect(ZigZag.decode(UInt32(4_294_967_295)) == Int32.min)
        #expect(ZigZag.decode(UInt64(3)) == -2)
        for value in [Int64.min, -5, 0, 7, Int64.max] {
            #expect(ZigZag.decode(ZigZag.encode(value)) == value)
        }
    }

    @Test func fixedWidthFieldsAreLittleEndian() throws {
        var writer = ProtobufWriter()
        writer.writeFixed32Field(1, 0x0403_0201)
        writer.writeFixed64Field(2, 0x0807_0605_0403_0201)
        #expect(Array(writer.bytes[1...4]) == [1, 2, 3, 4])
        var reader = ProtobufReader(writer.bytes)
        #expect(try reader.nextField()?.wireType == .fixed32)
        #expect(try reader.readFixed32() == 0x0403_0201)
        #expect(try reader.nextField()?.wireType == .fixed64)
        #expect(try reader.readFixed64() == 0x0807_0605_0403_0201)
    }

    @Test func malformedInputThrows() {
        var truncated = ProtobufReader([0x80])
        #expect(throws: ProtobufError.truncated) { try truncated.readVarint() }
        var overlong = ProtobufReader([UInt8](repeating: 0xFF, count: 11))
        #expect(throws: ProtobufError.overlongVarint) { try overlong.readVarint() }
        var tooLong = ProtobufReader([0x0A, 0x05, 0x01])
        _ = try? tooLong.nextField()
        #expect(throws: ProtobufError.lengthOutOfRange(5)) { try tooLong.readMessage() }
        var fieldZero = ProtobufReader([0x00])
        #expect(throws: ProtobufError.invalidKey(0)) { try fieldZero.nextField() }
        var group = ProtobufReader([0x0B])
        #expect(throws: ProtobufError.unsupportedGroup) {
            let field = try group.nextField()
            try group.skip(field?.wireType ?? .varint)
        }
    }
}

@Suite struct GZipTests {
    @Test func roundTrips() throws {
        let text = Array("The Zêzere meets the Tejo at Constância. ".utf8) + [UInt8](repeating: 7, count: 500)
        let compressed = GZip.compress(text)
        #expect(GZip.isCompressed(compressed))
        #expect(try GZip.decompress(compressed) == text)
    }

    @Test func readsTheOptionalHeaderFields() throws {
        let payload = Array("vector tile".utf8)
        let plain = GZip.compress(payload)
        // FEXTRA, FNAME, FCOMMENT and FHCRC, set and filled in after the
        // fixed ten bytes, in RFC 1952's order.
        var header = Array(plain[0..<10])
        header[3] = 0b0001_1110
        header += [3, 0, 0xAA, 0xBB, 0xCC]
        header += Array("tile.pbf".utf8) + [0]
        header += Array("a comment".utf8) + [0]
        header += [0x12, 0x34]
        let withFields = header + Array(plain[10...])
        #expect(try GZip.decompress(withFields) == payload)
    }

    @Test func rejectsWhatIsNotGzip() {
        #expect(throws: GZipError.truncated) { try GZip.decompress([0x1F, 0x8B]) }
        #expect(throws: GZipError.notGzip) { try GZip.decompress([UInt8](repeating: 0, count: 30)) }
        var reserved = GZip.compress([1, 2, 3])
        reserved[3] = 0x80
        #expect(throws: GZipError.reservedFlags) { try GZip.decompress(reserved) }
    }

    @Test func aWrongChecksumThrows() {
        var bytes = GZip.compress(Array("checksum".utf8))
        bytes[bytes.count - 8] ^= 0xFF
        #expect(throws: GZipError.checksumMismatch) { try GZip.decompress(bytes) }
    }
}

/// Geometry examples from MVT 2.1 §4.3.5, each a command stream and the
/// rings it decodes to.
@Suite struct GeometryTests {
    private func points(_ pairs: [(Int32, Int32)]) -> [TilePoint] {
        pairs.map { TilePoint(x: $0.0, y: $0.1) }
    }

    @Test func aPoint() throws {
        #expect(try VectorTileDecoder.decodeGeometry([9, 50, 34], kind: .point) == [points([(25, 17)])])
    }

    @Test func aMultiPoint() throws {
        #expect(try VectorTileDecoder.decodeGeometry([17, 10, 14, 3, 9], kind: .point)
            == [points([(5, 7), (3, 2)])])
    }

    @Test func aLineString() throws {
        #expect(try VectorTileDecoder.decodeGeometry([9, 4, 4, 18, 0, 16, 16, 0], kind: .lineString)
            == [points([(2, 2), (2, 10), (10, 10)])])
    }

    @Test func aMultiLineString() throws {
        let geometry: [UInt32] = [9, 4, 4, 18, 0, 16, 16, 0, 9, 17, 17, 10, 4, 8]
        #expect(try VectorTileDecoder.decodeGeometry(geometry, kind: .lineString)
            == [points([(2, 2), (2, 10), (10, 10)]), points([(1, 1), (3, 5)])])
    }

    @Test func aPolygon() throws {
        let feature = VectorFeature(kind: .polygon,
                                    rings: try VectorTileDecoder.decodeGeometry([9, 6, 12, 18, 10, 12, 24, 44, 15],
                                                                                kind: .polygon))
        #expect(feature.rings == [points([(3, 6), (8, 12), (20, 34)])])
        #expect(feature.polygons == [VectorPolygon(exterior: points([(3, 6), (8, 12), (20, 34)]))])
    }

    @Test func aMultiPolygonTellsExteriorFromInteriorRings() throws {
        let geometry: [UInt32] = [9, 0, 0, 26, 20, 0, 0, 20, 19, 0, 15, 9, 22, 2, 26, 18, 0, 0, 18, 17, 0, 15,
                                  9, 4, 13, 26, 0, 8, 8, 0, 0, 7, 15]
        let feature = VectorFeature(kind: .polygon,
                                    rings: try VectorTileDecoder.decodeGeometry(geometry, kind: .polygon))
        #expect(feature.polygons == [
            VectorPolygon(exterior: points([(0, 0), (10, 0), (10, 10), (0, 10)])),
            VectorPolygon(exterior: points([(11, 11), (20, 11), (20, 20), (11, 20)]),
                          interiors: [points([(13, 13), (13, 17), (17, 17), (17, 13)])]),
        ])
    }

    @Test func polygonsAreWoundAsTheSpecRequires() {
        let anticlockwise = points([(0, 0), (0, 10), (10, 10), (10, 0)])
        let feature = VectorFeature(polygons: [VectorPolygon(exterior: anticlockwise,
                                                             interiors: [points([(2, 2), (4, 2), (4, 4)])])])
        #expect(VectorFeature.doubledSignedArea(of: feature.rings[0]) > 0)
        #expect(VectorFeature.doubledSignedArea(of: feature.rings[1]) < 0)
        #expect(feature.polygons.count == 1)
        #expect(feature.polygons[0].interiors.count == 1)
    }

    @Test func malformedCommandsThrow() {
        typealias Problem = VectorTileError.GeometryProblem
        #expect(throws: Problem.unknownCommand(3)) { try VectorTileDecoder.decodeGeometry([11, 0, 0], kind: .point) }
        #expect(throws: Problem.missingParameters) { try VectorTileDecoder.decodeGeometry([9, 50], kind: .point) }
        #expect(throws: Problem.noCurrentPath) { try VectorTileDecoder.decodeGeometry([10, 2, 2], kind: .lineString) }
        #expect(throws: Problem.invalidCount(command: 7, count: 2)) {
            try VectorTileDecoder.decodeGeometry([9, 0, 0, 18, 2, 0, 0, 2, 23], kind: .polygon)
        }
        #expect(throws: Problem.commandNotAllowed(command: 7)) {
            try VectorTileDecoder.decodeGeometry([9, 0, 0, 10, 2, 2, 15], kind: .lineString)
        }
        #expect(throws: Problem.unclosedRing) {
            try VectorTileDecoder.decodeGeometry([9, 0, 0, 18, 2, 0, 0, 2], kind: .polygon)
        }
        #expect(throws: Problem.invalidCount(command: 1, count: 2)) {
            try VectorTileDecoder.decodeGeometry([17, 0, 0, 2, 2], kind: .lineString)
        }
        #expect(throws: Problem.coordinateOutOfRange) {
            try VectorTileDecoder.decodeGeometry([17, 4_294_967_294, 0, 4_294_967_294, 0], kind: .point)
        }
    }
}

@Suite struct VectorTileDecoderTests {
    /// A layer written field by field, its features before its keys and
    /// values as the spec allows, with a value of every type.
    private func handBuiltTile() -> [UInt8] {
        var feature = ProtobufWriter()
        feature.writeVarintField(1, 42)
        feature.writePackedField(2, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
        feature.writeVarintField(3, 1)
        feature.writePackedField(4, [9, 50, 34])

        var layer = ProtobufWriter()
        layer.writeVarintField(15, 2)
        layer.writeStringField(1, "poi")
        layer.writeBytesField(2, feature.bytes)
        for key in ["name", "rank", "height", "ratio", "offset", "open", "level"] {
            layer.writeStringField(3, key)
        }
        var values: [[UInt8]] = []
        var value = ProtobufWriter()
        value.writeStringField(1, "Café Vanda")
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeVarintField(5, 3)
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeFixed64Field(3, (12.5).bitPattern)
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeFixed32Field(2, Float(0.25).bitPattern)
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeVarintField(6, ZigZag.encode(Int64(-7)))
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeVarintField(7, 1)
        values.append(value.bytes)
        value = ProtobufWriter()
        value.writeVarintField(4, 2)
        values.append(value.bytes)
        for encoded in values { layer.writeBytesField(4, encoded) }
        layer.writeVarintField(5, 4096)

        var tile = ProtobufWriter()
        tile.writeBytesField(3, layer.bytes)
        // An extension field the decoder must skip.
        tile.writeVarintField(16, 99)
        return tile.bytes
    }

    @Test func decodesAHandBuiltTile() throws {
        let tile = try VectorTileDecoder.decode(handBuiltTile())
        let layer = try #require(tile[layer: "poi"])
        #expect(layer.version == 2)
        #expect(layer.extent == 4096)
        let feature = try #require(layer.features.first)
        #expect(feature.id == 42)
        #expect(feature.kind == .point)
        #expect(feature.rings == [[TilePoint(x: 25, y: 17)]])
        #expect(feature.properties == ["name": "Café Vanda", "rank": .uint(3), "height": .double(12.5),
                                       "ratio": .float(0.25), "offset": .int(-7), "open": true, "level": 2])
    }

    @Test func decodesGzippedBytes() throws {
        let plain = handBuiltTile()
        #expect(try VectorTileDecoder.decode(GZip.compress(plain)) == VectorTileDecoder.decode(plain))
    }

    @Test func aBadTagThrows() {
        var feature = ProtobufWriter()
        feature.writePackedField(2, [0, 5])
        feature.writeVarintField(3, 1)
        feature.writePackedField(4, [9, 2, 2])
        var layer = ProtobufWriter()
        layer.writeStringField(1, "poi")
        layer.writeBytesField(2, feature.bytes)
        layer.writeStringField(3, "name")
        var tile = ProtobufWriter()
        tile.writeBytesField(3, layer.bytes)
        #expect(throws: VectorTileError.invalidTags) { try VectorTileDecoder.decode(tile.bytes) }
    }

    @Test func aLayerNeedsAName() {
        var layer = ProtobufWriter()
        layer.writeVarintField(5, 4096)
        var tile = ProtobufWriter()
        tile.writeBytesField(3, layer.bytes)
        #expect(throws: VectorTileError.missingLayerName) { try VectorTileDecoder.decode(tile.bytes) }
    }

    @Test func anEmptyTileHasNoLayers() throws {
        #expect(try VectorTileDecoder.decode([]).layers.isEmpty)
    }

    @Test func theEncoderRoundTrips() throws {
        let tile = VectorTile(layers: [
            VectorLayer(name: "transportation", features: [
                .line(id: 1, [[TilePoint(x: 0, y: 0), TilePoint(x: 100, y: 4_000)],
                              [TilePoint(x: -64, y: 10), TilePoint(x: 4_160, y: 10)]],
                      properties: ["class": "primary", "oneway": 1]),
            ]),
            VectorLayer(name: "water", extent: 512, features: [
                VectorFeature(id: 2, polygons: [VectorPolygon(
                    exterior: [TilePoint(x: 0, y: 0), TilePoint(x: 0, y: 500), TilePoint(x: 500, y: 500)],
                    interiors: [[TilePoint(x: 10, y: 20), TilePoint(x: 10, y: 400), TilePoint(x: 300, y: 400)]])],
                    properties: ["class": "lake", "area": .double(1.5), "negative": .int(-3)]),
            ]),
            VectorLayer(name: "place", features: [
                .point(TilePoint(x: 2_048, y: 1_024), properties: ["name": "Millbrook", "capital": false]),
            ]),
        ])
        #expect(try VectorTileDecoder.decode(VectorTileEncoder.encode(tile)) == tile)
    }
}

@Suite struct RealTileTests {
    static func fixture() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openfreemap-14-7812-6233.pbf.gz")
        return Array(try Data(contentsOf: url))
    }

    @Test func decodesOpenFreeMapsTileOfConstancia() throws {
        let tile = try VectorTileDecoder.decode(Self.fixture())
        #expect(tile.layers.map(\.name) == ["boundary", "building", "housenumber", "landcover", "landuse", "place",
                                            "poi", "transportation", "transportation_name", "water", "water_name",
                                            "waterway"])
        #expect(tile.layers.allSatisfy { $0.version == 2 && $0.extent == 4096 })
        let counts = Dictionary(uniqueKeysWithValues: tile.layers.map { ($0.name, $0.features.count) })
        #expect(counts["poi"] == 151)
        #expect(counts["transportation"] == 117)
        #expect(counts["waterway"] == 16)
        let place = try #require(tile[layer: "place"])
        let town = try #require(place.features.first { $0.properties["name"] == "Constância" })
        #expect(town.properties["class"] == "town")
        #expect(town.kind == .point)
        let rivers = Set(tile[layer: "waterway"]?.features.compactMap { $0.properties["name"]?.stringValue } ?? [])
        #expect(rivers.isSuperset(of: ["Rio Tejo", "Rio Zêzere"]))
    }

    @Test func everyPolygonHasAnExteriorRing() throws {
        let tile = try VectorTileDecoder.decode(Self.fixture())
        let polygons = tile.layers.flatMap(\.features).filter { $0.kind == .polygon }
        #expect(!polygons.isEmpty)
        for feature in polygons {
            #expect(!feature.polygons.isEmpty)
            for polygon in feature.polygons {
                #expect(VectorFeature.doubledSignedArea(of: polygon.exterior) > 0)
                #expect(polygon.interiors.allSatisfy { VectorFeature.doubledSignedArea(of: $0) < 0 })
            }
        }
    }

    @Test func theTownLiesInItsTile() throws {
        let tile = try VectorTileDecoder.decode(Self.fixture())
        let id = TileID(zoom: 14, x: 7812, y: 6233)
        let town = try #require(tile[layer: "place"]?.features.first { $0.properties["name"] == "Constância" })
        let coordinate = id.coordinate(of: town.rings[0][0], extent: 4096)
        #expect(id.bounds.contains(coordinate))
    }

    @Test func reEncodingTheRealTileRoundTrips() throws {
        let tile = try VectorTileDecoder.decode(Self.fixture())
        #expect(try VectorTileDecoder.decode(VectorTileEncoder.encode(tile)) == tile)
    }

    /// Cut short and corrupted copies of the real tile: each decodes or
    /// throws, and none traps — the test finishing is the assertion.
    @Test func malformedCopiesNeverTrap() throws {
        let inflated = try GZip.decompress(Self.fixture())
        var generator = SplitMix64(seed: 0x6D61_7073)
        for length in stride(from: 0, to: inflated.count, by: 211) {
            _ = try? VectorTileDecoder.decode(Array(inflated[0..<length]))
        }
        for _ in 0..<300 {
            var corrupted = inflated
            for _ in 0..<1 + Int(generator.next() % 8) {
                let index = Int(generator.next() % UInt64(corrupted.count))
                corrupted[index] = UInt8(truncatingIfNeeded: generator.next())
            }
            _ = try? VectorTileDecoder.decode(corrupted)
        }
        let gzipped = try Self.fixture()
        for length in stride(from: 1, to: gzipped.count, by: 997) {
            #expect((try? VectorTileDecoder.decode(Array(gzipped[0..<length]))) == nil)
        }
    }
}

/// SplitMix64 (Steele, Lea, Flood 2014): a seeded generator, so the
/// corrupted copies are the same on every run.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
