import Foundation

/// A point of a GPX file: a waypoint, a route point or a track point, which
/// GPX 1.1 gives one type, `wptType`.
public struct GPXPoint: Sendable, Hashable {
    public var coordinate: GeoCoordinate
    /// Metres above mean sea level.
    public var elevation: Double?
    public var time: Date?
    public var name: String?
    public var description: String?
    /// Horizontal dilution of precision, as the receiver reported it.
    public var horizontalDilution: Double?

    public init(coordinate: GeoCoordinate, elevation: Double? = nil, time: Date? = nil, name: String? = nil,
                description: String? = nil, horizontalDilution: Double? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.time = time
        self.name = name
        self.description = description
        self.horizontalDilution = horizontalDilution
    }
}

/// A planned route: its points are the stops, not the road between them.
public struct GPXRoute: Sendable, Hashable {
    public var name: String?
    /// GPX's free-form `type`: what the route is travelled by, as
    /// ``TravelMode/init(gpxType:)`` reads it.
    public var type: String?
    public var points: [GPXPoint]

    public init(name: String? = nil, type: String? = nil, points: [GPXPoint]) {
        self.name = name
        self.type = type
        self.points = points
    }
}

/// A recorded track: where a traveller went, in segments broken where the
/// recording was.
public struct GPXTrack: Sendable, Hashable {
    public var name: String?
    /// GPX's free-form `type`.
    public var type: String?
    public var segments: [[GPXPoint]]

    public init(name: String? = nil, type: String? = nil, segments: [[GPXPoint]]) {
        self.name = name
        self.type = type
        self.segments = segments
    }

    /// Every point of every segment, in order.
    public var points: [GPXPoint] { segments.flatMap { $0 } }
}

/// A GPX 1.1 document (topografix.com/GPX/1/1, schema gpx.xsd): waypoints,
/// routes and tracks, read and written as the schema orders them.
///
/// ```swift
/// let document = try GPXDocument(contentsOf: url)
/// let plan = RoutePlan(gpx: document.routes[0])
/// try GPXDocument(routes: [GPXRoute(plan)]).write(to: url)
/// ```
public struct GPXDocument: Sendable, Hashable {
    public var name: String?
    public var waypoints: [GPXPoint]
    public var routes: [GPXRoute]
    public var tracks: [GPXTrack]
    /// The program that wrote the file, which GPX 1.1 requires.
    public var creator: String

    public static let namespace = "http://www.topografix.com/GPX/1/1"
    public static let version = "1.1"
    public static let defaultCreator = "TerminalUIMaps"

    public init(name: String? = nil, waypoints: [GPXPoint] = [], routes: [GPXRoute] = [], tracks: [GPXTrack] = [],
                creator: String = GPXDocument.defaultCreator) {
        self.name = name
        self.waypoints = waypoints
        self.routes = routes
        self.tracks = tracks
        self.creator = creator
    }

    // MARK: - Reading

    /// Read a GPX document. GPX 1.0 files read too: the elements this
    /// reads have the same names in both.
    public init(xml text: String) throws {
        let root = try XMLReader.parse(text)
        guard root.name == "gpx" else { throw GPXError.notGPX(root.name) }
        self.init(name: root.child("metadata")?.childText("name"),
                  waypoints: try root.children("wpt").map(GPXDocument.point),
                  routes: try root.children("rte").map { route in
                      GPXRoute(name: route.childText("name"), type: route.childText("type"),
                               points: try route.children("rtept").map(GPXDocument.point))
                  },
                  tracks: try root.children("trk").map { track in
                      GPXTrack(name: track.childText("name"), type: track.childText("type"),
                               segments: try track.children("trkseg").map { try $0.children("trkpt").map(GPXDocument.point) })
                  },
                  creator: root.attributes["creator"] ?? GPXDocument.defaultCreator)
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(xml: String(decoding: data, as: UTF8.self))
    }

    private static func point(_ node: XMLNode) throws -> GPXPoint {
        guard let latitudeText = node.attributes["lat"], let longitudeText = node.attributes["lon"],
              let latitude = Double(latitudeText.trimmingXMLWhitespace()),
              let longitude = Double(longitudeText.trimmingXMLWhitespace()),
              (-Degrees.quarterTurn...Degrees.quarterTurn).contains(latitude),
              (-Degrees.halfTurn...Degrees.halfTurn).contains(longitude) else {
            throw GPXError.badPoint(node.name, node.attributes)
        }
        return GPXPoint(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                        elevation: node.childText("ele").flatMap(Double.init),
                        time: node.childText("time").flatMap(XSDDateTime.parse),
                        name: node.childText("name"),
                        description: node.childText("desc"),
                        horizontalDilution: node.childText("hdop").flatMap(Double.init))
    }

    // MARK: - Writing

    /// The document as GPX 1.1 text, each element in the order the schema's
    /// sequences require: `metadata`, `wpt`, `rte`, `trk`; in a point
    /// `ele`, `time`, `name`, `desc`, `hdop`; in a route or track `name`
    /// and `type` before its points.
    public var xml: String {
        var writer = XMLWriter()
        writer.start("gpx", [("version", GPXDocument.version), ("creator", creator),
                             ("xmlns", GPXDocument.namespace)])
        if let name {
            writer.start("metadata")
            writer.element("name", text: name)
            writer.end()
        }
        for waypoint in waypoints { GPXDocument.write(waypoint, as: "wpt", into: &writer) }
        for route in routes {
            writer.start("rte")
            if let name = route.name { writer.element("name", text: name) }
            if let type = route.type { writer.element("type", text: type) }
            for point in route.points { GPXDocument.write(point, as: "rtept", into: &writer) }
            writer.end()
        }
        for track in tracks {
            writer.start("trk")
            if let name = track.name { writer.element("name", text: name) }
            if let type = track.type { writer.element("type", text: type) }
            for segment in track.segments {
                writer.start("trkseg")
                for point in segment { GPXDocument.write(point, as: "trkpt", into: &writer) }
                writer.end()
            }
            writer.end()
        }
        writer.end()
        return writer.output
    }

    public func write(to url: URL) throws {
        try Data(xml.utf8).write(to: url, options: .atomic)
    }

    private static func write(_ point: GPXPoint, as element: String, into writer: inout XMLWriter) {
        let attributes = [("lat", number(point.coordinate.latitude)), ("lon", number(point.coordinate.longitude))]
        let hasChildren = point.elevation != nil || point.time != nil || point.name != nil
            || point.description != nil || point.horizontalDilution != nil
        guard hasChildren else {
            writer.empty(element, attributes)
            return
        }
        writer.start(element, attributes)
        if let elevation = point.elevation { writer.element("ele", text: number(elevation)) }
        if let time = point.time { writer.element("time", text: XSDDateTime.format(time)) }
        if let name = point.name { writer.element("name", text: name) }
        if let description = point.description { writer.element("desc", text: description) }
        if let dilution = point.horizontalDilution { writer.element("hdop", text: number(dilution)) }
        writer.end()
    }

    /// A decimal as `xsd:decimal` has it: no exponent, which Swift's
    /// description of a small or large double would use. Seven places of a
    /// degree are a centimetre on the ground.
    static func number(_ value: Double) -> String {
        String(format: "%.\(decimalPlaces)f", value).trimmingTrailingZeros()
    }

    private static let decimalPlaces = 7
}

/// Why a file is not GPX this can read.
public enum GPXError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The root element is not `gpx`.
    case notGPX(String)
    /// A point without a latitude and longitude in range.
    case badPoint(String, [String: String])

    public var description: String {
        switch self {
        case .notGPX(let root): "not a GPX file: its root element is <\(root)>"
        case .badPoint(let element, let attributes): "a <\(element)> has no valid lat and lon: \(attributes)"
        }
    }
}

extension TravelMode {
    /// The mode a GPX `type` names, in the words GPX writers use for it —
    /// Garmin's and Strava's "cycling", "biking", "ride"; "walking",
    /// "hiking", "running"; "driving" — or nil for one it does not know.
    public init?(gpxType: String) {
        switch gpxType.trimmingXMLWhitespace().lowercased() {
        case "driving", "car", "drive", "motorcar": self = .driving
        case "cycling", "biking", "bike", "bicycle", "ride", "road_biking", "mountain_biking": self = .cycling
        case "walking", "hiking", "running", "foot", "walk", "run": self = .walking
        default: return nil
        }
    }

    /// The word written as a GPX route's `type`.
    public var gpxType: String { rawValue }
}

extension RoutePlan {
    /// A plan of a GPX route's points, named as the file names them, in
    /// the mode its `type` names, else `mode`.
    public init(gpx route: GPXRoute, mode: TravelMode = .driving) {
        self.init(mode: route.type.flatMap(TravelMode.init(gpxType:)) ?? mode)
        for (index, point) in route.points.enumerated() {
            append(point.name ?? "Stop \(index + 1)", at: point.coordinate)
        }
    }
}

extension GPXRoute {
    /// The plan's stops as a GPX route.
    public init(_ plan: RoutePlan, name: String? = nil) {
        self.init(name: name, type: plan.mode == .driving ? nil : plan.mode.gpxType,
                  points: plan.waypoints.map { GPXPoint(coordinate: $0.coordinate, name: $0.name) })
    }
}

extension Degrees {
    static let quarterTurn = 90.0
}

extension String {
    /// A fixed-point number without the zeros after its last significant
    /// place, nor a point with nothing after it.
    func trimmingTrailingZeros() -> String {
        guard contains(".") else { return self }
        var trimmed = self
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed == "-0" ? "0" : trimmed
    }
}
