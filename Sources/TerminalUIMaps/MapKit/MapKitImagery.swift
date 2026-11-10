#if canImport(MapKit)
import CoreGraphics
import MapKit
import TerminalUIIO

/// Apple's satellite imagery as pictures from `MKMapSnapshotter`, one
/// snapshot per tile, as ``MapKitSnapshotSource`` draws the standard map.
/// macOS only, and only on the Apple backend: Apple's terms let its
/// imagery be shown with its own map, not cached into a pack or laid
/// under another's data.
public struct MapKitImagerySource: MapTileSource {
    /// Which of Apple's imagery maps to snapshot.
    public enum Style: String, Sendable, CaseIterable {
        /// Imagery alone: `MKImageryMapConfiguration`.
        case imagery
        /// Imagery with Apple's roads and names drawn in:
        /// `MKHybridMapConfiguration`.
        case hybrid
    }

    /// Which imagery map is snapshotted: imagery alone or with roads and names.
    public let style: Style
    private let pixelsPerTile: Int

    /// Apple's imagery reaches building detail in cities, about OSM's 19;
    /// beyond, the deepest is drawn larger.
    public static let zoomRange = 0...19

    /// The credit Apple's terms ask to be shown with the imagery.
    public static let attribution = "Apple Maps imagery"

    /// A source that snapshots each tile in `style` at `pixelsPerTile` pixels square, at least 1.
    public init(style: Style = .imagery, pixelsPerTile: Int = MapKitSnapshotSource.defaultPixelsPerTile) {
        self.style = style
        self.pixelsPerTile = max(1, pixelsPerTile)
    }

    /// The source's name for its style, Apple's attribution and the imagery's zooms, known without a request.
    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: style == .imagery ? "Apple satellite" : "Apple hybrid",
                       attribution: MapKitImagerySource.attribution, zoomRange: MapKitImagerySource.zoomRange)
    }

    /// The tile as a snapshot picture, or nil for a tile outside the world or the imagery's zooms.
    public func tile(_ id: TileID) async throws -> MapTile? {
        guard id.isValid, MapKitImagerySource.zoomRange.contains(id.zoom) else { return nil }
        return .raster(try await MapKitImagerySource.snapshot(id, style: style, pixels: pixelsPerTile))
    }

    /// A tile's share of `MKMapRect.world`, snapshotted with the imagery
    /// configuration (`preferredConfiguration`, macOS 13 and later).
    @MainActor
    private static func snapshot(_ id: TileID, style: Style, pixels: Int) async throws -> ImageBuffer {
        let world = MKMapRect.world
        let (minimum, maximum) = id.worldBounds
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: world.origin.x + minimum.x * world.size.width,
                                    y: world.origin.y + minimum.y * world.size.height,
                                    width: (maximum.x - minimum.x) * world.size.width,
                                    height: (maximum.y - minimum.y) * world.size.height)
        options.size = CGSize(width: pixels, height: pixels)
        switch style {
        case .imagery:
            options.preferredConfiguration = MKImageryMapConfiguration()
        case .hybrid:
            // Places' pins and names would be drawn at a 256-point tile's
            // size, a cell or more each in half-blocks: the roads and their
            // names are what a hybrid adds.
            let hybrid = MKHybridMapConfiguration()
            hybrid.pointOfInterestFilter = MKPointOfInterestFilter.excludingAll
            options.preferredConfiguration = hybrid
        }
        let snapshot = try await MKMapSnapshotter(options: options).start()
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let image = snapshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw MapServiceError.invalidResponse("the snapshot had no bitmap")
        }
        return try MapKitConversion.pixels(of: image, width: pixels, height: pixels)
    }
}
#endif
