import Foundation

/// Directions through the sample town's streets: the shortest way along
/// them from the street nearest the origin to the street nearest the
/// destination, with a step for each street taken. No network, so
/// directions work on a first launch and in tests as search does.
public struct SampleRoutes: RouteProvider {
    /// Directions over the sample town's streets.
    public init() {}

    /// The shortest way along the town's streets, the ones `mode` may take,
    /// between those nearest each end; throws
    /// ``MapServiceError/noRoute(_:)`` where no street reaches either.
    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate,
                      mode: TravelMode) async throws -> Route {
        try SampleRoutes.network.route(from: origin, to: destination, mode: mode)
    }

    /// The first leg leaves along `bearing` unless turning back is far
    /// shorter: going back costs a U-turn's penalty. Each later leg leaves a
    /// stop the way the leg before arrived at it, so a route carries on
    /// through a stop rather than reversing there — OSRM's
    /// `continue_straight`, the default of its car profile (OSRM HTTP API,
    /// route service).
    public func route(through waypoints: [GeoCoordinate], mode: TravelMode, departing bearing: Double?) async throws
        -> Route {
        guard waypoints.count >= 2 else { throw MapServiceError.noRoute("a route needs a start and an end") }
        var legs: [Route] = []
        var leaving = bearing
        for (origin, destination) in zip(waypoints, waypoints.dropFirst()) {
            let leg = try SampleRoutes.network.route(from: origin, to: destination, mode: mode, departing: leaving)
            legs.append(leg)
            leaving = SampleRoutes.arrivingBearing(of: leg.coordinates)
        }
        return Route.joining(legs)
    }

    /// The bearing a leg arrives on: that of its last stretch long enough to
    /// have one.
    private static func arrivingBearing(of coordinates: [GeoCoordinate]) -> Double? {
        for (before, last) in zip(coordinates.dropLast().reversed(), coordinates.reversed())
        where GeoMeasure.distance(before, last) > minimumStretch {
            return GeoMeasure.bearing(before, last)
        }
        return nil
    }

    /// A stretch shorter than this, in metres, has no bearing worth trusting.
    private static let minimumStretch = 1.0

    /// The town's streets as a graph, built once.
    static let network = StreetNetwork(streets: SampleTown.streets)
}

/// Streets cut at every crossing into edges between junctions, and the
/// shortest way through them (Dijkstra, "A note on two problems in
/// connexion with graphs", Numerische Mathematik 1, 1959).
struct StreetNetwork: Sendable {
    struct Point: Sendable, Hashable {
        var east: Double
        var north: Double
    }

    struct Edge: Sendable {
        var from: Int
        var to: Int
        var street: Int
        var length: Double
    }

    let streets: [SampleTown.Street]
    private(set) var nodes: [Point] = []
    private(set) var edges: [Edge] = []
    private var adjacency: [[Int]] = []

    /// Junctions closer than this, in metres, are one.
    private static let junctionTolerance = 0.1

    /// How fast each mode goes on town streets, in metres a second: 30
    /// km/h driving, 15 cycling, 5 walking — the urban speeds OSRM's car,
    /// bicycle and foot profiles assume for residential roads.
    private static func speed(_ mode: TravelMode) -> Double {
        switch mode {
        case .driving: 30_000.0 / 3_600
        case .cycling: 15_000.0 / 3_600
        case .walking: 5_000.0 / 3_600
        }
    }

    /// Bearings closer than this, in degrees, read as going straight on.
    private static let straightOn = 20.0

    /// The farthest, in metres, a place may lie from every street and still
    /// be routed from or to.
    private static let reach = 400.0

    init(streets: [SampleTown.Street]) {
        self.streets = streets
        var segments: [(street: Int, start: Point, end: Point)] = []
        for (index, street) in streets.enumerated() {
            for (start, end) in zip(street.path, street.path.dropFirst()) {
                segments.append((index, Point(east: start.0, north: start.1), Point(east: end.0, north: end.1)))
            }
        }
        var cuts = segments.map { _ in [0.0, 1.0] }
        for first in segments.indices {
            for second in segments.indices where second > first {
                guard let crossing = StreetNetwork.intersection(segments[first], segments[second]) else { continue }
                cuts[first].append(crossing.first)
                cuts[second].append(crossing.second)
            }
        }
        for (index, segment) in segments.enumerated() {
            let positions = Set(cuts[index]).sorted()
            var previous: Int?
            for position in positions {
                let point = Point(east: segment.start.east + (segment.end.east - segment.start.east) * position,
                                  north: segment.start.north + (segment.end.north - segment.start.north) * position)
                let node = node(at: point)
                if let previous, previous != node { connect(previous, node, street: segment.street) }
                previous = node
            }
        }
    }

    private mutating func node(at point: Point) -> Int {
        if let existing = nodes.firstIndex(where: {
            abs($0.east - point.east) < StreetNetwork.junctionTolerance
                && abs($0.north - point.north) < StreetNetwork.junctionTolerance
        }) {
            return existing
        }
        nodes.append(point)
        adjacency.append([])
        return nodes.count - 1
    }

    private mutating func connect(_ from: Int, _ to: Int, street: Int) {
        let length = StreetNetwork.distance(nodes[from], nodes[to])
        edges.append(Edge(from: from, to: to, street: street, length: length))
        adjacency[from].append(edges.count - 1)
        adjacency[to].append(edges.count - 1)
    }

    /// Where two segments meet, as the fraction of the way along each, or
    /// nil when they do not (parallel ones included).
    private static func intersection(_ first: (street: Int, start: Point, end: Point),
                                     _ second: (street: Int, start: Point, end: Point))
        -> (first: Double, second: Double)? {
        let firstX = first.end.east - first.start.east, firstY = first.end.north - first.start.north
        let secondX = second.end.east - second.start.east, secondY = second.end.north - second.start.north
        let denominator = firstX * secondY - firstY * secondX
        guard abs(denominator) > .ulpOfOne else { return nil }
        let offsetX = second.start.east - first.start.east, offsetY = second.start.north - first.start.north
        let alongFirst = (offsetX * secondY - offsetY * secondX) / denominator
        let alongSecond = (offsetX * firstY - offsetY * firstX) / denominator
        guard (0...1).contains(alongFirst), (0...1).contains(alongSecond) else { return nil }
        return (alongFirst, alongSecond)
    }

    static func distance(_ first: Point, _ second: Point) -> Double {
        ((first.east - second.east) * (first.east - second.east)
            + (first.north - second.north) * (first.north - second.north)).squareRoot()
    }

    /// The point of an edge nearest `point`, and how far along it lies.
    private func nearest(on edge: Edge, to point: Point) -> (point: Point, distance: Double) {
        let start = nodes[edge.from], end = nodes[edge.to]
        let deltaX = end.east - start.east, deltaY = end.north - start.north
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        let along = lengthSquared > 0
            ? min(1, max(0, ((point.east - start.east) * deltaX + (point.north - start.north) * deltaY) / lengthSquared))
            : 0
        let foot = Point(east: start.east + deltaX * along, north: start.north + deltaY * along)
        return (foot, StreetNetwork.distance(foot, point))
    }

    /// Whether `mode` may take an edge, and from which end.
    private func allows(_ edge: Edge, from node: Int, mode: TravelMode) -> Bool {
        let street = streets[edge.street]
        guard street.allows(mode) else { return false }
        return !street.isOneWay(for: mode) || edge.from == node
    }

    /// The edge nearest a point that `mode` may use both ways, and the
    /// point on it: a route starts and ends on a street, not a roundabout.
    private func snap(_ point: Point, mode: TravelMode) -> (edge: Int, point: Point)? {
        var best: (edge: Int, point: Point, distance: Double)?
        for (index, edge) in edges.enumerated()
            where streets[edge.street].allows(mode) && !streets[edge.street].isOneWay(for: mode) {
            let candidate = nearest(on: edge, to: point)
            if best == nil || candidate.distance < best!.distance { best = (index, candidate.point, candidate.distance) }
        }
        guard let best, best.distance <= StreetNetwork.reach else { return nil }
        return (best.edge, best.point)
    }

    /// A way off the start more than this far round from the departing
    /// bearing goes back. As OSRM's `bearings` makes a route leave along
    /// the bearing, the sample leaves only by the end ahead, and turns back
    /// only when no way on reaches the destination.
    private static let reversal = 90.0

    func route(from origin: GeoCoordinate, to destination: GeoCoordinate, mode: TravelMode,
               departing bearing: Double? = nil) throws -> Route {
        let start = SampleTown.metres(of: origin), end = SampleTown.metres(of: destination)
        guard let from = snap(Point(east: start.east, north: start.north), mode: mode),
              let to = snap(Point(east: end.east, north: end.north), mode: mode) else {
            throw MapServiceError.noRoute("the sample's streets are all in \(SampleTown.name)")
        }
        let path = shortestPath(from: from, to: to, mode: mode, departing: bearing)
            ?? shortestPath(from: from, to: to, mode: mode, departing: nil)
            ?? Walk(points: [from.point, to.point], streets: [edges[from.edge].street], nodes: [nil, nil])
        return makeRoute(path, mode: mode)
    }

    /// A walk through the network: the points passed and the street each
    /// leg between two of them is on.
    private struct Walk {
        var points: [Point]
        var streets: [Int]
        /// The junction each point is, nil for the ends snapped onto a
        /// street.
        var nodes: [Int?]
    }

    private func shortestPath(from: (edge: Int, point: Point), to: (edge: Int, point: Point),
                              mode: TravelMode, departing bearing: Double?) -> Walk? {
        if from.edge == to.edge {
            return Walk(points: [from.point, to.point], streets: [edges[from.edge].street], nodes: [nil, nil])
        }
        // The start reaches either end of its edge, and the end is reached
        // from either end of its own: four ways in and out, through
        // Dijkstra over the junctions.
        let startEdge = edges[from.edge], endEdge = edges[to.edge]
        var distance = Array(repeating: Double.infinity, count: nodes.count)
        var previous = Array(repeating: (node: -1, edge: -1), count: nodes.count)
        var settled = Array(repeating: false, count: nodes.count)
        for end in [startEdge.from, startEdge.to] {
            distance[end] = StreetNetwork.distance(from.point, nodes[end])
            let way = (nodes[end].east - from.point.east, nodes[end].north - from.point.north)
            if let bearing, distance[end] > 0,
               abs(GeoMeasure.turn(from: bearing, to: StreetNetwork.bearing(way))) > StreetNetwork.reversal {
                distance[end] = .infinity
            }
        }
        while let current = (0..<nodes.count).filter({ !settled[$0] && distance[$0].isFinite })
            .min(by: { distance[$0] < distance[$1] }) {
            settled[current] = true
            for edgeIndex in adjacency[current] where allows(edges[edgeIndex], from: current, mode: mode) {
                let edge = edges[edgeIndex]
                let next = edge.from == current ? edge.to : edge.from
                let candidate = distance[current] + edge.length
                if candidate < distance[next] {
                    distance[next] = candidate
                    previous[next] = (current, edgeIndex)
                }
            }
        }
        let exits = [endEdge.from, endEdge.to].map { node in
            (node: node, total: distance[node] + StreetNetwork.distance(nodes[node], to.point))
        }
        guard let exit = exits.min(by: { $0.total < $1.total }), exit.total.isFinite else { return nil }
        var nodesBack: [Int] = [exit.node]
        var streetsBack: [Int] = [endEdge.street]
        var current = exit.node
        while previous[current].node >= 0 {
            streetsBack.append(edges[previous[current].edge].street)
            current = previous[current].node
            nodesBack.append(current)
        }
        streetsBack.append(startEdge.street)
        return Walk(points: [from.point] + nodesBack.reversed().map { nodes[$0] } + [to.point],
                    streets: streetsBack.reversed(), nodes: [nil] + nodesBack.reversed().map { $0 } + [nil])
    }

    private func makeRoute(_ walk: Walk, mode: TravelMode) -> Route {
        let speed = StreetNetwork.speed(mode)
        var steps: [RouteStep] = []
        var total = 0.0
        var legStart = 0
        func heading(_ leg: Int) -> (Double, Double) {
            let from = walk.points[leg], to = walk.points[leg + 1]
            return (to.east - from.east, to.north - from.north)
        }
        func coordinate(_ point: Point) -> GeoCoordinate { SampleTown.coordinate(east: point.east, north: point.north) }
        let legs = walk.points.count - 1
        var leg = 0
        while leg < legs {
            let street = walk.streets[leg]
            var length = 0.0
            var last = leg
            while last < legs, walk.streets[last] == street {
                length += StreetNetwork.distance(walk.points[last], walk.points[last + 1])
                last += 1
            }
            guard length > 0 else {
                leg = last
                continue
            }
            let name = streets[street].name
            var instruction: String
            var maneuver: Maneuver
            if streets[street].isRoundabout, !steps.isEmpty, last < legs {
                // OSRM's roundabout step: entered here, left at the exit
                // counted among the ring's junctions with another street,
                // the step after it the one that leaves.
                let exit = (leg + 1...last).filter { walk.nodes[$0].map { adjacency[$0].count > 2 } ?? false }.count
                let onto = streets[walk.streets[last]].name
                maneuver = Maneuver(kind: .roundabout, bearingBefore: StreetNetwork.bearing(heading(legStart)),
                                    bearingAfter: StreetNetwork.bearing(heading(leg)), exit: max(exit, 1))
                instruction = maneuver.instruction(onto: onto)
            } else if steps.isEmpty {
                instruction = "Head \(StreetNetwork.compass(heading(leg))) on \(name)"
                maneuver = Maneuver(kind: .depart, bearingAfter: StreetNetwork.bearing(heading(leg)))
            } else {
                maneuver = Maneuver.inferred(bearingBefore: StreetNetwork.bearing(heading(legStart)),
                                             bearingAfter: StreetNetwork.bearing(heading(leg)))
                if leg > 0, streets[walk.streets[leg - 1]].isRoundabout {
                    maneuver.kind = .exitRoundabout
                }
                instruction = maneuver.instruction(onto: name)
            }
            steps.append(RouteStep(instruction: instruction, distance: length, duration: length / speed,
                                   coordinate: coordinate(walk.points[leg]), name: name, maneuver: maneuver))
            total += length
            legStart = last - 1
            leg = last
        }
        let arrivingOn = legs > 0 ? StreetNetwork.bearing(heading(legs - 1)) : nil
        steps.append(RouteStep(instruction: "Arrive at the destination", distance: 0, duration: 0,
                               coordinate: coordinate(walk.points[walk.points.count - 1]),
                               maneuver: Maneuver(kind: .arrive, bearingBefore: arrivingOn)))
        return Route(coordinates: walk.points.map(coordinate), distance: total, duration: total / speed,
                     steps: steps)
    }

    /// A heading in metres east and north as a bearing, degrees clockwise
    /// from north.
    static func bearing(_ heading: (Double, Double)) -> Double {
        GeoMeasure.normalizedBearing(atan2(heading.0, heading.1) * Degrees.halfTurn / .pi)
    }

    /// The eight-point compass direction of a heading in metres east and
    /// north.
    static func compass(_ heading: (Double, Double)) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let degrees = atan2(heading.0, heading.1) * Degrees.halfTurn / .pi
        let sectorWidth = Degrees.fullTurn / Double(names.count)
        let bearing = (degrees + Degrees.fullTurn).truncatingRemainder(dividingBy: Degrees.fullTurn)
        return names[Int((bearing / sectorWidth).rounded()) % names.count]
    }

    /// Which way the second heading turns from the first: by the sign of
    /// their cross product, east and north being x and y, and straight on
    /// within `straightOn` degrees.
    static func turn(from first: (Double, Double), to second: (Double, Double)) -> String {
        let cross = first.0 * second.1 - first.1 * second.0
        let dot = first.0 * second.0 + first.1 * second.1
        let angle = abs(atan2(cross, dot)) * Degrees.halfTurn / .pi
        if angle < straightOn { return "Continue" }
        return cross > 0 ? "Turn left" : "Turn right"
    }
}
