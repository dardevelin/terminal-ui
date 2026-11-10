import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

/// The ladder design/maps.md writes out: what each zoom adds.
/// A row is the zoom a role first appears at; the test holds `MapRole` to
/// the table, and the frames below hold the sample town to it.
private let ladder: [(zoom: Int, roles: [MapRole])] = [
    (0, [.water, .countryLabel]),
    (3, [.boundary, .regionLabel]),
    (5, [.motorway, .cityLabel]),
    (7, [.trunk, .landcover]),
    (8, [.primary, .rail, .townLabel]),
    (9, [.secondary, .waterway, .waterLabel]),
    (10, [.tertiary, .park, .landuse, .villageLabel]),
    (12, [.minorRoad, .suburbLabel]),
    (13, [.roadLabel, .serviceRoad]),
    (14, [.path, .poiLabel, .lakeLabel]),
    (15, [.building]),
    (17, [.houseNumberLabel]),
]

@Suite("Zoom's level of detail")
@MainActor
struct LevelOfDetailTests {
    @Test func everyRoleSitsOnTheLadderAtItsZoom() {
        var listed: [MapRole] = []
        for step in ladder {
            for role in step.roles {
                #expect(role.minimumZoom == step.zoom, "\(role) appears at \(role.minimumZoom), not \(step.zoom)")
                #expect(!role.isVisible(atZoom: Double(step.zoom) - 0.01))
                #expect(role.isVisible(atZoom: Double(step.zoom)))
                listed.append(role)
            }
        }
        #expect(Set(listed) == Set(MapRole.allCases), "every role is on the ladder once")
        #expect(listed.count == MapRole.allCases.count)
    }

    @Test func atZoomTenTheTownIsNamedAndNothingInIt() {
        let text = sampleFrame(zoom: 10).text
        #expect(text.contains("Millbrook"))
        for detail in ["Silver River", "Duck Pond", "Old Town", "High Street", "Copper Kettle"] {
            #expect(!text.contains(detail), "\(detail) at zoom 10")
        }
    }

    @Test func atZoomTwelveTheSuburbsAndTheRiverAreNamed() {
        let text = sampleFrame(zoom: 12, width: 160, height: 50).text
        #expect(text.contains("Old Town") || text.contains("Parkside") || text.contains("Riverside"))
        #expect(text.contains("Silver River"))
        #expect(!text.contains("Duck Pond"))
    }

    @Test func atZoomFourteenThePondAndThePlacesAppear() {
        let renderer = MapRenderer()
        let text = sampleFrame(zoom: 14, width: 160, height: 50, renderer: renderer).text
        #expect(text.contains("Duck Pond"))
        #expect(renderer.statistics.pointsOfInterestPlaced > 0)
    }

    /// Buildings first draw at 15: a frame at 14 has none of the building
    /// colour, one at 15 has some.
    @Test func buildingsComeInAtZoomFifteen() {
        let building = MapRole.building.colour(in: MapTestTheme())
        func buildingCells(_ zoom: Double) -> Int {
            let buffer = sampleFrame(zoom: zoom, centre: SampleTown.coordinate(east: -600, north: -200))
            var count = 0
            for y in 0..<buffer.height {
                for x in 0..<buffer.width where buffer[x, y].style.background == building
                    || buffer[x, y].style.foreground == building {
                    count += 1
                }
            }
            return count
        }
        #expect(buildingCells(14.5) == 0)
        #expect(buildingCells(16) > 10)
    }

    @Test func houseNumbersComeInAtZoomSeventeen() throws {
        let house = try #require(SampleTown.houses.first { $0.street == "Oak Street" })
        let centre = SampleTown.coordinate(east: house.east, north: house.north)
        #expect(!sampleFrame(zoom: 16.5, centre: centre).text.contains(" \(house.number) "))
        #expect(sampleFrame(zoom: 18, centre: centre).text.contains(String(house.number)))
    }

    /// A street is named wherever it crosses the screen, however close the
    /// camera: across at 18 and 21, down at 19, and more than once along a
    /// long one.
    @Test func roadNamesSurviveEveryZoom() {
        for zoom in [16.0, 18, 19, 20, 21, 22] {
            let text = sampleFrame(zoom: zoom).text
            #expect(text.contains("High Street"), "High Street unnamed at \(zoom)")
            #expect(text.contains("Church Lane"), "Church Lane unnamed at \(zoom)")
        }
        let wide = sampleFrame(zoom: 18, width: 200, height: 20).text
        #expect(wide.components(separatedBy: "High Street").count - 1 >= 2, "a long street is named again along it")
    }

    @Test func aShortLaneGoesUnnamedUntilItIsAsLongAsItsName() {
        // Willow Walk is 570 m: about 3 dots at zoom 10, 60 at 14.
        let walk = SampleTown.coordinate(east: -300, north: 300)
        #expect(!sampleFrame(zoom: 12, centre: walk).text.contains("Willow Walk"))
        #expect(sampleFrame(zoom: 15, centre: walk).text.contains("Willow Walk"))
    }

    @Test func theSampleSourceLeavesTheSmallThingsOutOfItsOuterZooms() throws {
        func layers(_ zoom: Int) -> Set<String> {
            let id = TileID(containing: SampleTown.origin, zoom: zoom)
            return Set(SampleTileSource.tile(for: id)?.layers.map(\.name) ?? [])
        }
        #expect(!layers(12).contains("building"))
        #expect(layers(13).contains("building"))
        #expect(!layers(13).contains("housenumber"))
        #expect(layers(14).contains("housenumber"))
        #expect(!layers(11).contains("poi"))
        #expect(layers(12).contains("poi"))
    }

    /// The sample source ranks its points as OpenMapTiles does: 1 for the
    /// first in each cell of a 6 × 6 grid over the tile.
    @Test func theSampleSourceRanksPointsWithinTheGrid() throws {
        let tile = try #require(SampleTileSource.tile(for: TileID(containing: SampleTown.origin, zoom: 14)))
        let points = try #require(tile.layers.first { $0.name == "poi" }).features
        let side = SampleTileSource.rankGridSide, extent = VectorLayer.defaultExtent
        var byCell: [Int: [Int]] = [:]
        for feature in points {
            let point = try #require(feature.rings.first?.first)
            let cell = min(Int(point.y) * side / extent, side - 1) * side + min(Int(point.x) * side / extent, side - 1)
            byCell[cell, default: []].append(Int(try #require(feature.properties["rank"]?.numberValue)))
        }
        #expect(!byCell.isEmpty)
        for ranks in byCell.values {
            #expect(ranks.sorted() == Array(1...ranks.count))
        }
    }

    // MARK: - Zooming out never blanks

    /// The four children of a tile cached, the tile itself not: they draw
    /// in its place.
    @Test func aMissingTileIsDrawnFromItsCachedChildren() throws {
        let parent = TileID(containing: SampleTown.origin, zoom: 15)
        let children = try parent.children.map { child in
            RenderTile(id: child, tile: .vector(try #require(SampleTileSource.tile(for: child))))
        }
        let camera = MapCamera(center: parent.bounds.center, zoom: 15)
        let renderer = MapRenderer()
        let buffer = renderFrame(children, camera: camera, width: 40, height: 12, zoomRange: 0...22, renderer: renderer)
        #expect(renderer.statistics.descendantTiles >= 1)
        #expect(renderer.statistics.missingTiles == 0)
        #expect(renderer.statistics.featuresDrawn > 0)
        #expect(buffer.text.contains { $0 != " " })
    }

    /// With some children and an ancestor cached, the ancestor fills the
    /// tile, cut to it; with only the children, they draw what they can.
    @Test func partialChildrenGiveWayToAnAncestorAndElseDrawAlone() throws {
        let parent = TileID(containing: SampleTown.origin, zoom: 15)
        let above = try #require(parent.parent)
        let childTile = try #require(SampleTileSource.tile(for: parent.children[0]))
        let aboveTile = try #require(SampleTileSource.tile(for: above))
        let child = RenderTile(id: parent.children[0], tile: .vector(childTile))
        let grandparent = RenderTile(id: above, tile: .vector(aboveTile))
        let camera = MapCamera(center: parent.bounds.center, zoom: 15)
        let withAncestor = MapRenderer()
        _ = renderFrame([child, grandparent], camera: camera, width: 20, height: 6, zoomRange: 0...22,
                        renderer: withAncestor)
        #expect(withAncestor.statistics.fallbackTiles >= 1)
        let alone = MapRenderer()
        _ = renderFrame([child], camera: camera, width: 20, height: 6, zoomRange: 0...22, renderer: alone)
        #expect(alone.statistics.descendantTiles >= 1)
    }

    /// Through the store, as a running map has it: at zoom 15 its tiles
    /// land; zoomed out, the source holds the zoom-14 tiles back, and the
    /// frame still draws the town from the zoom-15 tiles it kept.
    @Test func zoomingOutWhileTilesLoadNeverBlanksTheMap() async throws {
        let source = GatedSource(zoomRange: 0...22)
        let store = MapTileStore(source: source)
        #expect(await waitUntil { store.info != nil })
        let size = CanvasSize(width: 40, height: 12)
        let close = MapCamera(center: SampleTown.origin, zoom: 15)
        _ = store.prepareFrame(camera: close, size: size)
        let closeTiles = MapRenderer.tiles(for: close, size: size, zoomRange: 0...22)
        #expect(await waitUntil { Set(source.waiting).isSuperset(of: closeTiles) })
        for id in closeTiles {
            source.release(id, with: SampleTileSource.tile(for: id).map(MapTile.vector))
        }
        #expect(await waitUntil { store.cachedTiles.isSuperset(of: closeTiles) })

        let far = close.zoomed(by: -1)
        let renderer = MapRenderer()
        let buffer = drawMap(width: 40, height: 12) { context, size in
            store.draw(with: renderer, in: context, camera: far, size: size)
        }
        let farTiles = MapRenderer.tiles(for: far, size: size, zoomRange: 0...22)
        #expect(store.cachedTiles.isDisjoint(with: farTiles), "the zoom-14 tiles are still on their way")
        #expect(renderer.statistics.descendantTiles >= 1)
        #expect(renderer.statistics.featuresDrawn > 0)
        #expect(buffer.text.contains { $0 != " " }, "the frame is not blank")
    }

    // MARK: - Steps

    @Test func bracketsZoomHalfALevelAndShiftedWheelAQuarter() throws {
        let camera = MapCamera(center: SampleTown.origin, zoom: 15)
        let viewport = DotSize(width: 80, height: 48)
        let finer = try #require(MapView.camera(camera, movedBy: KeyEvent(key: .character("]")), in: viewport))
        #expect(finer.zoom == 15.5)
        let coarser = try #require(MapView.camera(camera, movedBy: KeyEvent(key: .character("[")), in: viewport))
        #expect(coarser.zoom == 14.5)
        let whole = try #require(MapView.camera(camera, movedBy: KeyEvent(key: .character("+")), in: viewport))
        #expect(whole.zoom == 16)
        #expect(MapView.Steps.fineWheelZoom * 3 == 0.25, "a notch is three steps")
    }

    @Test func aFlyToTakesItsTargetZoom() {
        let camera = MapCamera(center: SampleTown.origin, zoom: 12)
        let target = SampleTown.coordinate(east: 300, north: 0)
        let flown = camera.centred(on: target, zoom: 17.25)
        #expect(flown.zoom == 17.25)
        #expect(abs(flown.center.latitude - target.latitude) < 1e-9)
        #expect(camera.centred(on: target).zoom == 12)
        #expect(camera.centred(on: target, zoom: 40).zoom == MapCamera.defaultZoomRange.upperBound)
    }
}
