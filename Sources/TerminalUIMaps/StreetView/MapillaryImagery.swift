import Foundation
import TerminalUIIO

/// Street-level photos from Mapillary through its Graph API v4
/// (mapillary.com/developer/api-documentation): a free client token, photos
/// CC BY-SA 4.0.
///
/// A search is `GET /images?bbox=…&fields=…`; an image's place in its
/// sequence comes from `GET /image_ids?sequence_id=…`, the sequence's
/// images in order; its photo is `thumb_1024_url`.
public struct MapillaryImagery: StreetImagery {
    /// Mapillary's Graph API, graph.mapillary.com.
    public static let defaultEndpoint = URL(string: "https://graph.mapillary.com")!
    /// The environment variable a token is read from by `init(environment:transport:userAgent:)`.
    static let tokenVariable = "MAPILLARY_ACCESS_TOKEN"

    /// "Mapillary".
    public let name = "Mapillary"
    private let token: String
    private let endpoint: URL
    private let transport: any HTTPTransport
    private let userAgent: String

    /// The fields asked of an image (Graph API v4, "Image" entity).
    static let fields = "id,computed_geometry,geometry,captured_at,compass_angle,computed_compass_angle,"
        + "thumb_1024_url,sequence,creator"
    static let searchLimit = 20

    /// Mapillary reached with a client `token`, sending `userAgent` with
    /// every request.
    public init(token: String, endpoint: URL = MapillaryImagery.defaultEndpoint,
                transport: any HTTPTransport = URLSessionTransport(), userAgent: String) {
        self.token = token
        self.endpoint = endpoint
        self.transport = transport
        self.userAgent = userAgent
    }

    /// Mapillary with the token in `tokenVariable`; throws
    /// ``StreetImageryError/missingToken(_:)`` when there is none.
    init(environment: [String: String] = ProcessInfo.processInfo.environment,
                transport: any HTTPTransport = URLSessionTransport(),
                userAgent: String) throws {
        guard let token = environment[Self.tokenVariable], !token.isEmpty else {
            throw StreetImageryError.missingToken(Self.tokenVariable)
        }
        self.init(token: token, transport: transport, userAgent: userAgent)
    }

    /// The images within `metres` of a coordinate, nearest first, from at
    /// most 20 the box around it holds.
    public func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage] {
        let box = coordinate.box(metres: metres)
        let response = try await transport.json(MapillaryList.self, from: request("images", [
            "bbox": [box.west, box.south, box.east, box.north].map { String($0) }.joined(separator: ","),
            "fields": Self.fields,
            "limit": String(Self.searchLimit),
        ]))
        return response.data.compactMap(\.image)
            .filter { $0.coordinate.metres(to: coordinate) <= metres }
            .sorted { $0.coordinate.metres(to: coordinate) < $1.coordinate.metres(to: coordinate) }
    }

    /// The images before and after `image` in its sequence; none for an
    /// image without one. `bearing` is not used.
    public func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours {
        guard let sequence = image.sequence else { return .none }
        let ids = try await transport.json(MapillaryIDList.self,
                                           from: request("image_ids", ["sequence_id": sequence])).data.map(\.id)
        guard let index = ids.firstIndex(of: image.id) else { return .none }
        async let previous = index > 0 ? self.image(ids[index - 1]) : nil
        async let next = index + 1 < ids.count ? self.image(ids[index + 1]) : nil
        return StreetImageNeighbours(previous: try await previous, next: try await next)
    }

    /// The image's 1024-pixel thumbnail, decoded; throws
    /// ``StreetImageryError/noPhoto`` when it has none.
    public func photo(of image: StreetImage) async throws -> ImageBuffer {
        guard let url = image.photoURL else { throw StreetImageryError.noPhoto }
        return try await transport.photo(at: url, userAgent: userAgent)
    }

    private func image(_ id: String) async throws -> StreetImage? {
        try await transport.json(MapillaryImage.self, from: request(id, ["fields": Self.fields])).image
    }

    /// A Graph API request. The token goes in the `Authorization` header,
    /// as the API accepts it (`OAuth <token>`), not in the URL, so it is
    /// never logged with one.
    private func request(_ path: String, _ query: [String: String]) throws -> HTTPRequest {
        var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw MapServiceError.invalidResponse("bad Mapillary URL") }
        return HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent, "Authorization": "OAuth \(token)"])
    }
}

struct MapillaryList: Decodable {
    var data: [MapillaryImage]
}

struct MapillaryIDList: Decodable {
    struct Entry: Decodable {
        var id: String
    }

    var data: [Entry]
}

struct MapillaryImage: Decodable {
    struct Point: Decodable {
        var coordinates: [Double]
    }

    struct Creator: Decodable {
        var username: String?
    }

    var id: String
    var computedGeometry: Point?
    var geometry: Point?
    /// Milliseconds since 1970.
    var capturedAt: Double?
    var compassAngle: Double?
    var computedCompassAngle: Double?
    var thumbnailURL: URL?
    var sequence: String?
    var creator: Creator?

    enum CodingKeys: String, CodingKey {
        case id, geometry, sequence, creator
        case computedGeometry = "computed_geometry"
        case capturedAt = "captured_at"
        case compassAngle = "compass_angle"
        case computedCompassAngle = "computed_compass_angle"
        case thumbnailURL = "thumb_1024_url"
    }

    private static let millisecondsPerSecond = 1_000.0
    /// GeoJSON (RFC 7946 §3.1.1) orders a position longitude first.
    private static let longitudeIndex = 0
    private static let latitudeIndex = 1

    var image: StreetImage? {
        guard let position = (computedGeometry ?? geometry)?.coordinates, position.count > Self.latitudeIndex else {
            return nil
        }
        return StreetImage(id: id,
                           coordinate: GeoCoordinate(latitude: position[Self.latitudeIndex],
                                                     longitude: position[Self.longitudeIndex]),
                           heading: computedCompassAngle ?? compassAngle,
                           captured: capturedAt.map { Date(timeIntervalSince1970: $0 / Self.millisecondsPerSecond) },
                           licence: "CC BY-SA 4.0",
                           attribution: creator?.username.map { "© \($0), Mapillary" } ?? "© Mapillary contributors",
                           sequence: sequence, photoURL: thumbnailURL)
    }
}
