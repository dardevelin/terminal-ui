import Foundation

/// OpenStreetMap tags read as a place's details, the keys as the wiki
/// documents them (wiki.openstreetmap.org/wiki/Map_features): `phone` or
/// `contact:phone`, `website`, `contact:website` or `url`, `cuisine` as a
/// `;`-separated list, `wheelchair`, `opening_hours`, and the `addr:*`
/// address keys.
enum OSMTags {
    /// The keys that say what a place is, in the order a card prefers them.
    static let categoryKeys = ["amenity", "shop", "tourism", "leisure", "healthcare", "office", "craft", "historic"]
    static let phoneKeys = ["phone", "contact:phone"]
    static let websiteKeys = ["website", "contact:website", "url"]
    static let listSeparator: Character = ";"

    static func information(name: String, tags: [String: String], address: PostalAddress? = nil) -> PlaceInformation {
        func first(_ keys: [String]) -> String? {
            keys.lazy.compactMap { tags[$0]?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        let category = first(categoryKeys).map(readable)
        let cuisine = (tags["cuisine"] ?? "").split(separator: listSeparator)
            .map { readable($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        let tagged = PostalAddress(houseNumber: tags["addr:housenumber"], street: tags["addr:street"],
                                   postcode: tags["addr:postcode"], city: tags["addr:city"],
                                   country: tags["addr:country"])
        return PlaceInformation(
            name: tags["name"] ?? name, category: category,
            address: address ?? (tagged.line == nil ? nil : tagged),
            openingHours: tags["opening_hours"].map(OpeningHours.init),
            phone: first(phoneKeys),
            website: first(websiteKeys).flatMap(URL.init(string:)),
            cuisine: cuisine,
            wheelchair: tags["wheelchair"].flatMap(WheelchairAccess.init(rawValue:)))
    }

    /// `coffee_shop` as "coffee shop".
    static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
    }
}

/// A place's details from Nominatim's `lookup`
/// (nominatim.org/release-docs/latest/api/Lookup/), by the place's
/// OpenStreetMap element, with its extra tags and address.
///
/// Every request shares Nominatim's pacing with ``NominatimSearch`` unless
/// given its own: the usage policy's one request a second counts lookups
/// and searches together. A place with no OpenStreetMap element, such as
/// one from Apple's search, is not looked up.
public struct NominatimPlaceDetails: PlaceDetails {
    public let sourceName = "OpenStreetMap"
    public let fields = Set(PlaceDetailField.allCases)

    private let baseURL: URL
    private let userAgent: String
    private let transport: any HTTPTransport
    private let pacing: any RequestPacing

    public init(userAgent: String, baseURL: URL = NominatimSearch.publicURL,
                transport: any HTTPTransport = URLSessionTransport(),
                pacing: any RequestPacing = NominatimSearch.sharedPacing) {
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.transport = transport
        self.pacing = pacing
    }

    public func details(for place: Place) async throws -> PlaceInformation? {
        guard let element = place.identifier?.osmElement, let url = lookupURL(for: element) else { return nil }
        try await pacing.waitForTurn()
        let request = HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
        let results = try await transport.json([NominatimLookupResult].self, from: request)
        return results.first.map { $0.information(fallbackName: place.name) }
    }

    /// `/lookup?osm_ids=N…&format=jsonv2&extratags=1&namedetails=1&addressdetails=1`.
    func lookupURL(for element: OSMElement) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("lookup"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "osm_ids", value: element.nominatimID),
                                  URLQueryItem(name: "format", value: "jsonv2"),
                                  URLQueryItem(name: "extratags", value: "1"),
                                  URLQueryItem(name: "namedetails", value: "1"),
                                  URLQueryItem(name: "addressdetails", value: "1")]
        return components?.url
    }
}

/// One result of `lookup` in `format=jsonv2`.
struct NominatimLookupResult: Decodable {
    var name: String?
    var type: String?
    var address: [String: String]?
    var extratags: [String: String]?

    /// Nominatim's `address` keys for the place a street is in, the most
    /// specific first (nominatim.org/release-docs/latest/api/Output/,
    /// "Addressdetails").
    static let townKeys = ["city", "town", "village", "hamlet", "municipality"]

    func information(fallbackName: String) -> PlaceInformation {
        var postal: PostalAddress?
        if let address {
            let parts = PostalAddress(houseNumber: address["house_number"], street: address["road"],
                                      postcode: address["postcode"],
                                      city: Self.townKeys.lazy.compactMap { address[$0] }.first,
                                      country: address["country"])
            postal = parts.line == nil ? nil : parts
        }
        // The main tag is not among the extra ones: `type` is its value.
        var information = OSMTags.information(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
                                              tags: extratags ?? [:], address: postal)
        information.category = type.map(OSMTags.readable) ?? information.category
        return information
    }
}

/// A place's details from the Overpass API (wiki.openstreetmap.org/wiki/
/// Overpass_API), by the place's OpenStreetMap element: its tags as they
/// are now, which Nominatim's copy may lag.
///
/// The public instance asks for no more than about 10 000 queries a day
/// and answers 429 when a client is going too fast, or 504 when the server
/// is too busy (dev.overpass-api.de/overpass-doc/en/preface/commons.html).
/// Either is waited out and tried again, each wait twice the last, a few
/// times before giving up. Requests share a pacing that by default allows
/// one a second.
public struct OverpassPlaceDetails: PlaceDetails {
    public static let publicURL = URL(string: "https://overpass-api.de/api/interpreter")!

    /// One request a second: the slot rate a client of the public
    /// instance is given.
    public static let sharedPacing: any RequestPacing = RequestLimiter(interval: .seconds(1))

    /// The statuses Overpass answers a busy client with: too many requests
    /// (RFC 6585 §4) and gateway timeout, which it sends when its
    /// dispatcher has no slot.
    static let busyStatuses: Set<Int> = [429, 504]

    /// The waits before each retry, doubling.
    public static let defaultBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Overpass QL's own timeout for a query of one element, in seconds.
    static let queryTimeout = 25

    public let sourceName = "OpenStreetMap (Overpass)"
    public let fields = Set(PlaceDetailField.allCases)

    private let baseURL: URL
    private let userAgent: String
    private let transport: any HTTPTransport
    private let pacing: any RequestPacing
    private let backoff: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameter sleep: how a wait is waited: the task's own sleep, which
    ///   suspends and holds no thread; a test passes one that records it.
    public init(userAgent: String, baseURL: URL = OverpassPlaceDetails.publicURL,
                transport: any HTTPTransport = URLSessionTransport(),
                pacing: any RequestPacing = OverpassPlaceDetails.sharedPacing,
                backoff: [Duration] = OverpassPlaceDetails.defaultBackoff,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.userAgent = userAgent
        self.baseURL = baseURL
        self.transport = transport
        self.pacing = pacing
        self.backoff = backoff
        self.sleep = sleep
    }

    public func details(for place: Place) async throws -> PlaceInformation? {
        guard let element = place.identifier?.osmElement, let url = queryURL(for: element) else { return nil }
        let request = HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
        var waits = backoff.makeIterator()
        while true {
            try await pacing.waitForTurn()
            let response = try await transport.get(request)
            if Self.busyStatuses.contains(response.statusCode), let wait = waits.next() {
                try await sleep(wait)
                continue
            }
            guard HTTPStatus.successful.contains(response.statusCode) else {
                throw MapServiceError.httpStatus(response.statusCode, url: url)
            }
            let answer: OverpassAnswer
            do {
                answer = try JSONDecoder().decode(OverpassAnswer.self, from: Data(response.body))
            } catch {
                throw MapServiceError.invalidResponse("Overpass: \(error)")
            }
            return answer.elements.first.map { OSMTags.information(name: place.name, tags: $0.tags ?? [:]) }
        }
    }

    /// `?data=[out:json][timeout:25];node(…);out tags center;`
    func queryURL(for element: OSMElement) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let query = "[out:json][timeout:\(Self.queryTimeout)];\(element.overpassSelector);out tags center;"
        components?.queryItems = [URLQueryItem(name: "data", value: query)]
        return components?.url
    }
}

/// Overpass's `[out:json]` answer, as much of it as details need.
struct OverpassAnswer: Decodable {
    struct Element: Decodable {
        var type: String
        var id: UInt64
        var tags: [String: String]?
    }

    var elements: [Element]
}
