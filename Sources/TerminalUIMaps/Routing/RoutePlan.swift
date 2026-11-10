/// A stop on a planned route.
public struct Waypoint: Sendable, Hashable, Codable, Identifiable {
    /// Unique within its plan, and kept as the stop moves in it.
    public var id: Int
    public var name: String
    public var coordinate: GeoCoordinate

    public init(id: Int, name: String, coordinate: GeoCoordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

/// The stops of a route being marked, in the order they are visited: the
/// first the start, the last the destination. A value, edited by the
/// panel and the map alike, and routed with ``RouteProvider/route(through:mode:)``.
public struct RoutePlan: Sendable, Hashable, Codable {
    public private(set) var waypoints: [Waypoint] = []
    public var mode: TravelMode
    private var nextID = 0

    public init(mode: TravelMode = .driving) {
        self.mode = mode
    }

    /// A plan through these places, in order.
    public init(places: [Place], mode: TravelMode = .driving) {
        self.init(mode: mode)
        for place in places { append(place.name, at: place.coordinate) }
    }

    /// Whether there is a start and an end to route between.
    public var isRoutable: Bool { waypoints.count >= 2 }

    public var coordinates: [GeoCoordinate] { waypoints.map(\.coordinate) }

    /// Add a stop at the end; returns its id.
    @discardableResult
    public mutating func append(_ name: String, at coordinate: GeoCoordinate) -> Int {
        insert(name, at: coordinate, before: waypoints.count)
    }

    /// Add a stop before the one at `index`, held to the plan's ends;
    /// returns its id.
    @discardableResult
    public mutating func insert(_ name: String, at coordinate: GeoCoordinate, before index: Int) -> Int {
        let id = nextID
        nextID += 1
        let position = min(max(index, 0), waypoints.count)
        waypoints.insert(Waypoint(id: id, name: name, coordinate: coordinate), at: position)
        return id
    }

    /// Remove the stop with `id`; nothing happens for an id not in the plan.
    public mutating func remove(_ id: Int) {
        waypoints.removeAll { $0.id == id }
    }

    /// Move the stop with `id` by `offset` places, held to the plan's ends.
    public mutating func move(_ id: Int, by offset: Int) {
        guard let from = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + offset, 0), waypoints.count - 1)
        guard to != from else { return }
        let waypoint = waypoints.remove(at: from)
        waypoints.insert(waypoint, at: to)
    }

    /// Reverse the order: the destination becomes the start.
    public mutating func reverse() {
        waypoints.reverse()
    }

    public mutating func removeAll() {
        waypoints.removeAll()
    }

    /// The plan from a stop on: what is left to visit once the traveller
    /// has passed the stops before `index`, with `start` — where they are —
    /// first. A reroute asks for this.
    public func remaining(from start: GeoCoordinate, after passed: Int) -> [GeoCoordinate] {
        [start] + waypoints.dropFirst(max(passed + 1, 1)).map(\.coordinate)
    }
}
