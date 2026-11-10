import Foundation

/// Distances and directions on the ground, on a sphere of the mean Earth
/// radius — the formulas Ed Williams' *Aviation Formulary* and Chris
/// Veness' "Calculate distance, bearing and more between
/// Latitude/Longitude points" (movable-type.co.uk) give. A sphere is
/// within 0.5 % of the ellipsoid, far inside a GPS fix's error.
public enum GeoMeasure {
    /// The mean Earth radius, R₁ = (2a + b) / 3 of WGS 84, in metres
    /// (IUGG, Moritz, "Geodetic Reference System 1980").
    public static let meanEarthRadius = 6_371_008.8

    static func radians(_ degrees: Double) -> Double { degrees * .pi / Degrees.halfTurn }
    static func degrees(_ radians: Double) -> Double { radians * Degrees.halfTurn / .pi }

    /// The great-circle distance between two points, in metres, by the
    /// haversine formula (Sinnott, "Virtues of the Haversine", Sky and
    /// Telescope 68, 1984), which stays exact at short range.
    public static func distance(_ from: GeoCoordinate, _ to: GeoCoordinate) -> Double {
        let latitude1 = radians(from.latitude), latitude2 = radians(to.latitude)
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = radians(to.longitude - from.longitude)
        let haversine = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 2 * meanEarthRadius * atan2(haversine.squareRoot(), (1 - haversine).squareRoot())
    }

    /// The initial bearing from one point towards another, in degrees
    /// clockwise from true north, 0 ..< 360.
    public static func bearing(_ from: GeoCoordinate, _ to: GeoCoordinate) -> Double {
        let latitude1 = radians(from.latitude), latitude2 = radians(to.latitude)
        let deltaLongitude = radians(to.longitude - from.longitude)
        let east = sin(deltaLongitude) * cos(latitude2)
        let north = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
        return normalizedBearing(degrees(atan2(east, north)))
    }

    /// The point `distance` metres from `origin` along the great circle
    /// that leaves it at `bearing` degrees.
    public static func destination(from origin: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        let angular = distance / meanEarthRadius
        let heading = radians(bearing)
        let latitude1 = radians(origin.latitude), longitude1 = radians(origin.longitude)
        let latitude2 = asin(sin(latitude1) * cos(angular) + cos(latitude1) * sin(angular) * cos(heading))
        let longitude2 = longitude1 + atan2(sin(heading) * sin(angular) * cos(latitude1),
                                            cos(angular) - sin(latitude1) * sin(latitude2))
        return GeoCoordinate(latitude: degrees(latitude2), longitude: degrees(longitude2)).normalized
    }

    /// The point a fraction of the way from one point to another, straight
    /// across the projected map: within a street's length, the same point
    /// as along the great circle to well under a centimetre.
    public static func interpolate(_ from: GeoCoordinate, _ to: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                      longitude: from.longitude + (to.longitude - from.longitude) * fraction)
    }

    /// A bearing brought into 0 ..< 360.
    public static func normalizedBearing(_ bearing: Double) -> Double {
        guard bearing.isFinite else { return 0 }
        let wrapped = bearing.truncatingRemainder(dividingBy: Degrees.fullTurn)
        return wrapped < 0 ? wrapped + Degrees.fullTurn : wrapped
    }

    /// The signed turn from one bearing to another, −180 ..< 180: positive
    /// clockwise, to the right.
    public static func turn(from first: Double, to second: Double) -> Double {
        let difference = normalizedBearing(second - first)
        return difference >= Degrees.halfTurn ? difference - Degrees.fullTurn : difference
    }

    /// The length of a line through points, in metres.
    public static func length(of line: [GeoCoordinate]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}

/// A flat map of the ground near a point, in metres east and north of it:
/// the equirectangular approximation, x = R·Δλ·cos φ₀, y = R·Δφ. Over a
/// few kilometres its error is a fraction of a metre, which is what a
/// projection of a fix onto a route needs, and its arithmetic is a
/// multiplication a coordinate.
public struct LocalPlane: Sendable, Equatable {
    public let reference: GeoCoordinate
    private let metresPerDegreeLatitude: Double
    private let metresPerDegreeLongitude: Double

    public init(reference: GeoCoordinate) {
        self.reference = reference
        metresPerDegreeLatitude = GeoMeasure.meanEarthRadius * .pi / Degrees.halfTurn
        metresPerDegreeLongitude = metresPerDegreeLatitude * cos(GeoMeasure.radians(reference.latitude))
    }

    /// Metres east and north of the reference.
    public func point(_ coordinate: GeoCoordinate) -> (east: Double, north: Double) {
        var deltaLongitude = coordinate.longitude - reference.longitude
        if deltaLongitude > Degrees.halfTurn { deltaLongitude -= Degrees.fullTurn }
        if deltaLongitude < -Degrees.halfTurn { deltaLongitude += Degrees.fullTurn }
        return (deltaLongitude * metresPerDegreeLongitude,
                (coordinate.latitude - reference.latitude) * metresPerDegreeLatitude)
    }

    /// The coordinate `east` and `north` metres from the reference.
    public func coordinate(east: Double, north: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: reference.latitude + north / metresPerDegreeLatitude,
                      longitude: reference.longitude
                          + (metresPerDegreeLongitude > 0 ? east / metresPerDegreeLongitude : 0)).normalized
    }
}
