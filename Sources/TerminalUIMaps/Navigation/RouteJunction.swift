import Foundation

/// A manoeuvre of a route as a junction on the map: where it is, the roads
/// that meet there, and how the route turns through them — what decides
/// whether the junction reads on screen at a zoom (``JunctionLegibility``).
public struct RouteJunction: Sendable, Equatable {
    /// Where the junction's roads came from.
    public enum BranchSource: Sendable, Equatable {
        /// The router's own intersection: OSRM's `bearings`.
        case router
        /// The roads of the map's vector tiles around the point.
        case tiles
        /// Only the route's way in and out, and for a fork the way straight
        /// on: nothing else said what meets there.
        case route
    }

    /// The step whose manoeuvre this is.
    public var stepIndex: Int
    /// Metres along the route to the junction.
    public var distanceAlong: Double
    public var coordinate: GeoCoordinate
    public var maneuver: Maneuver
    /// How far the route turns there, in degrees, 0 to 180, read from its
    /// shape.
    public var turnAngle: Double
    /// The bearing the traveller arrives on, degrees clockwise from north.
    public var entryBearing: Double?
    /// The bearing they leave on.
    public var exitBearing: Double?
    /// Every road's bearing leaving the junction, the way in among them
    /// (the arrival's bearing turned round), sorted.
    public var branches: [Double]
    public var branchSource: BranchSource
    /// Across the roundabout the manoeuvre enters, in metres, read from
    /// the route's arc around it.
    public var roundaboutDiameter: Double?

    public init(stepIndex: Int, distanceAlong: Double, coordinate: GeoCoordinate, maneuver: Maneuver,
                turnAngle: Double, entryBearing: Double?, exitBearing: Double?, branches: [Double],
                branchSource: BranchSource, roundaboutDiameter: Double? = nil) {
        self.stepIndex = stepIndex
        self.distanceAlong = distanceAlong
        self.coordinate = coordinate
        self.maneuver = maneuver
        self.turnAngle = turnAngle
        self.entryBearing = entryBearing
        self.exitBearing = exitBearing
        self.branches = branches.sorted()
        self.branchSource = branchSource
        self.roundaboutDiameter = roundaboutDiameter
    }

    /// The bearing of the way in, leaving the junction.
    public var wayInBearing: Double? { entryBearing.map { GeoMeasure.normalizedBearing($0 + Degrees.halfTurn) } }

    /// Whether the traveller must choose here: a turn of the route, or a
    /// manoeuvre that is one whichever way the road bends.
    public func isTurn(gentlestTurn: Double) -> Bool {
        turnAngle >= gentlestTurn || Self.choosingKinds.contains(maneuver.kind)
    }

    /// Manoeuvres that choose a road however little the route bends.
    static let choosingKinds: Set<Maneuver.Kind> = [
        .roundabout, .rotary, .roundaboutTurn, .exitRoundabout, .exitRotary, .fork, .onRamp, .offRamp, .merge,
        .endOfRoad,
    ]

    static let roundaboutKinds: Set<Maneuver.Kind> = [.roundabout, .rotary, .roundaboutTurn]
}

/// The junctions of a route, read from three sources in turn: the router's
/// intersections where it gives them (OSRM's `intersections[].bearings`),
/// else the roads of the vector tiles around the point (any backend whose
/// map is vector tiles), else the route's own way in and out. The route
/// itself adds the rest: how far apart the manoeuvres are, how sharply it
/// turns, and how wide a roundabout it goes round.
public enum JunctionAnalysis {
    /// The junctions of `session`'s route: every step's manoeuvre but the
    /// departure and the arrivals. `roads` gives the road lines near a
    /// point, as ``MapTileStore/lines(near:within:roles:)`` does; with
    /// none, the router's intersections or the route alone are read.
    public static func junctions(of session: NavigationSession, rules: JunctionLegibilityRules = JunctionLegibilityRules(),
                                 roads: (GeoCoordinate, Double) -> [[GeoCoordinate]] = { _, _ in [] })
        -> [RouteJunction] {
        let line = session.line
        let starts = session.stepStarts
        var junctions: [RouteJunction] = []
        for (index, step) in session.route.steps.enumerated() where index > 0 && index < starts.count {
            let maneuver = session.maneuvers[index]
            guard maneuver.kind != .arrive, maneuver.kind != .depart else { continue }
            let along = starts[index]
            let span = StepShapes.bearingSpan
            let entry = line.bearing(from: max(0, along - span), to: along) ?? maneuver.bearingBefore
            let exit = line.bearing(from: along, to: min(line.length, along + span)) ?? maneuver.bearingAfter
            let coordinate = line.coordinate(atDistance: along)
            let wayIn = entry.map { GeoMeasure.normalizedBearing($0 + Degrees.halfTurn) }

            var branches: [Double]
            var source: RouteJunction.BranchSource
            if let intersection = step.intersections?.first, intersection.bearings.count >= 2 {
                branches = intersection.bearings
                source = .router
            } else {
                let found = Self.branches(at: coordinate, lines: roads(coordinate, rules.mouthLength * Self.searchReach),
                                          rules: rules)
                if found.count >= 2 {
                    branches = found
                    source = .tiles
                } else {
                    branches = [wayIn, exit].compactMap { $0 }
                    if [.fork, .onRamp, .offRamp, .merge].contains(maneuver.kind), let entry {
                        branches.append(entry)
                    }
                    source = .route
                }
            }
            // The route's own way in and out are roads of the junction
            // whatever the source missed.
            for bearing in [wayIn, exit].compactMap({ $0 })
                where !branches.contains(where: { abs(GeoMeasure.turn(from: $0, to: bearing)) < rules.sameRoadSeparation }) {
                branches.append(bearing)
            }

            var diameter: Double?
            if RouteJunction.roundaboutKinds.contains(maneuver.kind) {
                let end = index + 1 < starts.count ? starts[index + 1] : line.length
                diameter = Self.arcDiameter(of: line, from: along, to: end)
            }
            junctions.append(RouteJunction(stepIndex: index, distanceAlong: along, coordinate: coordinate,
                                           maneuver: maneuver, turnAngle: session.turnAngle(atDistance: along),
                                           entryBearing: entry, exitBearing: exit, branches: branches,
                                           branchSource: source, roundaboutDiameter: diameter))
        }
        return junctions
    }

    /// How far beyond the mouth roads are looked for: a road's line may
    /// reach the circle from a vertex past it.
    static let searchReach = 3.0

    /// The bearings, leaving `node`, of every road of `lines` that passes
    /// through it: each line coming within the rules' node tolerance is
    /// followed both ways from its nearest point out to the mouth's
    /// circle, and the bearing taken to where it crosses it — the angle a
    /// reader sees the road leave at. A line that ends at the node gives
    /// one branch, one through it two; branches within the same-road
    /// separation of another are one (the same road in two tiles' buffers).
    public static func branches(at node: GeoCoordinate, lines: [[GeoCoordinate]],
                                rules: JunctionLegibilityRules = JunctionLegibilityRules()) -> [Double] {
        let plane = LocalPlane(reference: node)
        let radius = rules.mouthLength
        var bearings: [Double] = []
        for line in lines where line.count >= 2 {
            let points = line.map(plane.point)
            var nearest: (segment: Int, fraction: Double, distance: Double)?
            for segment in 0..<(points.count - 1) {
                let start = points[segment], end = points[segment + 1]
                let deltaEast = end.east - start.east, deltaNorth = end.north - start.north
                let lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth
                let fraction = lengthSquared > 0
                    ? min(max(-(start.east * deltaEast + start.north * deltaNorth) / lengthSquared, 0), 1) : 0
                let east = start.east + deltaEast * fraction, north = start.north + deltaNorth * fraction
                let distance = (east * east + north * north).squareRoot()
                if nearest == nil || distance < nearest!.distance { nearest = (segment, fraction, distance) }
            }
            guard let nearest, nearest.distance <= rules.nodeTolerance else { continue }
            let forward = Array(points[(nearest.segment + 1)...])
            let backward = Array(points[...nearest.segment].reversed())
            for way in [forward, backward] {
                if let bearing = Self.crossing(of: way, radius: radius, tolerance: rules.nodeTolerance) {
                    bearings.append(bearing)
                }
            }
        }
        var merged: [Double] = []
        for bearing in bearings
            where !merged.contains(where: { abs(GeoMeasure.turn(from: $0, to: bearing)) < rules.sameRoadSeparation }) {
            merged.append(bearing)
        }
        return merged.sorted()
    }

    /// The bearing from the node to where a way, its points in metres from
    /// the node, first reaches `radius`; to its end if it stops short but
    /// clear of the node; nil if it never leaves the node.
    private static func crossing(of way: [(east: Double, north: Double)], radius: Double,
                                 tolerance: Double) -> Double? {
        var previous = (east: 0.0, north: 0.0)
        for point in way {
            let distance = (point.east * point.east + point.north * point.north).squareRoot()
            if distance >= radius {
                // Where the segment from the last point inside meets the
                // circle: |previous + t (point − previous)| = radius.
                let deltaEast = point.east - previous.east, deltaNorth = point.north - previous.north
                let quadratic = deltaEast * deltaEast + deltaNorth * deltaNorth
                let linear = 2 * (previous.east * deltaEast + previous.north * deltaNorth)
                let constant = previous.east * previous.east + previous.north * previous.north - radius * radius
                let discriminant = max(0, linear * linear - 4 * quadratic * constant)
                let fraction = quadratic > 0 ? (-linear + discriminant.squareRoot()) / (2 * quadratic) : 1
                let east = previous.east + deltaEast * fraction, north = previous.north + deltaNorth * fraction
                return GeoMeasure.normalizedBearing(GeoMeasure.degrees(atan2(east, north)))
            }
            previous = point
        }
        let distance = (previous.east * previous.east + previous.north * previous.north).squareRoot()
        guard distance > tolerance else { return nil }
        return GeoMeasure.normalizedBearing(GeoMeasure.degrees(atan2(previous.east, previous.north)))
    }

    /// The diameter of the circle an arc of the route follows: its length
    /// over the angle it turns through, summed a short step at a time so a
    /// turn past half a circle counts whole. Nil for an arc that barely
    /// turns, which is no roundabout's.
    static func arcDiameter(of line: RouteLine, from start: Double, to end: Double) -> Double? {
        let length = end - start
        guard length > arcStep * 2 else { return nil }
        var turned = 0.0
        var previous: Double?
        var position = start
        while position + arcStep <= end {
            if let bearing = line.bearing(from: position, to: position + arcStep) {
                if let previous { turned += GeoMeasure.turn(from: previous, to: bearing) }
                previous = bearing
            }
            position += arcStep
        }
        let radians = abs(GeoMeasure.radians(turned))
        guard GeoMeasure.degrees(radians) >= leastRoundaboutTurn else { return nil }
        return 2 * length / radians
    }

    /// Metres between the bearings an arc is measured by: a few to a
    /// small roundabout's quarter.
    private static let arcStep = 2.0
    /// Degrees an arc must turn through to be a roundabout's.
    private static let leastRoundaboutTurn = 30.0
}

extension NavigationSession {
    /// How far the route turns at `distance`: between the bearing of the
    /// line just before and just after it, in degrees, 0 to 180. The end of
    /// the route turns nothing.
    func turnAngle(atDistance distance: Double) -> Double {
        let span = StepShapes.bearingSpan
        guard distance > 0, distance < line.length,
              let before = line.bearing(from: max(0, distance - span), to: distance),
              let after = line.bearing(from: distance, to: min(line.length, distance + span))
        else { return 0 }
        return abs(CameraMotion.signedTurn(from: before, to: after))
    }
}
