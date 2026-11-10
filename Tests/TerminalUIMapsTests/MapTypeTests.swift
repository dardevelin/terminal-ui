import Foundation
import Testing
@testable import TerminalUI
import TerminalUIIO
@testable import TerminalUIMaps

@Suite("The map-type model")
@MainActor
struct MapTypeModelTests {
    private let imagery = ImageryOption(id: "sample", name: "Sample imagery", detail: "the town from the air",
                                        source: SampleImagerySource())
    private let terrain = TerrainOption(id: "sample", name: "Sample ground", detail: "heights",
                                        source: SampleTerrainSource())

    @Test func aVectorBackendWithImageryAndTerrainOffersEveryType() {
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [imagery], terrain: terrain, basemapIsVector: true))
        #expect(model.options.allSatisfy { $0.isAvailable })
        #expect(model.mapType == .explore)
        #expect(model.layers == .explore)
    }

    @Test func eachTypeMakesItsLayers() throws {
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [imagery], terrain: terrain, basemapIsVector: true))
        #expect(model.select(.satellite))
        let satellite = model.layers
        let imageryStore = try #require(satellite.imagery)
        #expect(satellite.basemap == .hidden)
        #expect(satellite.terrain == nil)

        #expect(model.select(.hybrid))
        #expect(model.layers.basemap == .linesAndLabels)
        #expect(model.layers.imagery === imageryStore, "the hybrid keeps the satellite's store and its tiles")

        #expect(model.select(.terrain))
        #expect(model.layers.terrain != nil)
        #expect(model.layers.imagery == nil)
        #expect(model.layers.basemap == .full)
    }

    @Test func aPictureBasemapCannotHaveRoadsDrawnOverImagery() {
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [imagery], terrain: nil, basemapIsVector: false))
        let hybrid = model.option(for: .hybrid)
        #expect(!hybrid.isAvailable)
        #expect(hybrid.detail.contains("picture"))
        #expect(!model.option(for: .terrain).isAvailable)
        #expect(!model.select(.hybrid))
        #expect(model.mapType == .explore)
    }

    @Test func imageryWithItsOwnLabelsMakesAHybridOfAPictureBasemap() {
        let withLabels = ImageryOption(id: "labelled", name: "Labelled", detail: "", source: SampleImagerySource(),
                                       hybridSource: SampleImagerySource())
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [withLabels], terrain: nil, basemapIsVector: false))
        #expect(model.select(.hybrid))
        #expect(model.layers.basemap == .hidden)
    }

    @Test func aBackendWithoutImagerySaysSo() {
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [], terrain: nil, basemapIsVector: true))
        #expect(model.options.filter { $0.isAvailable }.map { $0.type } == [.explore])
        #expect(model.option(for: .satellite).detail.contains("no imagery"))
    }

    @Test func aNewBackendKeepsTheTypeWhereItCanAndFallsBackWhereItCannot() {
        let model = MapTypeModel(offer: MapTypeOffer(imagery: [imagery], terrain: terrain, basemapIsVector: true))
        model.select(.terrain)
        model.setOffer(MapTypeOffer(imagery: [imagery], terrain: terrain, basemapIsVector: true))
        #expect(model.mapType == .terrain)
        model.setOffer(MapTypeOffer(imagery: [imagery], terrain: nil, basemapIsVector: true))
        #expect(model.mapType == .explore)
    }

    @Test func theOpenOfferLeadsWithUSGSAndFillsInWithSentinel() async throws {
        let offer = MapTypeOffer.open(transport: StubTransport { _ in HTTPResponse(statusCode: 404, body: []) })
        let open = try #require(offer.imagery.first)
        let info = try await open.source.info()
        #expect(info.zoomRange == 0...16)
        #expect(info.attribution.contains("USGS"))
        #expect(info.attribution.contains("Sentinel-2 cloudless 2016"))
        #expect(offer.terrain?.source is RasterTileSource)
    }
}

@Suite("The renderer's layers")
@MainActor
struct MapLayerRenderingTests {
    private let width = 40
    private let height = 12
    /// On the north-west face of the sample's downs, which the sun lights,
    /// beside Foundry Way, with a marker to name.
    private let camera = MapCamera(center: SampleTown.coordinate(east: 600, north: -380), zoom: 16)
    private var marker: [MapElement] { Marker("Here", coordinate: camera.center).mapElements }

    private func tile(_ id: TileID, from source: any MapTileSource) async throws -> RenderTile? {
        try await source.tile(id).map { RenderTile(id: id, tile: $0) }
    }

    /// The tiles a frame of the test's size wants, at hand.
    private func tiles(from source: any MapTileSource) async throws -> [TileID: RenderTile] {
        var tiles: [TileID: RenderTile] = [:]
        for id in MapRenderer.tiles(for: camera, size: CanvasSize(width: Double(width), height: Double(height)),
                                    zoomRange: 0...16) {
            tiles[id] = try await tile(id, from: source)
        }
        return tiles
    }

    private func draw(basemap: [TileID: RenderTile], layers: MapFrameLayers,
                      theme: any Theme = MapTestTheme()) -> CellBuffer {
        drawMap(width: width, height: height, theme: theme) { context, size in
            MapRenderer().draw(in: context, camera: camera, size: size, zoomRange: 0...16, content: marker,
                               layers: layers) {
                basemap[$0]
            }
        }
    }

    @Test func terrainDrawsContoursAndShadesTheGround() async throws {
        let basemap = try await tiles(from: SampleTileSource())
        let terrain = try await tiles(from: SampleTerrainSource())
        let plain = draw(basemap: basemap, layers: MapFrameLayers())
        let relief = draw(basemap: basemap,
                          layers: MapFrameLayers(terrain: MapLayerTiles(zoomRange: 0...16) { terrain[$0] }))
        let colours = ReliefColours(MapTestTheme())
        var contourCells = 0, shadedCells = 0
        for y in 0..<height {
            for x in 0..<width {
                let cell = relief[x, y]
                if cell.style.foreground == colours.contour || cell.style.foreground == colours.indexContour {
                    contourCells += 1
                }
                if cell.style.background != plain[x, y].style.background { shadedCells += 1 }
            }
        }
        #expect(contourCells > 0, "contour lines are drawn")
        #expect(shadedCells > 0, "slopes are shaded")
    }

    @Test func theLayersTurnWithTheCamerasBearing() async throws {
        let imagery = try await tiles(from: SampleImagerySource())
        let terrain = try await tiles(from: SampleTerrainSource())
        func frame(bearing: Double, layers: MapFrameLayers) -> CellBuffer {
            var turned = camera
            turned.bearing = bearing
            return drawMap(width: width, height: height) { context, size in
                MapRenderer().draw(in: context, camera: turned, size: size, zoomRange: 0...16, layers: layers) { _ in nil }
            }
        }
        func backgrounds(_ buffer: CellBuffer) -> [String] {
            (0..<height).flatMap { y in (0..<width).map { String(describing: buffer[$0, y].style.background) } }
        }
        func foregrounds(_ buffer: CellBuffer) -> [String] {
            (0..<height).flatMap { y in (0..<width).map { "\(buffer[$0, y].character)\(String(describing: buffer[$0, y].style.foreground))" } }
        }
        let pictures = MapFrameLayers(basemap: .hidden, imagery: MapLayerTiles(zoomRange: 0...16) { imagery[$0] })
        let north = frame(bearing: 0, layers: pictures), east = frame(bearing: 90, layers: pictures)
        #expect(backgrounds(north) != backgrounds(east), "the picture turns")
        #expect(Set(backgrounds(east)).count > 8, "and still fills the turned frame")

        let relief = MapFrameLayers(terrain: MapLayerTiles(zoomRange: 0...16) { terrain[$0] })
        #expect(foregrounds(frame(bearing: 0, layers: relief)) != foregrounds(frame(bearing: 90, layers: relief)),
                "the contours turn")
    }

    @Test func satelliteDrawsThePictureAndNoneOfTheBasemap() async throws {
        let basemap = try await tiles(from: SampleTileSource())
        let imagery = try await tiles(from: SampleImagerySource())
        let buffer = draw(basemap: basemap,
                          layers: MapFrameLayers(basemap: .hidden,
                                                 imagery: MapLayerTiles(zoomRange: 0...16) { imagery[$0] }))
        let text = (0..<height).map { buffer.row($0) }.joined()
        #expect(!text.unicodeScalars.contains { (0x2801...0x28FF).contains($0.value) }, "no roads drawn over it")
        let backgrounds = Set((0..<height).flatMap { y in (0..<width).map { String(describing: buffer[$0, y].style.background) } })
        #expect(backgrounds.count > 8, "a photograph has many colours")
    }

    @Test func hybridDrawsRoadsAndNamesOverThePictureOnTheThemesGround() async throws {
        let basemap = try await tiles(from: SampleTileSource())
        let imagery = try await tiles(from: SampleImagerySource())
        let theme = MapTestTheme()
        let buffer = draw(basemap: basemap,
                          layers: MapFrameLayers(basemap: .linesAndLabels,
                                                 imagery: MapLayerTiles(zoomRange: 0...16) { imagery[$0] }))
        let text = (0..<height).map { buffer.row($0) }.joined()
        #expect(text.unicodeScalars.contains { (0x2801...0x28FF).contains($0.value) }, "roads are drawn")
        let labelled = (0..<height).flatMap { y in (0..<width).map { buffer[$0, y] } }
            .filter { $0.character.isLetter }
        #expect(!labelled.isEmpty, "names are drawn")
        #expect(labelled.allSatisfy { $0.style.background == theme.background },
                "a name sits on the theme's ground, not the photo")
    }
}

@Suite("Raster layers in region packs")
struct RegionPackLayerTests {
    @Test func aRegionsImageryAndTerrainDownloadBesideItsTilesAndReadBackOffline() async throws {
        let directory = try TemporaryDirectory()
        let store = RegionPackStore(directory: directory.url)
        let box = GeoRect(south: SampleTown.origin.latitude - 0.001, west: SampleTown.origin.longitude - 0.001,
                          north: SampleTown.origin.latitude + 0.001, east: SampleTown.origin.longitude + 0.001)
        let pack = try await RegionDownloader(store: store, source: SampleTileSource())
            .download(RegionDownloadRequest(name: "Millbrook", bounds: box, zoomRange: 14...15))
        let withImagery = try await RegionLayerDownloader(source: SampleImagerySource(), kind: .imagery,
                                                          encoding: .picture).download(into: pack)
        let withTerrain = try await RegionLayerDownloader(source: SampleTerrainSource(), kind: .terrain,
                                                          encoding: .terrarium).download(into: withImagery)

        let reread = try #require(try store.pack(named: "Millbrook"))
        let imagery = try #require(reread.layer(.imagery))
        let terrain = try #require(reread.layer(.terrain))
        #expect(imagery.isComplete && terrain.isComplete)
        #expect(imagery.zoomRange == 14...15)
        #expect(imagery.tileCount == RegionDownloader.tileCount(for: box, zoomRange: 14...15))
        #expect(withTerrain.manifest.layers?.count == 2)

        let id = TileID(containing: SampleTown.origin, zoom: 15)
        guard case .raster = try #require(try await OfflineLayerSource(pack: reread, layer: imagery).tile(id)),
              case .elevation = try #require(try await OfflineLayerSource(pack: reread, layer: terrain).tile(id)) else {
            Issue.record("the layers read back as a picture and heights")
            return
        }

        // A second download of the region keeps its layers.
        let again = try await RegionDownloader(store: store, source: SampleTileSource())
            .download(RegionDownloadRequest(name: "Millbrook", bounds: box, zoomRange: 14...15))
        #expect(again.manifest.layers?.count == 2)
    }

    @Test func aLayerResumesWithoutFetchingWhatIsOnDisk() async throws {
        let directory = try TemporaryDirectory()
        let store = RegionPackStore(directory: directory.url)
        let box = GeoRect(south: SampleTown.origin.latitude - 0.001, west: SampleTown.origin.longitude - 0.001,
                          north: SampleTown.origin.latitude + 0.001, east: SampleTown.origin.longitude + 0.001)
        let pack = try await RegionDownloader(store: store, source: SampleTileSource())
            .download(RegionDownloadRequest(name: "Millbrook", bounds: box, zoomRange: 15...15))
        let first = InstrumentedSource(SampleTerrainSource())
        try await RegionLayerDownloader(source: first, kind: .terrain, encoding: .terrarium).download(into: pack)
        let second = InstrumentedSource(SampleTerrainSource())
        try await RegionLayerDownloader(source: second, kind: .terrain, encoding: .terrarium).download(into: pack)
        #expect(!first.fetched.isEmpty)
        #expect(second.fetched.isEmpty)
    }

    @Test func aPackWrittenBeforeLayersReadsAsHavingNone() throws {
        let directory = try TemporaryDirectory()
        let manifest = """
        {"attribution":"a","bounds":{"east":1,"north":1,"south":0,"west":0},"byteCount":0,
         "created":"2026-01-01T00:00:00Z","format":1,"isComplete":true,"maximumZoom":3,"minimumZoom":0,
         "name":"Old","source":"s","tileCount":0}
        """
        try Data(manifest.utf8).write(to: directory.url.appendingPathComponent("manifest.json"))
        let pack = try RegionPack(directory: directory.url)
        #expect(pack.manifest.layers == nil)
        #expect(pack.layer(.imagery) == nil)
    }
}

@Suite("Credits on the map")
struct AttributionTests {
    @Test func aLongCreditBreaksAtItsPartsThenItsWordsAndIsNeverCut() {
        let lines = MapView.attributionLines(
            ["USGS The National Map: Orthoimagery · " + ImageryCredits.sentinel2Cloudless2016, "Sample"], width: 60)
        #expect(lines.allSatisfy { $0.count <= 60 })
        #expect(lines.first == "USGS The National Map: Orthoimagery")
        #expect(lines.joined(separator: " ").contains("(Contains modified Copernicus Sentinel data 2016)"))
        #expect(lines.last == "Sample")
    }

    @Test func aCreditGivenTwiceIsShownOnce() {
        #expect(MapView.attributionLines(["Sample data", "Sample data"], width: 80) == ["Sample data"])
    }
}
