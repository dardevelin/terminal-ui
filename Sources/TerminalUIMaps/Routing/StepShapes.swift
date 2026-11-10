/// Manoeuvres read from the shape of a route, for routers that give only a
/// sentence a step — MapKit's `MKRoute.Step` has `instructions` and a
/// `polyline`, and no type or direction.
enum StepShapes {
    /// How far back from a step boundary, and on from it, the bearing
    /// either side is measured over, in metres: a polyline's last few
    /// metres into a junction often bend with the kerb, and a street's
    /// direction is what a turn is measured against.
    static let bearingSpan = 20.0

    /// One manoeuvre for each step's polyline: the first a departure, the
    /// last an arrival, and each between inferred from the bearing the
    /// traveller arrives on — the end of the step before — and the one
    /// they leave on, the start of their own (``Maneuver/inferred(bearingBefore:bearingAfter:)``).
    static func maneuvers(of polylines: [[GeoCoordinate]]) -> [Maneuver] {
        var maneuvers: [Maneuver] = []
        var arriving: Double?
        for (index, line) in polylines.enumerated() {
            let leaving = bearing(leaving: line)
            if index == polylines.count - 1, polylines.count > 1 {
                maneuvers.append(Maneuver(kind: .arrive, bearingBefore: arriving))
            } else if let arriving, let leaving {
                maneuvers.append(Maneuver.inferred(bearingBefore: arriving, bearingAfter: leaving))
            } else {
                maneuvers.append(Maneuver(kind: .depart, bearingAfter: leaving))
            }
            if let end = bearing(arriving: line) { arriving = end }
        }
        return maneuvers
    }

    /// The bearing a line leaves its start on: towards its first point
    /// `bearingSpan` along, or its end if it is shorter; nil for a line of
    /// no length.
    static func bearing(leaving line: [GeoCoordinate]) -> Double? {
        guard let start = line.first, let ahead = point(along: line, from: start) else { return nil }
        return GeoMeasure.bearing(start, ahead)
    }

    /// The bearing a line arrives at its end on.
    static func bearing(arriving line: [GeoCoordinate]) -> Double? {
        let reversed = Array(line.reversed())
        guard let end = reversed.first, let behind = point(along: reversed, from: end) else { return nil }
        return GeoMeasure.bearing(behind, end)
    }

    private static func point(along line: [GeoCoordinate], from start: GeoCoordinate) -> GeoCoordinate? {
        var farthest: GeoCoordinate?
        for point in line.dropFirst() where GeoMeasure.distance(start, point) > 0 {
            farthest = point
            if GeoMeasure.distance(start, point) >= bearingSpan { break }
        }
        return farthest
    }
}
