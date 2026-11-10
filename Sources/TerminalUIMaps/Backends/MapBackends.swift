import TerminalUIIO

/// One tile of a source, as a ``MapTileSource`` answers it: vector
/// features, a picture, or heights.
///
/// A source of its own makes one from what it fetched or drew:
///
/// ```swift
/// func tile(_ id: TileID) async throws -> MapTile? {
///     guard let bytes = try await fetch(id) else { return nil }
///     return try MapTile.vector(decoding: bytes)
/// }
/// ```
public struct MapTile: Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case vector(VectorTile)
        /// Pixels covering exactly the tile's square, north up.
        case raster(ImageBuffer)
        /// Heights over the tile's square, north up: a terrain source's tile.
        case elevation(ElevationTile)
    }

    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    static func vector(_ tile: VectorTile) -> MapTile { MapTile(.vector(tile)) }

    static func elevation(_ tile: ElevationTile) -> MapTile { MapTile(.elevation(tile)) }

    /// A Mapbox Vector Tile (github.com/mapbox/vector-tile-spec, 2.1) in the
    /// OpenMapTiles schema, gzip-compressed or not, as a vector source
    /// serves it.
    public static func vector(decoding bytes: [UInt8]) throws -> MapTile {
        .vector(try VectorTileDecoder.decode(bytes))
    }

    /// A picture covering exactly the tile's square, north up: imagery.
    public static func raster(_ image: ImageBuffer) -> MapTile { MapTile(.raster(image)) }

    /// Heights in Mapzen's Terrarium encoding — metres as red × 256 +
    /// green + blue ÷ 256 − 32768 — covering the tile's square, north up:
    /// a terrain source's tile.
    public static func terrarium(_ image: ImageBuffer) -> MapTile {
        .elevation(Terrarium.elevation(of: image))
    }
}

/// What a tile source offers, and whose data it is.
public struct TileSourceInfo: Sendable, Equatable {
    public var name: String
    /// The credit the data's licence requires on screen, as plain text.
    public var attribution: String
    /// The zooms the source has tiles for; deeper zooms over-zoom the last.
    public var zoomRange: ClosedRange<Int>
    /// Where the source has data.
    public var bounds: GeoRect
    /// How its vector tiles' feature ids name the map data's elements.
    public var featureIdentifiers: FeatureIdentifiers

    /// The whole Web Mercator world.
    public static let world = GeoRect(south: -WebMercator.maximumLatitude, west: -Degrees.halfTurn,
                                      north: WebMercator.maximumLatitude, east: Degrees.halfTurn)

    public init(name: String, attribution: String, zoomRange: ClosedRange<Int>,
                bounds: GeoRect = TileSourceInfo.world, featureIdentifiers: FeatureIdentifiers = .opaque) {
        self.name = name
        self.attribution = attribution
        self.zoomRange = zoomRange
        self.bounds = bounds
        self.featureIdentifiers = featureIdentifiers
    }
}

/// Answers "what is the basemap of this tile?".
public protocol MapTileSource: Sendable {
    /// The source's name, zooms and attribution. A network source may
    /// fetch them the first time.
    func info() async throws -> TileSourceInfo

    /// The tile, or nil where the source has none (beyond its bounds or
    /// zooms, or a tile of empty sea it does not serve).
    func tile(_ id: TileID) async throws -> MapTile?
}

/// A source of vector tiles as encoded bytes — what an offline pack stores,
/// as fetched.
public protocol EncodedTileSource: MapTileSource {
    /// The tile's bytes as the source holds them, gzip-compressed or not,
    /// or nil where it has none.
    func tileData(_ id: TileID) async throws -> [UInt8]?
}

extension EncodedTileSource {
    public func tile(_ id: TileID) async throws -> MapTile? {
        guard let data = try await tileData(id) else { return nil }
        return try .vector(decoding: data)
    }
}

/// A place a search found.
public struct Place: Sendable, Hashable, Codable {
    public var name: String
    /// What it is, in the source's own words: "cafe", "town", "residential".
    public var kind: String
    public var coordinate: GeoCoordinate
    /// The address or description to show under the name, if any.
    public var address: String?
    /// What the backend it came from knows it by, where it says: what a
    /// ``PlaceDetails`` backend looks it up with.
    public var identifier: PlaceIdentifier?

    public init(name: String, kind: String, coordinate: GeoCoordinate, address: String? = nil,
                identifier: PlaceIdentifier? = nil) {
        self.name = name
        self.kind = kind
        self.coordinate = coordinate
        self.address = address
        self.identifier = identifier
    }
}

/// Answers "where is this?".
public protocol PlaceSearch: Sendable {
    /// Places matching `query`, best first. `region` is the area in view:
    /// a hint to prefer what is near it, not a filter.
    func search(_ query: String, near region: GeoRect?) async throws -> [Place]
}

/// How a route is travelled.
public enum TravelMode: String, Sendable, Hashable, Codable, CaseIterable {
    case driving
    case walking
    case cycling
}

/// The roads meeting where a route passes through a junction, as a router
/// that knows them says: OSRM's `Intersection` object
/// (project-osrm.org/docs/v5.24.0/api/#intersection-object).
public struct RouteIntersection: Sendable, Hashable, Codable {
    public var coordinate: GeoCoordinate
    /// Each road's bearing leaving the junction, degrees clockwise from
    /// north, the way in among them.
    public var bearings: [Double]
    /// Whether each road may be entered from the junction.
    public var entry: [Bool]
    /// Which of `bearings` the route arrives along; nil at the departure.
    public var inIndex: Int?
    /// Which it leaves along; nil at the arrival.
    public var outIndex: Int?

    public init(coordinate: GeoCoordinate, bearings: [Double], entry: [Bool] = [], inIndex: Int? = nil,
                outIndex: Int? = nil) {
        self.coordinate = coordinate
        self.bearings = bearings
        self.entry = entry
        self.inIndex = inIndex
        self.outIndex = outIndex
    }
}

/// One instruction of a route.
public struct RouteStep: Sendable, Hashable, Codable {
    /// What to do, as a sentence: "Turn left onto Mill Road".
    public var instruction: String
    /// The length of the step, in metres.
    public var distance: Double
    /// The expected time the step takes, in seconds.
    public var duration: Double
    /// Where the step begins.
    public var coordinate: GeoCoordinate
    /// The road the step travels along, when the router names it.
    public var name: String?
    /// What to do where the step begins, when the router says; a
    /// ``NavigationSession`` infers it from the route's shape otherwise.
    public var maneuver: Maneuver?
    /// The junctions the step passes, its manoeuvre's first, when the
    /// router says (OSRM does; MapKit and the sample do not).
    public var intersections: [RouteIntersection]?

    public init(instruction: String, distance: Double, duration: Double, coordinate: GeoCoordinate,
                name: String? = nil, maneuver: Maneuver? = nil, intersections: [RouteIntersection]? = nil) {
        self.instruction = instruction
        self.distance = distance
        self.duration = duration
        self.coordinate = coordinate
        self.name = name
        self.maneuver = maneuver
        self.intersections = intersections
    }
}

/// A route between two places.
public struct Route: Sendable, Hashable, Codable {
    /// The path, start to end.
    public var coordinates: [GeoCoordinate]
    /// The length, in metres.
    public var distance: Double
    /// The expected travel time, in seconds.
    public var duration: Double
    public var steps: [RouteStep]

    public init(coordinates: [GeoCoordinate], distance: Double, duration: Double, steps: [RouteStep]) {
        self.coordinates = coordinates
        self.distance = distance
        self.duration = duration
        self.steps = steps
    }
}

/// Answers "how do I get from here to there?".
public protocol RouteProvider: Sendable {
    func route(from origin: GeoCoordinate, to destination: GeoCoordinate, mode: TravelMode) async throws -> Route

    /// A route through every waypoint in order, the first its start and the
    /// last its end. A router that takes several stops in one request
    /// answers it so; the default asks for each leg and joins them
    /// (``Route/joining(_:)``).
    func route(through waypoints: [GeoCoordinate], mode: TravelMode) async throws -> Route

    /// The same, leaving the first waypoint along `bearing`, degrees
    /// clockwise from north: a reroute for a traveller on the move, who is
    /// not to be sent back the way they came while a way on is near. A
    /// router that cannot take a heading ignores it — MapKit's
    /// `MKDirections.Request` has none — and the default does.
    func route(through waypoints: [GeoCoordinate], mode: TravelMode, departing bearing: Double?) async throws
        -> Route
}

extension TileID {
    /// The coordinate of a point of this tile's layer of `extent`.
    func coordinate(of point: TilePoint, extent: Int) -> GeoCoordinate {
        let count = Double(TileID.tilesPerSide(atZoom: zoom))
        let scale = Double(extent)
        return WebMercator.unproject(WorldPoint(x: (Double(x) + Double(point.x) / scale) / count,
                                                y: (Double(y) + Double(point.y) / scale) / count))
    }

    /// The point of this tile's layer of `extent` at a coordinate, which may
    /// lie outside the tile. Rounded to the nearest unit and clamped to the
    /// 32-bit range a vector tile can hold.
    func tilePoint(for coordinate: GeoCoordinate, extent: Int) -> TilePoint {
        let world = WebMercator.project(coordinate)
        let count = Double(TileID.tilesPerSide(atZoom: zoom))
        let scale = Double(extent)
        return TilePoint(x: TileID.clampedCoordinate((world.x * count - Double(x)) * scale),
                         y: TileID.clampedCoordinate((world.y * count - Double(y)) * scale))
    }

    private static func clampedCoordinate(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}
