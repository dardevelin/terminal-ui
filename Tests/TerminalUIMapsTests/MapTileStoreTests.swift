import Foundation
import Observation
import Synchronization
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// The store is driven with a source whose tiles land only when the test
// lets them, so every wait is for a condition the test caused, never for
// time to pass.

/// How long a wait for something that happens in its own time may take
/// before it is called a regression: only a regression waits this long. Set
/// for CI's three-core runner under Thread Sanitizer, as TerminalUITests'
/// `eventualLimit` is.
let eventualLimit: Duration = .seconds(60)

/// Yield until `condition` holds, or `eventualLimit` passes; whether it held.
@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: eventualLimit)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        await Task.yield()
    }
    return true
}

/// A tile source whose answers wait until the test releases them, and which
/// records what it was asked for and what was cancelled.
final class GatedSource: MapTileSource {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "the tile server is down" }
    }

    private struct State {
        var waiting: [TileID: CheckedContinuation<MapTile?, any Error>] = [:]
        var requested: [TileID] = []
        var cancelled: Set<TileID> = []
    }

    private let state = Mutex(State())
    let zoomRange: ClosedRange<Int>

    init(zoomRange: ClosedRange<Int> = 0...14) {
        self.zoomRange = zoomRange
    }

    var requested: [TileID] { state.withLock { $0.requested } }
    var cancelled: Set<TileID> { state.withLock { $0.cancelled } }
    var waiting: Set<TileID> { state.withLock { Set($0.waiting.keys) } }

    func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: "Gated", attribution: "Test data", zoomRange: zoomRange)
    }

    func tile(_ id: TileID) async throws -> MapTile? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelledAlready = state.withLock { state -> Bool in
                    state.requested.append(id)
                    if state.cancelled.contains(id) { return true }
                    state.waiting[id] = continuation
                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.cancelled.insert(id)
                return state.waiting.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Answer the request for `id`, if one waits.
    func release(_ id: TileID, with tile: MapTile?) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(returning: tile)
    }

    func fail(_ id: TileID) {
        state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: Failure())
    }
}

private func park() -> MapTile {
    let ring = [TilePoint(x: -64, y: -64), TilePoint(x: 4_160, y: -64), TilePoint(x: 4_160, y: 4_160),
                TilePoint(x: -64, y: 4_160)]
    return .vector(VectorTile(layers: [VectorLayer(name: "park", features: [
        VectorFeature(polygons: [VectorPolygon(exterior: ring)], properties: ["class": "park"]),
    ])]))
}

private let home = GeoCoordinate(latitude: 38.5, longitude: -8.2)
private let tileA = TileID(containing: home, zoom: 14)
private let tileB = TileID(zoom: 14, x: tileA.x + 5, y: tileA.y)
private let tileC = TileID(zoom: 14, x: tileA.x + 10, y: tileA.y)

@Suite("The tile store")
@MainActor
struct MapTileStoreTests {

    @Test func aRequestedTileLandsAndIsKept() async {
        let source = GatedSource()
        let store = MapTileStore(source: source)
        store.load([tileA])
        #expect(await waitUntil { source.waiting.contains(tileA) })
        #expect(store.tile(tileA) == nil)
        #expect(await waitUntil { store.loadingCount == 1 })
        #expect(store.isLoading)
        source.release(tileA, with: park())
        #expect(await waitUntil { store.tile(tileA) != nil })
        #expect(await waitUntil { store.loadingCount == 0 })
        store.load([tileA])
        #expect(source.requested == [tileA], "a tile held is not fetched again")
    }

    @Test func aTileLandingRedrawsWhatDrewFromTheStore() async {
        let source = GatedSource()
        let store = MapTileStore(source: source)
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.tile(tileA)
        } onChange: {
            changed.withLock { $0 = true }
        }
        store.load([tileA])
        #expect(await waitUntil { source.waiting.contains(tileA) })
        #expect(!changed.withLock { $0 })
        source.release(tileA, with: park())
        #expect(await waitUntil { changed.withLock { $0 } })
    }

    @Test func aRequestGoneOffScreenIsCancelledAndItsTileSetAside() async {
        let source = GatedSource()
        let store = MapTileStore(source: source)
        store.load([tileA])
        #expect(await waitUntil { source.waiting.contains(tileA) })
        store.load([tileB])
        #expect(await waitUntil { source.cancelled.contains(tileA) })
        #expect(await waitUntil { source.waiting.contains(tileB) })
        source.release(tileB, with: park())
        #expect(await waitUntil { store.tile(tileB) != nil })
        #expect(store.tile(tileA) == nil)
        #expect(await waitUntil { store.loadingCount == 0 })
    }

    @Test func theLeastRecentlyDrawnTileIsGivenUpFirst() async {
        let source = GatedSource()
        let store = MapTileStore(source: source, capacity: 2)
        for tile in [tileA, tileB] {
            store.load([tile])
            #expect(await waitUntil { source.waiting.contains(tile) })
            source.release(tile, with: park())
            #expect(await waitUntil { store.tile(tile) != nil })
        }
        _ = store.tile(tileA)
        store.load([tileC])
        #expect(await waitUntil { source.waiting.contains(tileC) })
        source.release(tileC, with: park())
        #expect(await waitUntil { store.cachedTiles == [tileA, tileC] })
    }

    @Test func aMissingTileIsDrawnFromACachedAncestor() async {
        let source = GatedSource()
        let store = MapTileStore(source: source)
        let parent = tileA.parent!
        store.load([parent])
        #expect(await waitUntil { source.waiting.contains(parent) })
        source.release(parent, with: park())
        #expect(await waitUntil { store.tile(parent) != nil && store.info != nil })

        let camera = MapCamera(center: home, zoom: 14)
        let renderer = MapRenderer()
        let buffer = drawMap(width: 40, height: 12) { context, size in
            store.draw(with: renderer, in: context, camera: camera, size: size)
        }
        #expect(buffer[20, 6].style.background == MapTestTheme().successSubtle)
        #expect(renderer.statistics.fallbackTiles >= 1)
        #expect(await waitUntil { source.waiting.contains(tileA) }, "and the tile itself is asked for")
    }

    @Test func aFailureIsReportedAndNotRetriedEveryFrame() async {
        let source = GatedSource()
        let store = MapTileStore(source: source)
        store.load([tileA])
        #expect(await waitUntil { source.waiting.contains(tileA) })
        source.fail(tileA)
        #expect(await waitUntil { store.lastError == "the tile server is down" })
        #expect(await waitUntil { store.loadingCount == 0 })
        store.load([tileA])
        #expect(source.requested == [tileA])
        store.retry()
        store.load([tileA])
        #expect(await waitUntil { source.requested == [tileA, tileA] })
    }

    @Test func aNewSourceDropsTheOldOnesTilesAndLateAnswers() async {
        let old = GatedSource()
        let store = MapTileStore(source: old)
        store.load([tileA])
        #expect(await waitUntil { old.waiting.contains(tileA) })
        let new = GatedSource(zoomRange: 0...10)
        store.replaceSource(new)
        old.release(tileA, with: park())
        #expect(await waitUntil { store.info?.zoomRange == 0...10 })
        #expect(await waitUntil { store.loadingCount == 0 })
        #expect(store.tile(tileA) == nil)
        #expect(store.cachedTiles.isEmpty)
    }

    @Test func theSampleTownLoadsWithNoNetwork() async {
        let store = MapTileStore(source: SampleTileSource())
        let camera = MapCamera(center: SampleTown.origin, zoom: 15)
        let size = CanvasSize(width: 80, height: 24)
        #expect(await waitUntil { store.info != nil })
        let tiles = MapRenderer.tiles(for: camera, size: size, zoomRange: store.info!.zoomRange)
        store.load(tiles)
        #expect(await waitUntil { tiles.allSatisfy { store.tile($0) != nil } })
        #expect(!store.isLoading)
    }
}
