import Foundation
import TerminalUIIO

/// What a raster tile's bytes hold.
public enum RasterEncoding: String, Sendable, Codable, Equatable {
    /// A picture, PNG or JPEG: imagery, drawn as it is.
    case picture
    /// Heights in Mapzen's Terrarium encoding (``Terrarium``), in a PNG.
    case terrarium

    /// The tile the bytes hold, decoded in pure Swift, so every system
    /// draws the same: PNG or JPEG by their signatures.
    func decode(_ bytes: [UInt8]) throws -> MapTile {
        let image = try RasterEncoding.image(bytes)
        switch self {
        case .picture: return .raster(image)
        case .terrarium: return .elevation(Terrarium.elevation(of: image))
        }
    }

    /// The file extension a pack stores such a tile under.
    static func fileExtension(for bytes: [UInt8]) -> String {
        bytes.starts(with: RasterEncoding.jpegSignature) ? "jpg" : "png"
    }

    /// ITU-T T.81 B.2.1: the SOI marker every JPEG starts with.
    static let jpegSignature: [UInt8] = [0xFF, 0xD8]

    static func image(_ bytes: [UInt8]) throws(ImageDecodeError) -> ImageBuffer {
        let data = Data(bytes)
        if bytes.starts(with: jpegSignature) { return try JPEGDecoder().decode(data) }
        return try PNGDecoder().decode(data)
    }
}

/// Raster tiles from an XYZ URL template: imagery or terrain served by
/// zoom, column and row, as most open tile servers lay them out.
///
/// The template names `{z}`, `{x}` and `{y}` in whatever order the server
/// wants them — EOX's WMTS puts the row before the column. A 404 or 204 is
/// a tile the server has none of (USGS answers 404 outside the United
/// States), not an error. Tiles decode with the pure-Swift ``PNGDecoder``
/// and ``JPEGDecoder``.
///
/// ```swift
/// let imagery = RasterTileSource.sentinel2Cloudless2016()
/// let store = MapTileStore(source: imagery)
/// ```
public struct RasterTileSource: EncodedTileSource {
    public let template: String
    public let encoding: RasterEncoding
    private let sourceInfo: TileSourceInfo
    private let transport: any HTTPTransport
    private let userAgent: String

    public init(name: String, attribution: String, template: String, encoding: RasterEncoding,
                zoomRange: ClosedRange<Int>, bounds: GeoRect = TileSourceInfo.world,
                transport: any HTTPTransport = URLSessionTransport(), userAgent: String) {
        self.template = template
        self.encoding = encoding
        sourceInfo = TileSourceInfo(name: name, attribution: attribution, zoomRange: zoomRange, bounds: bounds)
        self.transport = transport
        self.userAgent = userAgent
    }

    public func info() async throws -> TileSourceInfo { sourceInfo }

    /// The URL of a tile: the template with its zoom, column and row.
    func url(for tile: TileID) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: String(tile.zoom))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard id.isValid, sourceInfo.zoomRange.contains(id.zoom), id.bounds.intersects(sourceInfo.bounds) else {
            return nil
        }
        guard let url = url(for: id) else { throw MapServiceError.invalidResponse("bad tile template \(template)") }
        let response = try await transport.get(HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent]))
        switch response.statusCode {
        case HTTPStatus.noContent, HTTPStatus.notFound: return nil
        case HTTPStatus.successful: return response.body
        default: throw MapServiceError.httpStatus(response.statusCode, url: url)
        }
    }

    public func tile(_ id: TileID) async throws -> MapTile? {
        guard let bytes = try await tileData(id) else { return nil }
        return try encoding.decode(bytes)
    }
}

extension RasterTileSource {
    /// EOX's Sentinel-2 cloudless mosaic of **2016**, the one year released
    /// under CC BY 4.0 (later years are CC BY-NC-SA): a cloud-free world at
    /// Sentinel-2's 10 m a pixel, so z14 is its last real zoom. No key.
    /// WMTS `s2cloudless_3857`, tile matrix set `g` (EPSG:3857), row before
    /// column.
    public static func sentinel2Cloudless2016(transport: any HTTPTransport = URLSessionTransport(),
                                              userAgent: String) -> RasterTileSource {
        RasterTileSource(name: "Sentinel-2 cloudless 2016", attribution: ImageryCredits.sentinel2Cloudless2016,
                         template: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg",
                         encoding: .picture, zoomRange: ImageryZooms.sentinel2, transport: transport,
                         userAgent: userAgent)
    }

    /// USGS The National Map's orthoimagery, in the public domain: the
    /// United States only, to about a metre a pixel (z16). Elsewhere the
    /// server answers 404, which reads as no tile.
    public static func usgsImagery(transport: any HTTPTransport = URLSessionTransport(),
                                   userAgent: String) -> RasterTileSource {
        RasterTileSource(name: "USGS orthoimagery", attribution: ImageryCredits.usgs,
                         template: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}",
                         encoding: .picture, zoomRange: ImageryZooms.usgs, bounds: ImageryBounds.unitedStates,
                         transport: transport, userAgent: userAgent)
    }

    /// AWS Terrain Tiles (registry.opendata.aws/terrain-tiles), Mapzen's
    /// global elevation in Terrarium PNG, z0 to z15. No key.
    public static func awsTerrain(transport: any HTTPTransport = URLSessionTransport(),
                                  userAgent: String) -> RasterTileSource {
        RasterTileSource(name: "AWS Terrain Tiles", attribution: ImageryCredits.awsTerrain,
                         template: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
                         encoding: .terrarium, zoomRange: ImageryZooms.awsTerrain, transport: transport,
                         userAgent: userAgent)
    }
}

/// The credit each open source's licence requires on screen, as its
/// provider words it.
enum ImageryCredits {
    /// CC BY 4.0, as EOX's WMTS capabilities give it for the 2016 layer.
    static let sentinel2Cloudless2016 =
        "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016)"
    /// Public domain; the service's own copyright text.
    static let usgs = "USGS The National Map: Orthoimagery"
    /// The Terrain Tiles' sources, as tilezen/joerd's attribution lists
    /// the ones that ask to be named.
    static let awsTerrain = "Terrain Tiles: Mapzen, AWS Open Data; SRTM, GMTED2010, ETOPO1, USGS 3DEP and others"
}

/// The zooms each open source has real tiles at.
enum ImageryZooms {
    static let sentinel2 = 0...14
    static let usgs = 0...16
    static let awsTerrain = 0...15
}

/// Where USGS's imagery is: the fifty states, Puerto Rico and the
/// territories near them, as one box from Hawaii's south to Alaska's
/// north. Tiles in the box but outside the country answer 404.
enum ImageryBounds {
    static let unitedStates = GeoRect(south: 17, west: -180, north: 72, east: -64)
}
