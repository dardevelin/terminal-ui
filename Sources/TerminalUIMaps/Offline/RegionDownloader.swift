import Foundation

/// A region to download.
public struct RegionDownloadRequest: Sendable, Equatable {
    public var name: String
    public var bounds: GeoRect
    public var zoomRange: ClosedRange<Int>

    public init(name: String, bounds: GeoRect, zoomRange: ClosedRange<Int>) {
        self.name = name
        self.bounds = bounds
        self.zoomRange = zoomRange
    }
}

/// How far a download has got.
public struct DownloadProgress: Sendable, Equatable {
    /// Tiles the region has at its zooms.
    public var total: Int
    /// Tiles dealt with so far: fetched, found on disk, or absent at the
    /// source.
    public var completed = 0
    /// Of those, tiles already on disk from an earlier run, not fetched.
    public var skipped = 0
    /// Of those, tiles the source has none of.
    public var absent = 0
    /// Bytes on disk for the tiles dealt with.
    public var bytes = 0

    public init(total: Int) {
        self.total = total
    }

    public var fractionCompleted: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// Downloads a region's tiles into a pack: every tile of the box over the
/// zoom range, a few at a time, each written as it lands. It resumes: a
/// tile already on disk is not fetched again, so a download that stopped —
/// cancelled, offline, a server error — picks up where it was. Each tile is
/// written to a temporary file and moved into place, so a stopped download
/// never leaves half a tile that a resume would take for whole.
public struct RegionDownloader: Sendable {
    /// The most tiles one pack may hold unless told otherwise, so nobody
    /// bulk-downloads a country by accident: OpenFreeMap allows a personal
    /// offline cache, not a mirror.
    public static let defaultTileLimit = 2_000

    /// Tiles in flight at once: enough to hide a round trip, few enough to
    /// be a polite client.
    public static let defaultConcurrency = 4

    private let store: RegionPackStore
    private let source: any EncodedTileSource
    private let concurrency: Int
    private let tileLimit: Int
    private let now: @Sendable () -> Date

    /// A downloader of `source`'s tiles into packs in `store`, fetching
    /// `concurrency` tiles at once and refusing a region of more than
    /// `tileLimit`.
    public init(store: RegionPackStore, source: any EncodedTileSource,
                concurrency: Int = RegionDownloader.defaultConcurrency,
                tileLimit: Int = RegionDownloader.defaultTileLimit) {
        self.init(store: store, source: source, concurrency: concurrency, tileLimit: tileLimit, now: { Date() })
    }

    init(store: RegionPackStore, source: any EncodedTileSource,
         concurrency: Int = RegionDownloader.defaultConcurrency,
         tileLimit: Int = RegionDownloader.defaultTileLimit,
         now: @escaping @Sendable () -> Date) {
        self.store = store
        self.source = source
        self.concurrency = max(1, concurrency)
        self.tileLimit = tileLimit
        self.now = now
    }

    /// How many tiles a region holds at a range of zooms.
    public static func tileCount(for bounds: GeoRect, zoomRange: ClosedRange<Int>) -> Int {
        zoomRange.reduce(0) { $0 + TileID.count(covering: bounds, zoom: $1) }
    }

    /// Downloads, or resumes downloading, a region, calling `progress` after
    /// each tile on the calling task. Refuses a region of more tiles than
    /// the limit before fetching any. The zoom range is narrowed to what
    /// the source has.
    @discardableResult
    public func download(_ request: RegionDownloadRequest,
                         progress: @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> RegionPack {
        let info = try await source.info()
        let low = max(request.zoomRange.lowerBound, info.zoomRange.lowerBound)
        let high = min(request.zoomRange.upperBound, info.zoomRange.upperBound)
        guard low <= high else {
            throw MapServiceError.unsupported("the source has no tiles at zooms \(request.zoomRange)")
        }
        let zoomRange = low...high
        let total = RegionDownloader.tileCount(for: request.bounds, zoomRange: zoomRange)
        guard total <= tileLimit else { throw RegionPackError.tooManyTiles(count: total, limit: tileLimit) }

        let directory = try store.directory(forName: request.name)
        if let existing = try? RegionPack(directory: directory), existing.manifest.name != request.name {
            throw RegionPackError.nameConflict(existing.manifest.name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let earlier = (try? RegionPack(directory: directory))?.manifest
        let created = earlier?.created ?? now()
        var manifest = RegionPackManifest(name: request.name, bounds: request.bounds, zoomRange: zoomRange,
                                          source: info.name, attribution: info.attribution, created: created)
        manifest.layers = earlier?.layers
        manifest.featureIdentifiers = info.featureIdentifiers
        let pack = RegionPack(directory: directory, manifest: manifest)
        try pack.writeManifest(manifest)

        var state = DownloadProgress(total: total)
        let tiles = zoomRange.lazy.flatMap { TileID.covering(request.bounds, zoom: $0) }
        let source = source
        try await withThrowingTaskGroup(of: TileOutcome.self) { group in
            var pending = tiles.makeIterator()
            for _ in 0..<concurrency {
                guard let tile = pending.next() else { break }
                group.addTask { try await RegionDownloader.store(tile, from: source, in: pack) }
            }
            while let outcome = try await group.next() {
                state.completed += 1
                switch outcome {
                case .stored(let bytes): state.bytes += bytes
                case .alreadyStored(let bytes):
                    state.bytes += bytes
                    state.skipped += 1
                case .absent: state.absent += 1
                }
                progress(state)
                if let tile = pending.next() {
                    group.addTask { try await RegionDownloader.store(tile, from: source, in: pack) }
                }
            }
        }

        manifest.tileCount = state.completed - state.absent
        manifest.byteCount = state.bytes
        manifest.isComplete = true
        try pack.writeManifest(manifest)
        return RegionPack(directory: directory, manifest: manifest)
    }

    private enum TileOutcome: Sendable {
        case stored(bytes: Int)
        case alreadyStored(bytes: Int)
        case absent
    }

    private static func store(_ tile: TileID, from source: any EncodedTileSource,
                              in pack: RegionPack) async throws -> TileOutcome {
        let url = pack.tileURL(for: tile)
        let files = FileManager.default
        if let attributes = try? files.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return .alreadyStored(bytes: size.intValue)
        }
        try Task.checkCancellation()
        guard let data = try await source.tileData(tile) else { return .absent }
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data).write(to: url, options: .atomic)
        return .stored(bytes: data.count)
    }
}
