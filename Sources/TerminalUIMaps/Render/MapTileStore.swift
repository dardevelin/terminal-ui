import Observation
import TerminalUI

/// The tiles a map has at hand, and the loading of those it needs.
///
/// A frame asks the store for the tiles its camera covers. What the store
/// lacks it loads as tasks — fetched and decoded off the main actor, never
/// blocking the frame — and a request that has gone off screen by the next
/// frame is cancelled, and its tile, if it lands anyway, set aside. Decoded
/// tiles are kept, the least recently drawn given up first once the store
/// holds `capacity`.
///
/// It is observable: a ``MapView`` that draws from it is drawn again when a
/// tile lands, and a status line can show ``isLoading``, ``loadingCount``
/// and ``lastError``. One store serves one map on screen: what it loads and
/// cancels follows the frames of the map that draws from it.
///
/// ```swift
/// let store = MapTileStore(source: SampleTileSource())
/// MapView(camera: $camera, store: store)
/// ```
@MainActor
@Observable
public final class MapTileStore {
    /// Where the tiles come from. Not observed itself: a new source
    /// changes ``info`` and ``revision``, which are.
    @ObservationIgnored public private(set) var source: any MapTileSource
    /// The source's name, zooms and attribution, once it has said.
    public private(set) var info: TileSourceInfo?
    /// Tiles being fetched now.
    public private(set) var loadingCount = 0
    /// What went wrong last, fetching a tile or the source's description,
    /// until a tile next lands.
    public private(set) var lastError: String?
    /// How many tiles have landed: a lookup reads it, so what drew from
    /// the store is drawn again when it moves.
    private(set) var revision = 0

    /// The most decoded tiles kept.
    public let capacity: Int

    /// Enough tiles for a screen several times over at every zoom a pan or
    /// a zoom passes through: a 200 × 60 terminal shows about six.
    public nonisolated static let defaultCapacity = 256

    /// The size, in cells, the map drawing from the store was last drawn
    /// at: what a camera's ``MapCamera/visibleRegion(in:)`` and
    /// ``MapCamera/coordinate(atCell:in:)`` take for the map on screen.
    @ObservationIgnored public private(set) var viewSize = CanvasSize.zero

    private struct Entry {
        var tile: RenderTile
        var lastUse: UInt64
    }

    private struct Load {
        var task: Task<Void, Never>
        var token: UInt64
    }

    @ObservationIgnored private var cache: [TileID: Entry] = [:]
    @ObservationIgnored private var useCount: UInt64 = 0
    @ObservationIgnored private var loads: [TileID: Load] = [:]
    @ObservationIgnored private var loadCount: UInt64 = 0
    /// Tiles the source has none of, or failed to give: not asked for again
    /// until the source changes or ``retry()``.
    @ObservationIgnored private var absent: Set<TileID> = []
    @ObservationIgnored private var failed: Set<TileID> = []
    @ObservationIgnored private var wanted: Set<TileID> = []
    /// Bumped with each source, so a late answer from the last is dropped.
    @ObservationIgnored private var generation = 0

    /// A store of `source`'s tiles. Not isolated, so an app's model can
    /// make one as it is made; asking the source what it has starts on the
    /// main actor straight after.
    public nonisolated init(source: any MapTileSource, capacity: Int = MapTileStore.defaultCapacity) {
        self.source = source
        self.capacity = max(1, capacity)
        Task { @MainActor [weak self] in await self?.describe(source, generation: 0) }
    }

    isolated deinit {
        for load in loads.values { load.task.cancel() }
    }

    /// Whether anything is still on its way: the source's description or a
    /// tile.
    public var isLoading: Bool { loadingCount > 0 || (info == nil && lastError == nil) }

    /// Draw from another source: what the store holds and is loading is
    /// dropped, and late answers from the old source with it.
    public func replaceSource(_ newSource: any MapTileSource) {
        source = newSource
        generation += 1
        for load in loads.values { load.task.cancel() }
        loads.removeAll()
        cache.removeAll()
        absent.removeAll()
        failed.removeAll()
        wanted.removeAll()
        info = nil
        lastError = nil
        revision += 1
        describeSource()
    }

    /// Ask again for the tiles that failed, and for the source's
    /// description if that failed: a map opened offline loads once the
    /// network is back.
    public func retry() {
        failed.removeAll()
        lastError = nil
        revision += 1
        if info == nil { describeSource() }
    }

    /// The tile, decoded, if the store has it. Reads ``revision``, so what
    /// asks is drawn again when a tile lands.
    func tile(_ id: TileID) -> RenderTile? {
        _ = revision
        guard var entry = cache[id] else { return nil }
        useCount += 1
        entry.lastUse = useCount
        cache[id] = entry
        return entry.tile
    }

    /// The tiles the store holds.
    var cachedTiles: Set<TileID> {
        _ = revision
        return Set(cache.keys)
    }

    /// Have `tiles` at hand: load those not held or on their way, and
    /// cancel loads of any others — tiles gone off screen. Cheap to call
    /// every frame with the same tiles; it starts tasks and changes nothing
    /// a view reads, so it may be called while drawing.
    func load(_ tiles: [TileID]) {
        wanted = Set(tiles)
        for (id, load) in loads where !wanted.contains(id) {
            load.task.cancel()
            loads[id] = nil
        }
        for id in tiles where cache[id] == nil && loads[id] == nil && !absent.contains(id) && !failed.contains(id) {
            startLoad(id)
        }
    }

    /// Ready a frame of `size` cells for `camera`: load what it covers and
    /// cancel what it no longer does. Returns the zooms to draw it at, or
    /// nil until the source has said which it has — a read of ``info``, so
    /// the frame is drawn again when it does.
    func prepareFrame(camera: MapCamera, size: CanvasSize) -> ClosedRange<Int>? {
        viewSize = size
        guard let info else { return nil }
        load(MapRenderer.tiles(for: camera, size: size, zoomRange: info.zoomRange))
        return info.zoomRange
    }

    /// Note the size the store's map is drawn at without loading anything:
    /// a frame that hides the basemap still pans and zooms within its size.
    func noteSize(_ size: CanvasSize) {
        viewSize = size
    }

    /// Draw the map for `camera` into a canvas of `size` cells with
    /// `renderer`: what is at hand, and a request for the rest.
    func draw(with renderer: MapRenderer, in context: GraphicsContext, camera: MapCamera,
                     size: CanvasSize, content: [MapElement] = []) {
        guard let zoomRange = prepareFrame(camera: camera, size: size) else { return }
        renderer.draw(in: context, camera: camera, size: size, zoomRange: zoomRange, content: content) {
            tile($0)
        }
    }

    // MARK: - Loading

    private func describeSource() {
        let source = source, generation = generation
        Task { [weak self] in await self?.describe(source, generation: generation) }
    }

    /// Ask `source` what it has; the answer counts only while it is still
    /// the store's source.
    private func describe(_ source: any MapTileSource, generation: Int) async {
        do {
            let info = try await MapTileStore.describe(source)
            guard self.generation == generation else { return }
            self.info = info
        } catch {
            guard self.generation == generation else { return }
            lastError = String(describing: error)
        }
    }

    private func startLoad(_ id: TileID) {
        loadCount += 1
        let token = loadCount
        let source = source
        let generation = generation
        loadingCount += 1
        // The task holds the store only once its fetch is back: a store
        // given up while tiles are on their way is freed, and its deinit
        // cancels them.
        let task = Task { [weak self] in
            let outcome: Result<RenderTile?, any Error>
            do {
                outcome = .success(try await MapTileStore.fetch(id, from: source))
            } catch {
                outcome = .failure(error)
            }
            self?.finishLoad(id, token: token, generation: generation, outcome: outcome)
        }
        loads[id] = Load(task: task, token: token)
    }

    private func finishLoad(_ id: TileID, token: UInt64, generation: Int, outcome: Result<RenderTile?, any Error>) {
        loadingCount -= 1
        let current = loads[id]?.token == token
        if current { loads[id] = nil }
        guard current, self.generation == generation else { return }
        switch outcome {
        case .success(let tile?):
            insert(tile)
        case .success(nil):
            absent.insert(id)
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            failed.insert(id)
            lastError = String(describing: error)
        }
    }

    private func insert(_ tile: RenderTile) {
        useCount += 1
        cache[tile.id] = Entry(tile: tile, lastUse: useCount)
        while cache.count > capacity {
            let evictable = cache.filter { !wanted.contains($0.key) }
            guard let oldest = evictable.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            cache[oldest.key] = nil
        }
        lastError = nil
        revision += 1
    }

    /// Fetch and prepare a tile, away from the main actor: a decode of a
    /// busy city tile takes milliseconds a frame cannot spare.
    @concurrent
    private nonisolated static func fetch(_ id: TileID, from source: any MapTileSource) async throws -> RenderTile? {
        guard let tile = try await source.tile(id) else { return nil }
        try Task.checkCancellation()
        return RenderTile(id: id, tile: tile)
    }

    @concurrent
    private nonisolated static func describe(_ source: any MapTileSource) async throws -> TileSourceInfo {
        try await source.info()
    }
}
