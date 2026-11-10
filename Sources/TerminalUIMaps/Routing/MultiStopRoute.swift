extension RouteProvider {
    /// A leg at a time, joined: what a router that takes two places a
    /// request does for many — MapKit's `MKDirections` among them.
    public func route(through waypoints: [GeoCoordinate], mode: TravelMode) async throws -> Route {
        guard waypoints.count >= 2 else {
            throw MapServiceError.noRoute("a route needs a start and an end")
        }
        var legs: [Route] = []
        for (origin, destination) in zip(waypoints, waypoints.dropFirst()) {
            legs.append(try await route(from: origin, to: destination, mode: mode))
        }
        return Route.joining(legs)
    }

    /// The route through the waypoints, the bearing ignored.
    public func route(through waypoints: [GeoCoordinate], mode: TravelMode, departing bearing: Double?) async throws
        -> Route {
        try await route(through: waypoints, mode: mode)
    }
}

extension Route {
    /// Legs travelled one after another as one route. Each leg but the
    /// last ends on an arrival at a stop, as OSRM's multi-leg routes do
    /// (each `RouteLeg` ends in an `arrive` step); it is named for the stop
    /// so the traveller is not told they have arrived when they have not.
    public static func joining(_ legs: [Route]) -> Route {
        guard var joined = legs.first else { return Route(coordinates: [], distance: 0, duration: 0, steps: []) }
        joined.steps = joined.steps.renamingArrival(stop: legs.count > 1 ? 1 : nil)
        for (index, leg) in legs.enumerated().dropFirst() {
            var coordinates = leg.coordinates
            if let first = coordinates.first, let last = joined.coordinates.last, first == last {
                coordinates.removeFirst()
            }
            joined.coordinates += coordinates
            joined.distance += leg.distance
            joined.duration += leg.duration
            let stop = index < legs.count - 1 ? index + 1 : nil
            joined.steps += leg.steps.renamingArrival(stop: stop)
        }
        return joined
    }
}

extension [RouteStep] {
    /// The steps with their last, the arrival, named for stop `stop`,
    /// counted from 1 — or left as they are for the route's end.
    fileprivate func renamingArrival(stop: Int?) -> [RouteStep] {
        guard let stop, let last = indices.last else { return self }
        var renamed = self
        renamed[last].instruction = "Arrive at stop \(stop)"
        return renamed
    }
}
