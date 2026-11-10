import Foundation

/// A point on a route line: where a position projects onto it.
struct RouteLinePosition: Sendable, Equatable {
    /// The index of the segment, from point `segment` to `segment + 1`.
    var segment: Int
    /// Metres along the line from its start.
    var distanceAlong: Double
    /// How far the position projected lies from the line, in metres.
    var offset: Double
    /// The point on the line.
    var coordinate: GeoCoordinate
    /// The line's bearing there, degrees clockwise from north.
    var bearing: Double
}

/// A route's path measured for navigation: each point's distance from the
/// start, on a local plane in metres, so a fix projects onto it as onto a
/// polyline on paper.
struct RouteLine: Sendable, Equatable {
    let coordinates: [GeoCoordinate]
    /// Metres from the start to each point.
    let cumulative: [Double]
    private let plane: LocalPlane
    private let points: [Planar]

    private struct Planar: Sendable, Equatable {
        var east: Double
        var north: Double
    }

    init(_ coordinates: [GeoCoordinate]) {
        self.coordinates = coordinates
        plane = LocalPlane(reference: coordinates.first ?? GeoCoordinate(latitude: 0, longitude: 0))
        let plane = plane
        points = coordinates.map { coordinate in
            let point = plane.point(coordinate)
            return Planar(east: point.east, north: point.north)
        }
        var total = 0.0
        var cumulative: [Double] = []
        for (index, point) in points.enumerated() {
            if index > 0 {
                let previous = points[index - 1]
                total += ((point.east - previous.east) * (point.east - previous.east)
                    + (point.north - previous.north) * (point.north - previous.north)).squareRoot()
            }
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    /// The line's length in metres.
    var length: Double { cumulative.last ?? 0 }

    /// The nearest point of the line to `coordinate` on a segment that ends
    /// at or after `minimumDistance` along it, the cost of each candidate
    /// raised by `penalty` — which can, say, discourage a segment heading
    /// against the traveller's course. Nil for a line of fewer than two
    /// points.
    func project(_ coordinate: GeoCoordinate, from minimumDistance: Double = 0,
                        penalty: (_ segmentBearing: Double, _ distanceAlong: Double) -> Double = { _, _ in 0 })
        -> RouteLinePosition? {
        guard points.count >= 2 else { return nil }
        let target = plane.point(coordinate)
        var best: (position: RouteLinePosition, cost: Double)?
        for segment in 0..<(points.count - 1) where cumulative[segment + 1] >= minimumDistance {
            let start = points[segment], end = points[segment + 1]
            let deltaEast = end.east - start.east, deltaNorth = end.north - start.north
            let lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth
            guard lengthSquared > 0 else { continue }
            var fraction = ((target.east - start.east) * deltaEast + (target.north - start.north) * deltaNorth)
                / lengthSquared
            fraction = min(max(fraction, 0), 1)
            let along = cumulative[segment] + fraction * lengthSquared.squareRoot()
            if along < minimumDistance {
                fraction = (minimumDistance - cumulative[segment]) / lengthSquared.squareRoot()
            }
            let footEast = start.east + deltaEast * fraction, footNorth = start.north + deltaNorth * fraction
            let offset = ((target.east - footEast) * (target.east - footEast)
                + (target.north - footNorth) * (target.north - footNorth)).squareRoot()
            let bearing = GeoMeasure.normalizedBearing(GeoMeasure.degrees(atan2(deltaEast, deltaNorth)))
            let distanceAlong = cumulative[segment] + fraction * lengthSquared.squareRoot()
            let cost = offset + penalty(bearing, distanceAlong)
            if best == nil || cost < best!.cost {
                best = (RouteLinePosition(segment: segment, distanceAlong: distanceAlong, offset: offset,
                                          coordinate: plane.coordinate(east: footEast, north: footNorth),
                                          bearing: bearing), cost)
            }
        }
        return best?.position
    }

    /// The point `distance` metres along the line, held to its ends.
    func coordinate(atDistance distance: Double) -> GeoCoordinate {
        guard let first = coordinates.first else { return GeoCoordinate(latitude: 0, longitude: 0) }
        guard coordinates.count > 1, distance > 0 else { return first }
        guard distance < length else { return coordinates[coordinates.count - 1] }
        let segment = self.segment(atDistance: distance)
        let span = cumulative[segment + 1] - cumulative[segment]
        let fraction = span > 0 ? (distance - cumulative[segment]) / span : 0
        return GeoMeasure.interpolate(coordinates[segment], coordinates[segment + 1], fraction: fraction)
    }

    /// The bearing of the line from `from` metres along it to `to`.
    func bearing(from: Double, to: Double) -> Double? {
        let start = coordinate(atDistance: from), end = coordinate(atDistance: to)
        guard GeoMeasure.distance(start, end) > 0 else { return nil }
        return GeoMeasure.bearing(start, end)
    }

    /// The line split at `distance` along it: the part travelled, ending
    /// at that point, and the part ahead, beginning there.
    func split(atDistance distance: Double) -> (travelled: [GeoCoordinate], ahead: [GeoCoordinate]) {
        guard coordinates.count > 1 else { return ([], coordinates) }
        let clamped = min(max(distance, 0), length)
        let segment = self.segment(atDistance: clamped)
        let point = coordinate(atDistance: clamped)
        return (Array(coordinates[...segment]) + [point], [point] + Array(coordinates[(segment + 1)...]))
    }

    private func segment(atDistance distance: Double) -> Int {
        var low = 0, high = coordinates.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if cumulative[middle] <= distance { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
