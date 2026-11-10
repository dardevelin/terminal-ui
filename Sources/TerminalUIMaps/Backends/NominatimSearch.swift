import Foundation

/// Place search over OpenStreetMap's Nominatim
/// (nominatim.org/release-docs/latest/api/Search/).
///
/// The public instance's usage policy (operations.osmfoundation.org/
/// policies/nominatim/) asks for an identifying User-Agent on every request
/// and at most one request a second, so both are required here: the agent
/// is a parameter with no default, and requests are paced by a limiter
/// that by default allows one a second. Search on Enter, not per keystroke.
public struct NominatimSearch: PlaceSearch {
    public static let publicURL = URL(string: "https://nominatim.openstreetmap.org")!

    /// The policy's ceiling: one request a second.
    public static let minimumInterval: Duration = .seconds(1)

    /// The pacing every search of the process shares unless given its own,
    /// so two searches made apart still stay under the policy's ceiling
    /// together.
    public static let sharedPacing: any RequestPacing = RequestLimiter(interval: minimumInterval)

    /// How many results to ask for; Nominatim's own default is 10.
    public static let defaultLimit = 10

    private let baseURL: URL
    private let userAgent: String
    private let transport: any HTTPTransport
    private let pacing: any RequestPacing
    private let limit: Int

    public init(userAgent: String, baseURL: URL = NominatimSearch.publicURL,
                transport: any HTTPTransport = URLSessionTransport(),
                pacing: any RequestPacing = NominatimSearch.sharedPacing,
                limit: Int = NominatimSearch.defaultLimit) {
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.transport = transport
        self.pacing = pacing
        self.limit = limit
    }

    public func search(_ query: String, near region: GeoRect?) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = searchURL(for: trimmed, near: region) else {
            throw MapServiceError.invalidResponse("could not build a search URL")
        }
        try await pacing.waitForTurn()
        let request = HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
        let results = try await transport.json([NominatimResult].self, from: request)
        return results.compactMap(\.place)
    }

    /// `/search?q=…&format=jsonv2`, with the region as a `viewbox` to prefer
    /// (left, top, right, bottom, in degrees) but not bound to.
    func searchURL(for query: String, near region: GeoRect?) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "format", value: "jsonv2"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let region {
            let box = [region.west, region.north, region.east, region.south].map { String($0) }
            items.append(URLQueryItem(name: "viewbox", value: box.joined(separator: ",")))
        }
        components?.queryItems = items
        return components?.url
    }
}

/// One result of `format=jsonv2`. Nominatim sends coordinates as strings.
struct NominatimResult: Decodable {
    var lat: String
    var lon: String
    var name: String?
    var displayName: String?
    var category: String?
    var type: String?
    var osmType: String?
    var osmID: UInt64?

    enum CodingKeys: String, CodingKey {
        case lat, lon, name, category, type
        case displayName = "display_name"
        case osmType = "osm_type"
        case osmID = "osm_id"
    }

    /// The element `osm_type` and `osm_id` name.
    var element: OSMElement? {
        guard let osmType, let kind = OSMElement.Kind(rawValue: osmType), let osmID else { return nil }
        return OSMElement(kind, osmID)
    }

    var place: Place? {
        guard let latitude = Double(lat), let longitude = Double(lon) else { return nil }
        let firstPart = displayName?.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let title = (name?.isEmpty == false ? name : firstPart) ?? ""
        guard !title.isEmpty else { return nil }
        return Place(name: title, kind: type ?? category ?? "place",
                     coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                     address: displayName, identifier: element.map(PlaceIdentifier.openStreetMap))
    }
}
