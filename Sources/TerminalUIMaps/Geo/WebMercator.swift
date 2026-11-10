import Foundation

/// A position on the Web Mercator square, the unit world: x runs 0 at
/// 180° W to 1 at 180° E, y runs 0 at the northern limit to 1 at the
/// southern one, as tile rows do.
public struct WorldPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Spherical ("Web") Mercator, EPSG:3857 — the projection of the
/// OpenStreetMap and Google tile schemes, which treats WGS 84 coordinates as
/// if on a sphere. Normalised here to the unit square rather than metres.
///
/// Forward, for longitude λ and latitude φ in radians:
///   x = (λ + π) / 2π
///   y = (π − ln(tan(π/4 + φ/2))) / 2π
/// Inverse: λ = 2πx − π, φ = 2·atan(exp(π − 2πy)) − π/2.
public enum WebMercator {
    /// The latitude at which the projected world is square:
    /// atan(sinh(π)) in degrees. Tile schemes cut the poles off there.
    public static let maximumLatitude = 85.051_128_779_806_59

    public static func project(_ coordinate: GeoCoordinate) -> WorldPoint {
        let latitude = min(max(coordinate.latitude, -maximumLatitude), maximumLatitude)
        let longitudeRadians = coordinate.longitude * .pi / Degrees.halfTurn
        let latitudeRadians = latitude * .pi / Degrees.halfTurn
        let x = (longitudeRadians + .pi) / (2 * .pi)
        let y = (.pi - log(tan(.pi / 4 + latitudeRadians / 2))) / (2 * .pi)
        return WorldPoint(x: x, y: y)
    }

    public static func unproject(_ point: WorldPoint) -> GeoCoordinate {
        let longitudeRadians = 2 * .pi * point.x - .pi
        let latitudeRadians = 2 * atan(exp(.pi - 2 * .pi * point.y)) - .pi / 2
        return GeoCoordinate(latitude: latitudeRadians * Degrees.halfTurn / .pi,
                             longitude: longitudeRadians * Degrees.halfTurn / .pi)
    }

    /// The ground distance one unit of the world spans at a latitude, in
    /// metres: the equator's length, shrunk by the Mercator scale factor
    /// cos φ. The equatorial circumference is that of WGS 84's semi-major
    /// axis, 6 378 137 m, as EPSG:3857 defines its sphere.
    public static func metresPerWorldUnit(atLatitude latitude: Double) -> Double {
        2 * .pi * earthRadius * cos(latitude * .pi / Degrees.halfTurn)
    }

    static let earthRadius = 6_378_137.0

    /// The point halfway along a line by its length on the projected map —
    /// where a road's name goes — or nil for no points.
    public static func midpoint(of line: [GeoCoordinate]) -> GeoCoordinate? {
        let projected = line.map(project)
        guard projected.count >= 2 else { return line.first }
        let lengths = zip(projected, projected.dropFirst()).map { start, end in
            ((end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y)).squareRoot()
        }
        var remaining = lengths.reduce(0, +) / 2
        for (index, length) in lengths.enumerated() {
            if remaining <= length, length > 0 {
                let fraction = remaining / length
                let start = projected[index]
                let end = projected[index + 1]
                return unproject(WorldPoint(x: start.x + (end.x - start.x) * fraction,
                                            y: start.y + (end.y - start.y) * fraction))
            }
            remaining -= length
        }
        return line.last
    }
}
