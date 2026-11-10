/// A point on the WGS 84 ellipsoid, in degrees: latitude positive north,
/// longitude positive east.
public struct GeoCoordinate: Sendable, Hashable, Codable {
    /// Degrees north of the equator, −90 ... 90; negative south.
    public var latitude: Double
    /// Degrees east of the prime meridian; negative west.
    public var longitude: Double

    /// The point at `latitude` and `longitude`, in degrees, taken as given.
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

/// A latitude/longitude box. It does not cross the antimeridian: `west` is
/// at most `east`.
public struct GeoRect: Sendable, Hashable, Codable {
    /// The southern edge's latitude, in degrees.
    public var south: Double
    /// The western edge's longitude, in degrees.
    public var west: Double
    /// The northern edge's latitude, in degrees.
    public var north: Double
    /// The eastern edge's longitude, in degrees.
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

    /// The south-west corner.
    public var southWest: GeoCoordinate { GeoCoordinate(latitude: south, longitude: west) }
    /// The north-east corner.
    public var northEast: GeoCoordinate { GeoCoordinate(latitude: north, longitude: east) }
    /// The point midway between the edges, in degrees of each.
    public var center: GeoCoordinate {
        GeoCoordinate(latitude: (south + north) / 2, longitude: (west + east) / 2)
    }

    /// Whether `coordinate` lies inside the box or on its edge.
    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
    }

    /// Whether the two boxes overlap or touch.
    public func intersects(_ other: GeoRect) -> Bool {
        south <= other.north && other.south <= north && west <= other.east && other.west <= east
    }

    /// The smallest box holding both.
    public func union(_ other: GeoRect) -> GeoRect {
        GeoRect(south: min(south, other.south), west: min(west, other.west),
                north: max(north, other.north), east: max(east, other.east))
    }
}
