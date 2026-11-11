import Foundation
import Testing
import TerminalUIIO
@testable import TerminalUI
@testable import TerminalUIMaps

/// Central Paris at zoom 14, the densest tile the fixtures hold
/// (Fixtures/README.md): about 13 800 points of interest.
enum ParisFixture {
    static let id = TileID(zoom: 14, x: 8298, y: 5636)

    /// Decoded once for every test: a debug build takes most of a second
    /// over its 1.2 MB.
    static func tile() throws -> RenderTile {
        try decoded.get()
    }

    private static let decoded = Result<RenderTile, any Error> {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openfreemap-14-8298-5636.pbf.gz")
        return RenderTile(id: id, tile: .vector(try VectorTileDecoder.decode(Array(try Data(contentsOf: url)))))
    }

    /// The tile's middle: the Seine by the Pont Neuf, the Louvre north of
    /// it, Saint-Germain south.
    static var centre: GeoCoordinate { id.bounds.center }
}

/// A frame of the renderer over a set of tiles, as text, for a test to read.
@MainActor
func renderFrame(_ tiles: [RenderTile], camera: MapCamera, width: Int, height: Int, zoomRange: ClosedRange<Int>,
                 renderer: MapRenderer = MapRenderer(), content: [MapElement] = []) -> CellBuffer {
    let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return drawMap(width: width, height: height) { context, size in
        renderer.draw(in: context, camera: camera, size: size, zoomRange: zoomRange, content: content) { byID[$0] }
    }
}

extension CellBuffer {
    /// Every row, top to bottom.
    var text: String { (0..<height).map(row).joined(separator: "\n") }
}

/// Whether frames are printed for a person to look at:
/// `TERMINALUI_MAPS_PRINT=1`.
let printFrames = ProcessInfo.processInfo.environment["TERMINALUI_MAPS_PRINT"] == "1"

@Suite("A dense city")
@MainActor
struct DenseCityTests {
    /// The work a 200 × 60 frame over central Paris may do, at the zooms
    /// a reader of a city looks at: counts, not time, so the budget holds
    /// on any machine. Measured on the fixture (design/maps.md,
    /// "Measured") and set about half as high again, so a change that
    /// doubles a frame's work fails here.
    private enum Budget {
        static let labelsOffered = 480
        static let verticesDrawn = 80_000
        static let pointsOfInterestPlaced = 20...120
    }

    @Test(arguments: [14.0, 14.5, 15, 16, 17, 18])
    func aFrameOverCentralParisStaysWithinItsBudget(zoom: Double) throws {
        let tile = try ParisFixture.tile()
        let renderer = MapRenderer()
        let camera = MapCamera(center: ParisFixture.centre, zoom: zoom)
        let buffer = renderFrame([tile], camera: camera, width: 200, height: 60, zoomRange: 0...14, renderer: renderer)
        let statistics = renderer.statistics
        #expect(statistics.labelsOffered <= Budget.labelsOffered, "\(statistics)")
        #expect(statistics.verticesDrawn <= Budget.verticesDrawn, "\(statistics)")
        if zoom <= 16 {
            #expect(Budget.pointsOfInterestPlaced.contains(statistics.pointsOfInterestPlaced), "\(statistics)")
        }
        #expect(statistics.labelsPlaced > 0)
        // Every placed name and glyph is where it was placed, none over
        // another.
        var taken = Set<Int>()
        for label in renderer.placedLabels {
            let columns = label.showsText ? label.column..<(label.column + label.width) : label.column..<(label.column + 1)
            for column in columns {
                #expect(taken.insert(label.row * buffer.width + column).inserted, "\(label.text) overlaps")
            }
        }
        for point in renderer.placedPointsOfInterest {
            #expect(buffer[point.column, point.row].character == Character(point.category.glyph))
            if point.nameColumns != nil {
                #expect(taken.insert(point.row * buffer.width + point.column).inserted, "\(point.name)'s glyph")
            }
        }
    }

    @Test func theRankCutKeepsAFewPointsAGridCellAndFourTimesAsManyAZoomDeeper() {
        let density = PointOfInterestDensity.standard
        #expect(density.maximumRank(atZoom: 14, tileZoom: 14) == 2)
        #expect(density.maximumRank(atZoom: 14.5, tileZoom: 14) == 4)
        #expect(density.maximumRank(atZoom: 15, tileZoom: 14) == 8)
        #expect(density.maximumRank(atZoom: 17, tileZoom: 14) == 128)
        #expect(density.maximumRank(atZoom: 13, tileZoom: 14) == 2, "a tile drawn smaller keeps its own cut")
        #expect(density.maximumRank(atZoom: 22, tileZoom: 14) == 131_072 || density.maximumRank(atZoom: 22, tileZoom: 14)
            == PointOfInterestDensity.unlimited)
    }

    @Test func centralParisOffersAFewPerCellAtItsOwnZoom() throws {
        let renderer = MapRenderer()
        _ = renderFrame([try ParisFixture.tile()], camera: MapCamera(center: ParisFixture.centre, zoom: 14),
                        width: 200, height: 60, zoomRange: 0...14, renderer: renderer)
        #expect(renderer.statistics.pointsOfInterestCut > 5_000, "the rank cut passes over most of the 13 800")
    }

    @Test func streetFurnitureAndOfficesAreNotPointsOfInterest() throws {
        guard case .vector(let content) = try ParisFixture.tile().content else {
            Issue.record("the fixture is a vector tile")
            return
        }
        let points = content.labels.compactMap(\.pointOfInterest)
        #expect(points.count > 5_000)
        for noise in ["waste_basket", "bicycle_parking", "bollard", "office", "information", "gate"] {
            #expect(!points.contains { $0.featureClass == noise }, "\(noise) is noise")
        }
        #expect(points.contains { $0.category == .food })
        #expect(points.contains { $0.featureClass == "library" && $0.category == .shop },
                "a bookshop, which the schema files under library, is a shop")
    }

    @Test func everyCategoryHasOneCellGlyphOfItsOwnAndATitle() {
        let glyphs = PointOfInterestCategory.allCases.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
        for category in PointOfInterestCategory.allCases {
            #expect(category.glyph.displayWidth == 1, "\(category)")
            #expect(category.glyph.count == 1)
            #expect(!category.title.isEmpty)
        }
        #expect(PointOfInterestCategory(class: "restaurant", subclass: "restaurant") == .food)
        #expect(PointOfInterestCategory(class: "shop", subclass: "convenience") == .groceries)
        #expect(PointOfInterestCategory(class: "post", subclass: "post_box") == nil)
        #expect(PointOfInterestCategory(class: "something_new", subclass: nil) == .shop)
    }

    /// Past the source's last zoom the z14 tile is drawn larger, and what
    /// it holds keeps coming in: more points at 16 than at 15 over the same
    /// streets, buildings from 15.
    @Test func overZoomedParisRevealsMoreAsItComesCloser() throws {
        let tile = try ParisFixture.tile()
        let size = CanvasSize(width: 200, height: 60)
        let camera = MapCamera(center: ParisFixture.centre, zoom: 18)
        #expect(MapRenderer.tiles(for: camera, size: size, zoomRange: 0...14).allSatisfy { $0.zoom == 14 })
        let around = ParisFixture.id.coordinate(of: TilePoint(x: 1_500, y: 2_600), extent: VectorLayer.defaultExtent)
        func placed(_ zoom: Double) -> Int {
            let renderer = MapRenderer()
            _ = renderFrame([tile], camera: MapCamera(center: around, zoom: zoom), width: 200, height: 60,
                            zoomRange: 0...14, renderer: renderer)
            return renderer.statistics.pointsOfInterestPlaced + renderer.statistics.pointsOfInterestCut
        }
        let building = MapRole.building.colour(in: MapTestTheme())
        func hasBuildings(_ zoom: Double) -> Bool {
            let buffer = renderFrame([tile], camera: MapCamera(center: around, zoom: zoom), width: 200, height: 60,
                                     zoomRange: 0...14)
            return (0..<buffer.height).contains { y in
                (0..<buffer.width).contains { buffer[$0, y].style.background == building }
            }
        }
        #expect(!hasBuildings(14.5))
        #expect(hasBuildings(15.5))
        let renderer = MapRenderer()
        _ = renderFrame([tile], camera: MapCamera(center: around, zoom: 15), width: 200, height: 60,
                        zoomRange: 0...14, renderer: renderer)
        let atFifteen = renderer.statistics.pointsOfInterestPlaced
        let closer = MapRenderer()
        _ = renderFrame([tile], camera: MapCamera(center: around, zoom: 17), width: 200, height: 60,
                        zoomRange: 0...14, renderer: closer)
        #expect(closer.statistics.pointsOfInterestCut < renderer.statistics.pointsOfInterestCut)
        #expect(atFifteen > 0 && placed(17) > 0)
    }

    /// Turned by a bearing, the city keeps its names level and its points
    /// where the turn puts them: a placed point's glyph is at the screen
    /// point of its coordinate, and a street crossing the view is named.
    @Test func aTurnedMapKeepsItsNamesLevelAndItsPointsInPlace() throws {
        let tile = try ParisFixture.tile()
        let renderer = MapRenderer()
        let camera = MapCamera(center: ParisFixture.centre, zoom: 16, bearing: 60)
        let buffer = renderFrame([tile], camera: camera, width: 200, height: 60, zoomRange: 0...14, renderer: renderer)
        #expect(renderer.statistics.pointsOfInterestPlaced > 5)
        let viewport = MapRenderer.viewport(for: CanvasSize(width: 200, height: 60))
        for point in renderer.placedPointsOfInterest {
            let screen = try #require(camera.screenPoint(for: point.coordinate, in: viewport))
            #expect(Int(screen.x / Double(BrailleCell.dotColumns)) == point.column, "\(point.name)")
            #expect(Int(screen.y / Double(BrailleCell.dotRows)) == point.row, "\(point.name)")
        }
        #expect(buffer.text.contains("Quai"), "a quay along the Seine is named, level, under the turn")
    }

    /// Over a satellite picture, as the hybrid map draws it, every name and
    /// point-of-interest glyph sits on the theme's ground, so the photo's
    /// colours cannot drown them.
    @Test func overAPictureNamesAndGlyphsSitOnTheThemesGround() throws {
        let tile = try ParisFixture.tile()
        let pixels: [UInt8] = [120, 120, 120, 255]
        let picture = RenderTile(id: ParisFixture.id, tile: .raster(try ImageBuffer(rgba: pixels, width: 1, height: 1)))
        let layers = MapFrameLayers(basemap: .linesAndLabels,
                                    imagery: MapLayerTiles(zoomRange: 0...14) { $0 == picture.id ? picture : nil })
        let renderer = MapRenderer()
        let theme = MapTestTheme()
        let buffer = drawMap(width: 200, height: 60, theme: theme) { context, size in
            renderer.draw(in: context, camera: MapCamera(center: ParisFixture.centre, zoom: 16), size: size,
                          zoomRange: 0...14, layers: layers) { $0 == tile.id ? tile : nil }
        }
        #expect(renderer.statistics.pointsOfInterestPlaced > 5)
        for point in renderer.placedPointsOfInterest {
            #expect(buffer[point.column, point.row].style.background == theme.background, "\(point.name)'s glyph")
        }
        for label in renderer.placedLabels where label.showsText {
            #expect(buffer[label.column, label.row].style.background == theme.background, "\(label.text)")
        }
    }

    @Test func aPointCanBeFoundByTheCellsItTook() throws {
        let renderer = MapRenderer()
        _ = renderFrame([try ParisFixture.tile()], camera: MapCamera(center: ParisFixture.centre, zoom: 16),
                        width: 200, height: 60, zoomRange: 0...14, renderer: renderer)
        let point = try #require(renderer.placedPointsOfInterest.first { $0.nameColumns != nil })
        #expect(renderer.pointOfInterest(atColumn: point.column, row: point.row)?.name == point.name)
        let name = try #require(point.nameColumns), row = try #require(point.nameRow)
        #expect(renderer.pointOfInterest(atColumn: name.upperBound - 1, row: row)?.name == point.name)
        #expect(point.featureID != nil)
        #expect(ParisFixture.id.bounds.contains(point.coordinate))
    }

    /// The frame's cost at 200 × 60 over central Paris, reported with
    /// `TERMINALUI_MAPS_BENCHMARK=1` and held to a budget then: a timing has
    /// no place in a pass or a fail of the ordinary run on a shared runner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINALUI_MAPS_BENCHMARK"] == "1"),
          arguments: [14.5, 16, 18])
    func benchmark(zoom: Double) throws {
        let tile = try ParisFixture.tile()
        let renderer = MapRenderer()
        let raster = CanvasRaster()
        var environment = EnvironmentValues()
        environment.theme = MapTestTheme()
        let frames = 50
        var camera = MapCamera(center: ParisFixture.centre, zoom: zoom)
        let elapsed = ContinuousClock().measure {
            for _ in 0..<frames {
                raster.begin(width: 200, height: 60, inheritedGround: nil)
                renderer.draw(in: GraphicsContext(raster: raster, environment: environment), camera: camera,
                              size: CanvasSize(width: 200, height: 60), zoomRange: 0...14) {
                    $0 == tile.id ? tile : nil
                }
                var buffer = CellBuffer(width: 200, height: 60)
                raster.composite(into: &buffer, at: Rect(x: 0, y: 0, width: 200, height: 60), style: .plain,
                                 opaque: false)
                camera = camera.panned(byDotsX: 1, y: 0)
            }
        }
        let perFrame = elapsed / frames
        print("Paris frame at 200 × 60, z\(zoom): \(perFrame) (\(renderer.statistics))")
        #expect(perFrame < Self.debugFrameBudget, "a debug build's frame over central Paris")
    }

    /// A debug build's frame: 25 ms was measured at the slowest zoom
    /// (design/maps.md, "Measured"), and the budget is half as
    /// much again, so a regression shows and a busy machine does not.
    static let debugFrameBudget: Duration = .milliseconds(40)
    @Test(.enabled(if: printFrames))
    func printParis() throws {
        let tile = try ParisFixture.tile()
        for zoom in [14.0, 15, 16, 17, 18] {
            let renderer = MapRenderer()
            let buffer = renderFrame([tile], camera: MapCamera(center: ParisFixture.centre, zoom: zoom),
                                     width: 200, height: 60, zoomRange: 0...14, renderer: renderer)
            print("Paris z\(zoom) \(renderer.statistics)\n\(buffer.text)\n")
        }
    }

    @Test(.enabled(if: printFrames))
    func printSample() throws {
        for zoom in [8.0, 10, 12, 14, 16, 18, 20] {
            let renderer = MapRenderer()
            let buffer = sampleFrame(zoom: zoom, renderer: renderer)
            print("Sample z\(zoom) \(renderer.statistics)\n\(buffer.text)\n")
        }
    }
}

/// A frame of the sample town at `zoom`, 100 × 30 cells, the tiles at that
/// zoom cut from the town as the sample source serves them.
@MainActor
func sampleFrame(zoom: Double, centre: GeoCoordinate = SampleTown.origin, width: Int = 100, height: Int = 30,
                 renderer: MapRenderer = MapRenderer()) -> CellBuffer {
    let camera = MapCamera(center: centre, zoom: zoom)
    let size = CanvasSize(width: Double(width), height: Double(height))
    let tiles = MapRenderer.tiles(for: camera, size: size, zoomRange: SampleTileSource.zoomRange).compactMap { id in
        SampleTileSource.tile(for: id).map { RenderTile(id: id, tile: .vector($0)) }
    }
    return renderFrame(tiles, camera: camera, width: width, height: height, zoomRange: SampleTileSource.zoomRange,
                       renderer: renderer)
}
