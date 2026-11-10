import Foundation

/// Routing over an OSRM server's `route` service
/// (project-osrm.org/docs/v5.24.0/api/#route-service).
///
/// There is no default server. The project's demo server, ``demoURL``
/// (router.project-osrm.org), is for trying the API: its usage policy
/// allows at most a request a second, asks for an identifying User-Agent
/// and forbids heavy use, and it routes cars only whatever profile the URL
/// names. Walking and cycling need a server that loads those profiles, such
/// as routing.openstreetmap.de's per-profile instances, with
/// `supportedModes` saying which. Routes are drawn from OpenStreetMap data,
/// © OpenStreetMap contributors, ODbL.
public struct OSRMRoutes: RouteProvider {
    /// The OSRM project's demo server: cars only, for light use.
    public static let demoURL = URL(string: "https://router.project-osrm.org")!

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let userAgent: String
    private let supportedModes: Set<TravelMode>

    /// A router over the server at `baseURL`, naming the application
    /// `userAgent` on every request, that answers `supportedModes`.
    public init(baseURL: URL,
                transport: any HTTPTransport = URLSessionTransport(),
                userAgent: String,
                supportedModes: Set<TravelMode> = [.driving]) {
        self.baseURL = baseURL
        self.transport = transport
        self.userAgent = userAgent
        self.supportedModes = supportedModes
    }

    /// The route from `origin` to `destination` in one request, or an
    /// error for a mode the server is not said to support.
    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate,
                      mode: TravelMode) async throws -> Route {
        try await route(through: [origin, destination], mode: mode)
    }

    /// OSRM routes through every coordinate of a request in order, a leg
    /// between each two, in one call.
    public func route(through waypoints: [GeoCoordinate], mode: TravelMode) async throws -> Route {
        try await route(through: waypoints, mode: mode, departing: nil)
    }

    /// A bearing is OSRM's `bearings` on the first coordinate: the road it
    /// snaps to must run within ``bearingTolerance`` of it, so the route
    /// leaves the way the traveller is going.
    public func route(through waypoints: [GeoCoordinate], mode: TravelMode, departing bearing: Double?) async throws
        -> Route {
        guard supportedModes.contains(mode) else {
            throw MapServiceError.unsupported("this OSRM server does not route \(mode.rawValue)")
        }
        guard waypoints.count >= 2 else {
            throw MapServiceError.noRoute("a route needs a start and an end")
        }
        guard let url = routeURL(through: waypoints, mode: mode, departing: bearing) else {
            throw MapServiceError.invalidResponse("could not build a route URL")
        }
        let request = HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
        let response = try await transport.json(OSRMResponse.self, from: request)
        guard response.code == OSRMResponse.success, let route = response.routes?.first else {
            throw MapServiceError.noRoute(response.message ?? response.code)
        }
        return route.route
    }

    /// `/route/v1/{profile}/{lon},{lat};{lon},{lat}…` — OSRM orders a
    /// coordinate longitude first — with the full geometry as GeoJSON and
    /// turn-by-turn steps; with a bearing, `bearings={value},{range}` for
    /// the first coordinate and none for the rest (api docs, "General
    /// options": one entry a coordinate, empty for unconstrained).
    func routeURL(through waypoints: [GeoCoordinate], mode: TravelMode, departing bearing: Double? = nil) -> URL? {
        let profile: String = switch mode {
        case .driving: "driving"
        case .walking: "foot"
        case .cycling: "bike"
        }
        let points = waypoints.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        let path = baseURL.appendingPathComponent("route/v1/\(profile)/\(points)")
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "overview", value: "full"),
                     URLQueryItem(name: "geometries", value: "geojson"),
                     URLQueryItem(name: "steps", value: "true")]
        if let bearing {
            let first = "\(Int(GeoMeasure.normalizedBearing(bearing).rounded()) % Int(Degrees.fullTurn)),"
                + "\(Int(OSRMRoutes.bearingTolerance))"
            let rest = String(repeating: ";", count: waypoints.count - 1)
            items.append(URLQueryItem(name: "bearings", value: first + rest))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Degrees either side of a departing bearing OSRM may snap within: a
    /// right angle's half, so a road the traveller is on matches and the
    /// one across the junction does not.
    public static let bearingTolerance = 45.0
}

/// The parts of OSRM's route response a `Route` is made of.
struct OSRMResponse: Decodable {
    static let success = "Ok"

    var code: String
    var message: String?
    var routes: [OSRMRoute]?
}

struct OSRMRoute: Decodable {
    var distance: Double
    var duration: Double
    var geometry: OSRMLineString
    var legs: [OSRMLeg]

    /// Every leg's steps in turn. Each leg ends in an `arrive` step; all
    /// but the last are named for their stop, as ``Route/joining(_:)``
    /// names them.
    var route: Route {
        var steps: [RouteStep] = []
        for (index, leg) in legs.enumerated() {
            var legSteps = leg.steps.map(\.step)
            if index < legs.count - 1, let last = legSteps.indices.last {
                legSteps[last].instruction = "Arrive at stop \(index + 1)"
            }
            steps += legSteps
        }
        return Route(coordinates: geometry.coordinates.compactMap(OSRMLineString.coordinate),
                     distance: distance, duration: duration, steps: steps)
    }
}

/// A GeoJSON LineString (RFC 7946 §3.1.4): positions longitude first.
struct OSRMLineString: Decodable {
    var coordinates: [[Double]]

    static func coordinate(_ position: [Double]) -> GeoCoordinate? {
        guard position.count >= 2 else { return nil }
        return GeoCoordinate(latitude: position[1], longitude: position[0])
    }
}

struct OSRMLeg: Decodable {
    var steps: [OSRMStep]
}

struct OSRMStep: Decodable {
    var distance: Double
    var duration: Double
    var name: String?
    var maneuver: OSRMManeuver
    var intersections: [OSRMIntersection]?

    var step: RouteStep {
        let road = name.flatMap { $0.isEmpty ? nil : $0 }
        let model = maneuver.model
        return RouteStep(instruction: model.instruction(onto: road), distance: distance, duration: duration,
                         coordinate: OSRMLineString.coordinate(maneuver.location)
                             ?? GeoCoordinate(latitude: 0, longitude: 0),
                         name: road, maneuver: model, intersections: intersections?.compactMap(\.model))
    }
}

/// OSRM's intersection: where it is, the bearing of every road there, which
/// may be entered, and the indices of the ways in and out (api docs,
/// "Intersection object"). `in` is absent at the departure, `out` at the
/// arrival.
struct OSRMIntersection: Decodable {
    var location: [Double]
    var bearings: [Double]
    var entry: [Bool]?
    var inIndex: Int?
    var outIndex: Int?

    enum CodingKeys: String, CodingKey {
        case location, bearings, entry
        case inIndex = "in"
        case outIndex = "out"
    }

    var model: RouteIntersection? {
        guard let coordinate = OSRMLineString.coordinate(location) else { return nil }
        return RouteIntersection(coordinate: coordinate, bearings: bearings, entry: entry ?? [], inIndex: inIndex,
                                 outIndex: outIndex)
    }
}

/// OSRM's step maneuver: a type, a modifier and the bearings either side
/// of it (api docs, "StepManeuver object"). OSRM gives no sentence;
/// ``Maneuver`` makes one.
struct OSRMManeuver: Decodable {
    var type: String
    var modifier: String?
    var location: [Double]
    var bearingBefore: Double?
    var bearingAfter: Double?
    var exit: Int?

    enum CodingKeys: String, CodingKey {
        case type, modifier, location, exit
        case bearingBefore = "bearing_before"
        case bearingAfter = "bearing_after"
    }

    /// OSRM's docs say new types may appear and a client should treat one
    /// it does not know as a turn.
    var model: Maneuver {
        Maneuver(kind: Maneuver.Kind(rawValue: type) ?? .turn,
                 direction: modifier.flatMap(Maneuver.Direction.init(rawValue:)),
                 bearingBefore: bearingBefore, bearingAfter: bearingAfter, exit: exit)
    }
}
