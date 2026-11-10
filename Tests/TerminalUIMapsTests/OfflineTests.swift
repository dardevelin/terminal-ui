import Foundation
import Synchronization
import Testing
@testable import TerminalUIMaps

@Suite struct RegionPackTests {
    private let request = RegionDownloadRequest(name: "Millbrook", bounds: SampleTown.bounds, zoomRange: 12...16)
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func downloader(_ store: RegionPackStore, _ source: any EncodedTileSource,
                            tileLimit: Int = RegionDownloader.defaultTileLimit) -> RegionDownloader {
        RegionDownloader(store: store, source: source, concurrency: 3, tileLimit: tileLimit,
                         now: { [fixedDate] in fixedDate })
    }

    @Test func downloadsARegionWithProgress() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let source = InstrumentedSource(SampleTileSource())
        let reports = Mutex<[DownloadProgress]>([])
        let pack = try await downloader(store, source).download(request) { progress in
            reports.withLock { $0.append(progress) }
        }
        let expected = RegionDownloader.tileCount(for: request.bounds, zoomRange: 12...16)
        let seen = reports.withLock { $0 }
        #expect(seen.count == expected)
        #expect(seen.map(\.completed) == Array(1...expected))
        #expect(seen.last?.fractionCompleted == 1)
        #expect(source.fetched.count == expected)
        #expect(source.mostInFlight <= 3)
        #expect(pack.manifest.isComplete)
        #expect(pack.manifest.tileCount == expected - (seen.last?.absent ?? 0))
        #expect(pack.manifest.byteCount == seen.last?.bytes)
        #expect(pack.manifest.created == fixedDate)
        #expect(pack.manifest.source == "Sample")
        #expect(pack.manifest.attribution == SampleTown.attribution)
        #expect(FileManager.default.fileExists(atPath: pack.directory.appendingPathComponent("manifest.json").path))
        #expect(pack.storedTiles().count == pack.manifest.tileCount)
        #expect(pack.storedTiles().first?.zoom == 16)
    }

    @Test func theOfflineSourceServesTheBytesAsFetched() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let pack = try await downloader(store, SampleTileSource()).download(request)
        let offline = OfflineTileSource(pack: pack)
        let info = try await offline.info()
        #expect(info.zoomRange == 12...16)
        #expect(info.name == "Millbrook")
        for tile in pack.storedTiles().prefix(5) {
            #expect(try await offline.tileData(tile) == SampleTileSource().tileData(tile))
        }
        #expect(try await offline.tileData(TileID(zoom: 17, x: 0, y: 0)) == nil)
        #expect(try await offline.tileData(TileID(zoom: 14, x: 7812, y: 6233)) == nil)
    }

    @Test func aSecondDownloadFetchesNothing() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        try await downloader(store, SampleTileSource()).download(request)
        let again = InstrumentedSource(SampleTileSource())
        let last = Mutex<DownloadProgress?>(nil)
        let pack = try await downloader(store, again).download(request) { progress in last.withLock { $0 = progress } }
        #expect(again.fetched.isEmpty)
        #expect(last.withLock { $0?.skipped } == pack.manifest.tileCount)
    }

    @Test func aStoppedDownloadResumesWhereItWas() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let dropping = InstrumentedSource(SampleTileSource(), failAfter: 10)
        await #expect(throws: InstrumentedSource.Dropped.self) {
            try await downloader(store, dropping).download(request)
        }
        let stopped = try #require(try store.pack(named: "Millbrook"))
        #expect(!stopped.manifest.isComplete)
        let storedBeforeResume = Set(stopped.storedTiles())
        #expect(!storedBeforeResume.isEmpty)
        #expect(storedBeforeResume.count <= 10)

        let resuming = InstrumentedSource(SampleTileSource())
        let pack = try await downloader(store, resuming).download(request)
        let total = RegionDownloader.tileCount(for: request.bounds, zoomRange: 12...16)
        #expect(pack.manifest.isComplete)
        #expect(resuming.fetched.count == total - storedBeforeResume.count)
        #expect(Set(resuming.fetched).isDisjoint(with: storedBeforeResume))
    }

    @Test func tooManyTilesIsRefusedBeforeAnyFetch() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let source = InstrumentedSource(SampleTileSource())
        let total = RegionDownloader.tileCount(for: request.bounds, zoomRange: 12...16)
        await #expect(throws: RegionPackError.tooManyTiles(count: total, limit: 5)) {
            try await downloader(store, source, tileLimit: 5).download(request)
        }
        #expect(source.fetched.isEmpty)
        #expect(try store.list().isEmpty)
    }

    @Test func theDefaultCapIsTwoThousand() {
        #expect(RegionDownloader.defaultTileLimit == 2_000)
        let portugal = GeoRect(south: 36.9, west: -9.6, north: 42.2, east: -6.1)
        #expect(RegionDownloader.tileCount(for: portugal, zoomRange: 0...14) > RegionDownloader.defaultTileLimit)
    }

    @Test func listsAndDeletesPacks() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let source = SampleTileSource()
        try await downloader(store, source).download(request)
        try await downloader(store, source).download(
            RegionDownloadRequest(name: "Old Town", bounds: GeoRect(covering: [SampleTown.coordinate(east: -650,
                                                                                                     north: -550)])!,
                                  zoomRange: 14...14))
        #expect(try store.list().map(\.manifest.name) == ["Millbrook", "Old Town"])
        let oldTown = try #require(try store.pack(named: "Old Town"))
        #expect(oldTown.directory.lastPathComponent == "old-town")
        try store.delete(oldTown)
        #expect(try store.list().map(\.manifest.name) == ["Millbrook"])
        #expect(try store.pack(named: "Old Town") == nil)
    }

    @Test func aNameMustMakeADirectory() throws {
        let store = RegionPackStore(directory: URL(fileURLWithPath: "/packs"))
        #expect(try store.directory(forName: "Lisboa & Sintra (2026)").lastPathComponent == "lisboa-sintra-2026")
        #expect(throws: RegionPackError.invalidName("…")) { try store.directory(forName: "…") }
    }

    @Test func twoNamesOfOneDirectoryConflict() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let small = RegionDownloadRequest(name: "Old Town", bounds: SampleTown.bounds, zoomRange: 12...12)
        try await downloader(store, SampleTileSource()).download(small)
        var clash = small
        clash.name = "old town!"
        await #expect(throws: RegionPackError.nameConflict("Old Town")) {
            try await downloader(store, SampleTileSource()).download(clash)
        }
    }

    @Test func thePacksGoWhereThePlatformKeepsData() {
        #if canImport(Darwin)
        let path = RegionPackStore.defaultDirectory().path
        #expect(path.hasSuffix("Library/Application Support/TerminalUIMaps/packs"))
        #endif
        #expect(RegionPackStore.xdgDirectory(environment: ["XDG_DATA_HOME": "/data", "HOME": "/home/me"]).path
            == "/data/terminalui-maps/packs")
        #expect(RegionPackStore.xdgDirectory(environment: ["HOME": "/home/me"]).path
            == "/home/me/.local/share/terminalui-maps/packs")
        // The specification ignores a relative XDG_DATA_HOME.
        #expect(RegionPackStore.xdgDirectory(environment: ["XDG_DATA_HOME": "data", "HOME": "/home/me"]).path
            == "/home/me/.local/share/terminalui-maps/packs")
    }

    @Test func offlineSearchFindsTheNamesInThePack() async throws {
        let temporary = try TemporaryDirectory()
        let store = RegionPackStore(directory: temporary.url)
        let pack = try await downloader(store, SampleTileSource()).download(request)
        let search = OfflineSearch(pack: pack)
        let kettle = try #require(try await search.search("copper kettle", near: nil).first)
        #expect(kettle.name == "The Copper Kettle")
        #expect(kettle.kind == "cafe")
        let truth = try #require(SampleTown.places.first { $0.name == "The Copper Kettle" })
        #expect(abs(kettle.coordinate.latitude - truth.coordinate.latitude) < 1e-4)
        #expect(abs(kettle.coordinate.longitude - truth.coordinate.longitude) < 1e-4)
        #expect(try await search.search("High Street", near: nil).first?.name == "High Street")
        #expect(try await search.search("Millbrook", near: nil).contains { $0.kind == "town" })
        #expect(try await search.search("Silver River", near: nil).isEmpty)
    }

    @Test func aManifestOfAnotherFormatIsNotRead() throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"format": 99}"#.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(throws: RegionPackError.self) { try RegionPack(directory: directory) }
        #expect(try RegionPackStore(directory: temporary.url).list().isEmpty)
    }
}
