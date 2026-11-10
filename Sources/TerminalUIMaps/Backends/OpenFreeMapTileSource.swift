import Foundation

/// The subset of TileJSON 3.0.0 (github.com/mapbox/tilejson-spec) a vector
/// source needs.
struct TileJSON: Decodable, Sendable {
    var name: String?
    var tiles: [String]
    var minzoom: Int?
    var maxzoom: Int?
    var attribution: String?
    /// West, south, east, north, in degrees.
    var bounds: [Double]?

    /// TileJSON 3.0.0's defaults where a field is absent.
    private enum Default {
        static let minimumZoom = 0
        static let maximumZoom = 30
    }

    private static let boundsCount = 4

    var zoomRange: ClosedRange<Int> {
        let low = minzoom ?? Default.minimumZoom
        return low...max(low, maxzoom ?? Default.maximumZoom)
    }

    var geoBounds: GeoRect {
        guard let bounds, bounds.count == TileJSON.boundsCount else { return TileSourceInfo.world }
        return GeoRect(south: bounds[1], west: bounds[0], north: bounds[3], east: bounds[2])
    }

    /// The URL of a tile from the first template: `{z}`, `{x}` and `{y}`
    /// replaced, as TileJSON §3.13 specifies.
    func url(for tile: TileID) -> URL? {
        guard let template = tiles.first else { return nil }
        let filled = template
            .replacingOccurrences(of: "{z}", with: String(tile.zoom))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y))
        return URL(string: filled)
    }
}

/// OpenMapTiles-schema vector tiles from OpenFreeMap (openfreemap.org),
/// which needs no key. The TileJSON at `tileJSONURL` is fetched once and
/// names the current planet build's tile template and zooms; tiles are
/// then fetched from it.
public actor OpenFreeMapTileSource: EncodedTileSource {
    public static let planetURL = URL(string: "https://tiles.openfreemap.org/planet")!

    /// OpenFreeMap's attribution (openfreemap.org/quick_start), as plain
    /// text for a status bar.
    public static let attribution = "OpenFreeMap © OpenMapTiles Data from OpenStreetMap"

    private let tileJSONURL: URL
    private let transport: any HTTPTransport
    private let userAgent: String
    private var tileJSON: Task<TileJSON, any Error>?

    public init(tileJSONURL: URL = OpenFreeMapTileSource.planetURL,
                transport: any HTTPTransport = URLSessionTransport(),
                userAgent: String) {
        self.tileJSONURL = tileJSONURL
        self.transport = transport
        self.userAgent = userAgent
    }

    public func info() async throws -> TileSourceInfo {
        let metadata = try await loadTileJSON()
        let attribution = metadata.attribution.map(OpenFreeMapTileSource.plainText) ?? OpenFreeMapTileSource.attribution
        return TileSourceInfo(name: metadata.name ?? "OpenFreeMap",
                              attribution: attribution.isEmpty ? OpenFreeMapTileSource.attribution : attribution,
                              zoomRange: metadata.zoomRange, bounds: metadata.geoBounds,
                              featureIdentifiers: .openMapTiles)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        let metadata = try await loadTileJSON()
        guard id.isValid, metadata.zoomRange.contains(id.zoom) else { return nil }
        guard let url = metadata.url(for: id) else {
            throw MapServiceError.invalidResponse("TileJSON has no tile template")
        }
        let response = try await transport.get(request(url))
        switch response.statusCode {
        case HTTPStatus.successful where response.statusCode != HTTPStatus.noContent:
            return response.body
        case HTTPStatus.noContent, HTTPStatus.notFound:
            return nil
        default:
            throw MapServiceError.httpStatus(response.statusCode, url: url)
        }
    }

    /// The TileJSON, fetched by the first caller; callers while it is in
    /// flight wait on the same fetch. A failed fetch is forgotten, so the
    /// next caller tries again.
    private func loadTileJSON() async throws -> TileJSON {
        if let tileJSON { return try await tileJSON.value }
        let transport = transport
        let request = request(tileJSONURL)
        let fetch = Task { try await transport.json(TileJSON.self, from: request) }
        tileJSON = fetch
        do {
            return try await fetch.value
        } catch {
            if tileJSON == fetch { tileJSON = nil }
            throw error
        }
    }

    private func request(_ url: URL) -> HTTPRequest {
        HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent])
    }

    /// A TileJSON attribution, which is HTML, as plain text: tags dropped,
    /// the entities it uses decoded, runs of space collapsed.
    static func plainText(_ html: String) -> String {
        var text = ""
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
            } else if character == ">" {
                inTag = false
                text.append(" ")
            } else if !inTag {
                text.append(character)
            }
        }
        let entities = ["&copy;": "©", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
