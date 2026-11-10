import Foundation

/// What a raster layer of a pack holds.
public enum RegionPackLayerKind: String, Sendable, Codable, CaseIterable {
    case imagery
    case terrain
}

/// A raster layer downloaded into a region pack beside its vector tiles:
/// the same box, at the zooms both the pack and the layer's source have,
/// each tile the source's bytes as fetched under
/// `layers/<kind>/<z>/<x>/<y>.<png|jpg>`.
///
/// Only sources whose licences allow keeping their tiles are downloaded:
/// Sentinel-2 cloudless 2016 (CC BY 4.0), USGS (public domain), AWS
/// Terrain Tiles and the sample town's. Apple's imagery is a snapshot
/// shown with Apple's map, not a tile to keep, and is never a layer.
public struct RegionPackLayer: Sendable, Codable, Equatable {
    public var kind: RegionPackLayerKind
    /// The source's name and the credit its licence requires.
    public var source: String
    public var attribution: String
    public var encoding: RasterEncoding
    public var minimumZoom: Int
    public var maximumZoom: Int
    public var tileCount: Int
    public var byteCount: Int
    public var isComplete: Bool

    public var zoomRange: ClosedRange<Int> { minimumZoom...max(minimumZoom, maximumZoom) }

    public init(kind: RegionPackLayerKind, source: String, attribution: String, encoding: RasterEncoding,
                zoomRange: ClosedRange<Int>, tileCount: Int = 0, byteCount: Int = 0, isComplete: Bool = false) {
        self.kind = kind
        self.source = source
        self.attribution = attribution
        self.encoding = encoding
        minimumZoom = zoomRange.lowerBound
        maximumZoom = zoomRange.upperBound
        self.tileCount = tileCount
        self.byteCount = byteCount
        self.isComplete = isComplete
    }
}

extension RegionPack {
    static let layersDirectoryName = "layers"
    /// The extensions a layer's tile may be stored under, by what its
    /// bytes are.
    static let layerExtensions = ["png", "jpg"]

    /// The layer of a kind the pack holds, if any.
    public func layer(_ kind: RegionPackLayerKind) -> RegionPackLayer? {
        manifest.layers?.first { $0.kind == kind }
    }

    /// The directory a layer's tiles live in.
    public func layerDirectory(_ kind: RegionPackLayerKind) -> URL {
        directory.appendingPathComponent(RegionPack.layersDirectoryName).appendingPathComponent(kind.rawValue)
    }

    /// Where a layer's tile is stored with a file extension.
    func layerTileURL(_ kind: RegionPackLayerKind, tile: TileID, fileExtension: String) -> URL {
        layerDirectory(kind).appendingPathComponent(String(tile.zoom)).appendingPathComponent(String(tile.x))
            .appendingPathComponent("\(tile.y).\(fileExtension)")
    }

    /// The stored file of a layer's tile, whichever extension it has.
    func storedLayerTile(_ kind: RegionPackLayerKind, tile: TileID) -> URL? {
        RegionPack.layerExtensions.lazy.map { layerTileURL(kind, tile: tile, fileExtension: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// A pack's raster layer, served from disk: its tiles decoded as the
/// source's were.
public struct OfflineLayerSource: EncodedTileSource {
    public let pack: RegionPack
    public let layer: RegionPackLayer

    public init(pack: RegionPack, layer: RegionPackLayer) {
        self.pack = pack
        self.layer = layer
    }

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: layer.source, attribution: layer.attribution, zoomRange: layer.zoomRange,
                       bounds: pack.manifest.bounds)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard layer.zoomRange.contains(id.zoom), id.bounds.intersects(pack.manifest.bounds),
              let url = pack.storedLayerTile(layer.kind, tile: id) else { return nil }
        return Array(try Data(contentsOf: url))
    }

    public func tile(_ id: TileID) async throws -> MapTile? {
        guard let bytes = try await tileData(id) else { return nil }
        return try layer.encoding.decode(bytes)
    }
}

/// Downloads a raster layer into an existing pack, over the pack's box and
/// the zooms both have, a few tiles at a time; it resumes as the region's
/// own download does, a tile on disk not fetched again, and the pack's
/// manifest says how far it got.
public struct RegionLayerDownloader: Sendable {
    private let source: any EncodedTileSource
    private let kind: RegionPackLayerKind
    private let encoding: RasterEncoding
    private let concurrency: Int
    private let tileLimit: Int

    public init(source: any EncodedTileSource, kind: RegionPackLayerKind, encoding: RasterEncoding,
                concurrency: Int = RegionDownloader.defaultConcurrency,
                tileLimit: Int = RegionDownloader.defaultTileLimit) {
        self.source = source
        self.kind = kind
        self.encoding = encoding
        self.concurrency = max(1, concurrency)
        self.tileLimit = tileLimit
    }

    /// The zooms the layer is downloaded at: the pack's that the source
    /// has, or nil where they share none.
    public static func zoomRange(of pack: RegionPack, source info: TileSourceInfo) -> ClosedRange<Int>? {
        let low = max(pack.manifest.zoomRange.lowerBound, info.zoomRange.lowerBound)
        let high = min(pack.manifest.zoomRange.upperBound, info.zoomRange.upperBound)
        return low <= high ? low...high : nil
    }

    /// Download, or resume downloading, the layer into `pack`, calling
    /// `progress` after each tile; returns the pack with the layer in its
    /// manifest.
    @discardableResult
    public func download(into pack: RegionPack,
                         progress: @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> RegionPack {
        let info = try await source.info()
        guard let zoomRange = Self.zoomRange(of: pack, source: info) else {
            throw MapServiceError.unsupported("\(info.name) has no tiles at the region's zooms")
        }
        let bounds = pack.manifest.bounds
        let total = RegionDownloader.tileCount(for: bounds, zoomRange: zoomRange)
        guard total <= tileLimit else { throw RegionPackError.tooManyTiles(count: total, limit: tileLimit) }

        // Copies the download's tasks capture, taken before any closure
        // names them: a closure that captures a name declared after it is an
        // error to the Linux toolchain's Swift 6.2.
        let source = source, kind = kind
        var layer = RegionPackLayer(kind: kind, source: info.name, attribution: info.attribution, encoding: encoding,
                                    zoomRange: zoomRange)
        var manifest = pack.manifest
        manifest.layers = (manifest.layers ?? []).filter { $0.kind != kind } + [layer]
        try pack.writeManifest(manifest)

        var state = DownloadProgress(total: total)
        let tiles = zoomRange.lazy.flatMap { TileID.covering(bounds, zoom: $0) }
        try await withThrowingTaskGroup(of: (bytes: Int, fetched: Bool)?.self) { group in
            var pending = tiles.makeIterator()
            for _ in 0..<concurrency {
                guard let tile = pending.next() else { break }
                group.addTask { try await RegionLayerDownloader.store(tile, kind: kind, from: source, in: pack) }
            }
            while let outcome = try await group.next() {
                state.completed += 1
                if let outcome {
                    state.bytes += outcome.bytes
                    if !outcome.fetched { state.skipped += 1 }
                } else {
                    state.absent += 1
                }
                progress(state)
                if let tile = pending.next() {
                    group.addTask { try await RegionLayerDownloader.store(tile, kind: kind, from: source, in: pack) }
                }
            }
        }

        layer.tileCount = state.completed - state.absent
        layer.byteCount = state.bytes
        layer.isComplete = true
        manifest.layers = (manifest.layers ?? []).filter { $0.kind != kind } + [layer]
        try pack.writeManifest(manifest)
        return RegionPack(directory: pack.directory, manifest: manifest)
    }

    /// The tile's bytes on disk, fetched unless they are there already;
    /// nil for a tile the source has none of.
    private static func store(_ tile: TileID, kind: RegionPackLayerKind, from source: any EncodedTileSource,
                              in pack: RegionPack) async throws -> (bytes: Int, fetched: Bool)? {
        let files = FileManager.default
        if let stored = pack.storedLayerTile(kind, tile: tile),
           let size = (try? files.attributesOfItem(atPath: stored.path))?[.size] as? NSNumber {
            return (size.intValue, false)
        }
        try Task.checkCancellation()
        guard let data = try await source.tileData(tile) else { return nil }
        let url = pack.layerTileURL(kind, tile: tile,
                                    fileExtension: RasterEncoding.fileExtension(for: data))
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data).write(to: url, options: .atomic)
        return (data.count, true)
    }
}
