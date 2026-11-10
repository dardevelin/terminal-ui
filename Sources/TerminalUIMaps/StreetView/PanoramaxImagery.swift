import Foundation
import TerminalUIIO

/// Street-level photos from Panoramax (panoramax.fr), the federated open
/// alternative to the proprietary services, through its STAC API: no key,
/// photos CC BY-SA 4.0 (some instances CC0), strongest in France.
///
/// A search is `GET /api/search?bbox=west,south,east,north`, a GeoJSON
/// FeatureCollection of STAC items; each item names its sequence as its
/// `collection`, its heading as `view:azimuth`, its photographer as
/// `geovisio:producer`, links its neighbours along the sequence as
/// `prev` and `next`, and serves its photo as the `thumb` asset (500 px
/// wide) and `sd` (2 048 px).
public struct PanoramaxImagery: StreetImagery {
    public static let defaultEndpoint = URL(string: "https://api.panoramax.xyz/api")!

    public let name = "Panoramax"
    private let endpoint: URL
    private let transport: any HTTPTransport
    private let userAgent: String

    /// How many items a search asks for: enough to find the nearest in a
    /// busy street, few enough to be a light request.
    static let searchLimit = 20

    public init(endpoint: URL = PanoramaxImagery.defaultEndpoint, transport: any HTTPTransport = URLSessionTransport(),
                userAgent: String = MapUserAgent.default) {
        self.endpoint = endpoint
        self.transport = transport
        self.userAgent = userAgent
    }

    public func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage] {
        let box = coordinate.box(metres: metres)
        var components = URLComponents(url: endpoint.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bbox", value: [box.west, box.south, box.east, box.north].map { String($0) }
                .joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(Self.searchLimit)),
        ]
        guard let url = components?.url else { throw MapServiceError.invalidResponse("bad Panoramax search URL") }
        let collection = try await transport.json(STACCollection.self, from: request(url))
        return collection.features.compactMap(\.image)
            .filter { $0.coordinate.metres(to: coordinate) <= metres }
            .sorted { $0.coordinate.metres(to: coordinate) < $1.coordinate.metres(to: coordinate) }
    }

    public func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours {
        guard let sequence = image.sequence else { return .none }
        let item = try await self.item(image.id, in: sequence)
        async let previous = linked(item, relation: "prev", in: sequence)
        async let next = linked(item, relation: "next", in: sequence)
        return StreetImageNeighbours(previous: try await previous, next: try await next)
    }

    public func photo(of image: StreetImage) async throws -> ImageBuffer {
        guard let url = image.photoURL else { throw StreetImageryError.noPhoto }
        return try await transport.photo(at: url, userAgent: userAgent)
    }

    private func item(_ id: String, in sequence: String) async throws -> STACItem {
        let url = endpoint.appendingPathComponent("collections").appendingPathComponent(sequence)
            .appendingPathComponent("items").appendingPathComponent(id)
        return try await transport.json(STACItem.self, from: request(url))
    }

    private func linked(_ item: STACItem, relation: String, in sequence: String) async throws -> StreetImage? {
        guard let id = item.links?.first(where: { $0.rel == relation })?.id else { return nil }
        return try await self.item(id, in: sequence).image
    }

    private func request(_ url: URL) -> HTTPRequest {
        HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
    }
}

/// The parts of a STAC FeatureCollection and Item (stacspec.org, 1.0.0)
/// and Panoramax's properties that a street image needs.
struct STACCollection: Decodable {
    var features: [STACItem]
}

struct STACItem: Decodable {
    struct Geometry: Decodable {
        var coordinates: [Double]
    }

    struct Asset: Decodable {
        var href: URL
    }

    struct Link: Decodable {
        var rel: String
        var id: String?
    }

    struct Provider: Decodable {
        var name: String
    }

    struct Properties: Decodable {
        var datetime: String?
        var license: String?
        var azimuth: Double?
        var producer: String?

        enum CodingKeys: String, CodingKey {
            case datetime
            case license
            case azimuth = "view:azimuth"
            case producer = "geovisio:producer"
        }
    }

    var id: String
    var collection: String?
    var geometry: Geometry?
    var properties: Properties?
    var assets: [String: Asset]?
    var links: [Link]?
    var providers: [Provider]?

    /// GeoJSON (RFC 7946 §3.1.1) orders a position longitude first.
    private static let longitudeIndex = 0
    private static let latitudeIndex = 1

    var image: StreetImage? {
        guard let position = geometry?.coordinates, position.count > Self.latitudeIndex else { return nil }
        let photographer = properties?.producer ?? providers?.first?.name
        return StreetImage(id: id,
                           coordinate: GeoCoordinate(latitude: position[Self.latitudeIndex],
                                                     longitude: position[Self.longitudeIndex]),
                           heading: properties?.azimuth,
                           captured: properties?.datetime.flatMap(STACItem.date),
                           licence: STACItem.licenceName(properties?.license),
                           attribution: photographer.map { "© \($0), Panoramax" } ?? "Panoramax contributors",
                           sequence: collection,
                           photoURL: (assets?["thumb"] ?? assets?["sd"])?.href)
    }

    /// An SPDX identifier as people write it: "CC-BY-SA-4.0" as "CC BY-SA 4.0".
    static func licenceName(_ spdx: String?) -> String {
        guard let spdx, !spdx.isEmpty else { return "CC BY-SA 4.0" }
        guard spdx.hasPrefix("CC-") else { return spdx }
        var parts = spdx.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return spdx }
        let version = parts.removeLast()
        return "CC \(parts.dropFirst().joined(separator: "-")) \(version)"
    }

    /// RFC 3339, with or without fractional seconds, as STAC's `datetime`.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
