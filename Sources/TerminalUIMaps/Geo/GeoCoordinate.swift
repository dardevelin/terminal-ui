/// A point on the WGS 84 ellipsoid, in degrees: latitude positive north,
/// longitude positive east.
public struct GeoCoordinate: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The same point with its longitude brought into −180 ..< 180.
    public var normalized: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: GeoCoordinate.wrappedLongitude(longitude))
    }

    static func wrappedLongitude(_ longitude: Double) -> Double {
        let span = Degrees.fullTurn
        var wrapped = (longitude + Degrees.halfTurn).truncatingRemainder(dividingBy: span)
        if wrapped < 0 { wrapped += span }
        return wrapped - Degrees.halfTurn
    }
}

/// Angles a longitude wraps over.
enum Degrees {
    static let fullTurn = 360.0
    static let halfTurn = 180.0
}

/// A latitude/longitude box. It does not cross the antimeridian: `west` is
/// at most `east`.
extension GeoCoordinate {
    /// The great-circle distance to `other`, in metres, on a sphere of the
    /// Earth's mean radius (IUGG): within half a percent of the ellipsoid's.
    public func distance(to other: GeoCoordinate) -> Double {
        GeoMeasure.distance(self, other)
    }

    /// The initial bearing of the great circle to `other`, degrees
    /// clockwise from north, 0 ..< 360.
    public func bearing(to other: GeoCoordinate) -> Double {
        GeoMeasure.bearing(self, other)
    }
}

public struct GeoRect: Sendable, Hashable, Codable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    /// The box spanned by two corners, whichever way round they are given.
    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = min(south, north)
        self.north = max(south, north)
        self.west = min(west, east)
        self.east = max(west, east)
    }

    /// The smallest box holding every coordinate, or nil for none.
    public init?(covering coordinates: some Sequence<GeoCoordinate>) {
        var iterator = coordinates.makeIterator()
        guard let first = iterator.next() else { return nil }
        var box = GeoRect(south: first.latitude, west: first.longitude,
                          north: first.latitude, east: first.longitude)
        while let next = iterator.next() {
            box = box.union(GeoRect(south: next.latitude, west: next.longitude,
                                    north: next.latitude, east: next.longitude))
        }
        self = box
    }

    public var southWest: GeoCoordinate { GeoCoordinate(latitude: south, longitude: west) }
    public var northEast: GeoCoordinate { GeoCoordinate(latitude: north, longitude: east) }
    public var center: GeoCoordinate {
        GeoCoordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
    }

    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
    }

    public func intersects(_ other: GeoRect) -> Bool {
        south <= other.north && other.south <= north && west <= other.east && other.west <= east
    }

    public func union(_ other: GeoRect) -> GeoRect {
        GeoRect(south: min(south, other.south), west: min(west, other.west),
                north: max(north, other.north), east: max(east, other.east))
    }
}
