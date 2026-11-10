/// One Mapbox Vector Tile (MVT 2.1): named layers of features in tile
/// coordinates.
struct VectorTile: Sendable, Equatable {
    var layers: [VectorLayer]

    init(layers: [VectorLayer]) {
        self.layers = layers
    }

    /// The first layer with a name. The spec forbids two layers of one name
    /// in a tile.
    public subscript(layer name: String) -> VectorLayer? {
        layers.first { $0.name == name }
    }
}

/// A layer of a tile (MVT 2.1 §4.1).
struct VectorLayer: Sendable, Equatable {
    /// The extent the spec defaults to.
    static let defaultExtent = 4096
    /// The version this decoder reads.
    static let specificationVersion = 2

    var name: String
    var version: Int
    /// The width and height of the tile in this layer's coordinates; a
    /// feature may reach beyond it into a buffer around the tile.
    var extent: Int
    var features: [VectorFeature]

    init(name: String, version: Int = VectorLayer.specificationVersion,
                extent: Int = VectorLayer.defaultExtent, features: [VectorFeature]) {
        self.name = name
        self.version = version
        self.extent = extent
        self.features = features
    }
}

/// A point in a layer's tile coordinates: x right, y down, the tile from 0
/// to the layer's extent.
struct TilePoint: Sendable, Hashable {
    var x: Int32
    var y: Int32

    init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

/// A feature's property value (MVT 2.1 §4.1, the `Value` message).
enum VectorValue: Sendable, Hashable {
    case string(String)
    case float(Float)
    case double(Double)
    case int(Int64)
    case uint(UInt64)
    case bool(Bool)

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// Any numeric value as a `Double`.
    var numberValue: Double? {
        switch self {
        case .float(let number): Double(number)
        case .double(let number): number
        case .int(let number): Double(number)
        case .uint(let number): Double(number)
        case .string, .bool: nil
        }
    }
}

extension VectorValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// A polygon of a feature: one exterior ring and the holes in it.
struct VectorPolygon: Sendable, Equatable {
    var exterior: [TilePoint]
    var interiors: [[TilePoint]]

    init(exterior: [TilePoint], interiors: [[TilePoint]] = []) {
        self.exterior = exterior
        self.interiors = interiors
    }
}

/// A feature of a layer (MVT 2.1 §4.2).
struct VectorFeature: Sendable, Equatable {
    /// MVT 2.1 §4.3.4's geometry types.
    enum Kind: Int, Sendable {
        case unknown = 0
        case point = 1
        case lineString = 2
        case polygon = 3
    }

    var id: UInt64?
    var kind: Kind
    /// The geometry, by kind: for points, one list of every point; for
    /// lines, one list per line string; for polygons, one per ring, each
    /// closed implicitly (the first point is not repeated at the end).
    var rings: [[TilePoint]]
    var properties: [String: VectorValue]
    /// For a polygon feature, its rings grouped by the spec's winding rule:
    /// an exterior ring has a positive surveyor's-formula area in tile
    /// coordinates (clockwise as drawn, y being down), and each is followed
    /// by its interior rings, of negative area. A ring of zero area, or an
    /// interior ring before any exterior one, is dropped. Empty for other
    /// kinds.
    private(set) var polygons: [VectorPolygon]

    init(id: UInt64? = nil, kind: Kind, rings: [[TilePoint]], properties: [String: VectorValue] = [:]) {
        self.id = id
        self.kind = kind
        self.rings = rings
        self.properties = properties
        self.polygons = kind == .polygon ? VectorFeature.group(rings) : []
    }

    /// A polygon feature from polygons, each ring wound as the spec requires
    /// whichever way it was given.
    init(id: UInt64? = nil, polygons: [VectorPolygon], properties: [String: VectorValue] = [:]) {
        var rings: [[TilePoint]] = []
        for polygon in polygons {
            rings.append(VectorFeature.wound(polygon.exterior, positive: true))
            for interior in polygon.interiors {
                rings.append(VectorFeature.wound(interior, positive: false))
            }
        }
        self.init(id: id, kind: .polygon, rings: rings, properties: properties)
    }

    /// A point feature.
    static func point(id: UInt64? = nil, _ point: TilePoint,
                             properties: [String: VectorValue] = [:]) -> VectorFeature {
        VectorFeature(id: id, kind: .point, rings: [[point]], properties: properties)
    }

    /// A line feature of one or more line strings.
    static func line(id: UInt64? = nil, _ lines: [[TilePoint]],
                            properties: [String: VectorValue] = [:]) -> VectorFeature {
        VectorFeature(id: id, kind: .lineString, rings: lines, properties: properties)
    }

    public subscript(property key: String) -> VectorValue? { properties[key] }

    /// Twice the signed area of a ring by the surveyor's (shoelace) formula,
    /// in tile coordinates: positive for an exterior ring under MVT 2.1
    /// §4.3.4.4.
    static func doubledSignedArea(of ring: [TilePoint]) -> Int64 {
        guard ring.count >= 3 else { return 0 }
        var sum: Int64 = 0
        var previous = ring[ring.count - 1]
        for point in ring {
            // Each product fits 63 bits, their difference may not: a
            // malformed ring wraps rather than trapping.
            sum = sum &+ (Int64(previous.x) * Int64(point.y) &- Int64(point.x) * Int64(previous.y))
            previous = point
        }
        return sum
    }

    private static func group(_ rings: [[TilePoint]]) -> [VectorPolygon] {
        var polygons: [VectorPolygon] = []
        for ring in rings {
            let area = doubledSignedArea(of: ring)
            if area > 0 {
                polygons.append(VectorPolygon(exterior: ring))
            } else if area < 0, !polygons.isEmpty {
                polygons[polygons.count - 1].interiors.append(ring)
            }
        }
        return polygons
    }

    private static func wound(_ ring: [TilePoint], positive: Bool) -> [TilePoint] {
        (doubledSignedArea(of: ring) > 0) == positive ? ring : ring.reversed()
    }
}
