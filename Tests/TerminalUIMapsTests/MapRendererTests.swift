import Foundation
import Testing
@testable import TerminalUI
import TerminalUIIO
@testable import TerminalUIMaps

// The renderer is checked at the cells it leaves: where a road's dots land,
// which background a park gives, which names are drawn and where. A camera
// at zoom z on a tile of zoom z has the tile 256 dots, 128 columns, across,
// so a small canvas sits well inside one tile.

private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
private let tileZoom = 14
private let centreTile = TileID(containing: centre, zoom: tileZoom)
private let extent = VectorLayer.defaultExtent

private func tilePoint(_ coordinate: GeoCoordinate, in tile: TileID = centreTile) -> TilePoint {
    tile.tilePoint(for: coordinate, extent: extent)
}

/// A coordinate `east` and `south` dots from `centre` at `zoom`.
private func offset(east: Double, south: Double, zoom: Double = Double(tileZoom)) -> GeoCoordinate {
    let camera = MapCamera(center: centre, zoom: zoom)
    let viewport = DotSize(width: 0, height: 0)
    return camera.coordinate(at: DotPoint(x: east, y: south), in: viewport)
}

private func line(_ layer: String, class featureClass: String, _ points: [TilePoint],
                  name: String? = nil) -> VectorLayer {
    var properties: [String: VectorValue] = ["class": .string(featureClass)]
    if let name { properties["name"] = .string(name) }
    return VectorLayer(name: layer, features: [.line([points], properties: properties)])
}

/// A square of the tile's own units, wound as an exterior ring.
private func square(_ layer: String, class featureClass: String, from low: Int32 = -64,
                    to high: Int32 = Int32(extent) + 64) -> VectorLayer {
    let ring = [TilePoint(x: low, y: low), TilePoint(x: high, y: low), TilePoint(x: high, y: high),
                TilePoint(x: low, y: high)]
    return VectorLayer(name: layer, features: [VectorFeature(polygons: [VectorPolygon(exterior: ring)],
                                                             properties: ["class": .string(featureClass)])])
}

private func place(_ name: String, class featureClass: String, at point: TilePoint) -> VectorFeature {
    .point(point, properties: ["name": .string(name), "class": .string(featureClass)])
}

private func renderTile(_ layers: [VectorLayer], id: TileID = centreTile) -> RenderTile {
    RenderTile(id: id, tile: .vector(VectorTile(layers: layers)))
}

/// A theme of distinct colours, so a cell's colour names the role it came
/// from.
struct MapTestTheme: Theme {
    var background: Color = .rgb(12, 14, 18)
    var foreground: Color = .rgb(220, 222, 226)
    var warning: Color = .rgb(232, 176, 32)
    var info: Color = .rgb(64, 128, 232)
    var success: Color = .rgb(48, 176, 72)
    var accent: Color = .rgb(240, 64, 160)
    var attention: Color = .rgb(250, 120, 40)
}

/// The same roles on a light ground.
struct MapLightTestTheme: Theme {
    var background: Color = .rgb(248, 246, 240)
    var foreground: Color = .rgb(30, 32, 36)
    var warning: Color = .rgb(176, 112, 0)
    var info: Color = .rgb(24, 88, 200)
    var success: Color = .rgb(32, 128, 48)
    var accent: Color = .rgb(200, 30, 120)
}

/// Draw a frame into a canvas of `width` × `height` cells and return its
/// cells.
@MainActor
func drawMap(width: Int, height: Int, theme: any Theme = MapTestTheme(),
             _ draw: (GraphicsContext, CanvasSize) -> Void) -> CellBuffer {
    let raster = CanvasRaster()
    raster.begin(width: width, height: height, inheritedGround: theme.background)
    var environment = EnvironmentValues()
    environment.theme = theme
    draw(GraphicsContext(raster: raster, environment: environment),
         CanvasSize(width: Double(width), height: Double(height)))
    var buffer = CellBuffer(width: width, height: height)
    raster.composite(into: &buffer, at: Rect(x: 0, y: 0, width: width, height: height),
                     style: Style(foreground: nil, background: theme.background, bold: false, italic: false,
                                  underline: false), opaque: true)
    return buffer
}

private func isBraille(_ cell: Cell) -> Bool {
    guard let scalar = cell.character.unicodeScalars.first else { return false }
    return (0x2801...0x28FF).contains(scalar.value)
}

extension CellBuffer {
    func row(_ y: Int) -> String { String((0..<width).map { self[$0, y].character }) }
}

@Suite("The map renderer")
@MainActor
struct MapRendererTests {
    private let width = 40
    private let height = 12

    private func draw(_ tiles: [RenderTile], camera: MapCamera = MapCamera(center: centre, zoom: Double(tileZoom)),
                      zoomRange: ClosedRange<Int> = 0...tileZoom, content: [MapElement] = [],
                      theme: any Theme = MapTestTheme(),
                      renderer: MapRenderer = MapRenderer()) -> CellBuffer {
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return drawMap(width: width, height: height, theme: theme) { context, size in
            renderer.draw(in: context, camera: camera, size: size, zoomRange: zoomRange, content: content) {
                byID[$0]
            }
        }
    }

    @Test func aRoadLandsWhereTheProjectionPutsIt() {
        // 40 × 12 cells is 80 × 48 dots; the centre is dot (40, 24), in cell
        // (20, 6). A road from 30 dots west to 30 east of it, along its row.
        let west = tilePoint(offset(east: -30, south: 0)), east = tilePoint(offset(east: 30, south: 0))
        let buffer = draw([renderTile([line("transportation", class: "primary", [west, east])])])
        #expect(isBraille(buffer[20, 6]))
        #expect(buffer[20, 6].style.foreground == MapTestTheme().warning)
        #expect(isBraille(buffer[6, 6]), "30 dots west is column 5, the road's end")
        #expect(!isBraille(buffer[2, 6]), "the road stops where it ends")
        #expect(!isBraille(buffer[20, 3]), "and nothing is drawn off its row")
    }

    @Test func aParkIsABackgroundFill() {
        let buffer = draw([renderTile([square("park", class: "park")])])
        let parkColour = MapTestTheme().successSubtle
        #expect(buffer[20, 6].character == " ")
        #expect(buffer[20, 6].style.background == parkColour)
        #expect(buffer[0, 0].style.background == parkColour)
        #expect(parkColour != MapTestTheme().background)
    }

    @Test func aRoadOverAParkKeepsThePark() {
        let west = tilePoint(offset(east: -30, south: 0)), east = tilePoint(offset(east: 30, south: 0))
        let buffer = draw([renderTile([square("park", class: "park"),
                                       line("transportation", class: "minor", [west, east])])])
        #expect(isBraille(buffer[20, 6]))
        #expect(buffer[20, 6].style.background == MapTestTheme().successSubtle)
    }

    @Test func eachRoleTakesItsThemesColourInDarkAndLight() {
        let tile = renderTile([square("water", class: "lake")])
        let dark = draw([tile], theme: MapTestTheme())
        let light = draw([tile], theme: MapLightTestTheme())
        #expect(dark[20, 6].style.background == MapTestTheme().infoSubtle)
        #expect(light[20, 6].style.background == MapLightTestTheme().infoSubtle)
        #expect(dark[20, 6].style.background != light[20, 6].style.background)
    }

    @Test func aRoleBelowItsZoomIsNotDrawn() {
        let tile = renderTile([square("building", class: "")], id: TileID(containing: centre, zoom: 12))
        let buffer = draw([tile], camera: MapCamera(center: centre, zoom: 12), zoomRange: 0...12)
        #expect(buffer[20, 6].style.background == MapTestTheme().background)
    }

    @Test func labelsNeverOverlap() {
        // A crowd of names around the centre, most of which cannot all fit.
        var features: [VectorFeature] = []
        for index in 0..<30 {
            let point = tilePoint(offset(east: Double(index % 6 - 3) * 6, south: Double(index / 6 - 2) * 4))
            features.append(place("Place \(index)", class: index.isMultiple(of: 3) ? "town" : "suburb", at: point))
        }
        let renderer = MapRenderer()
        let buffer = draw([renderTile([VectorLayer(name: "place", features: features)])], renderer: renderer)
        let placed = renderer.placedLabels
        #expect(placed.count > 1)
        #expect(placed.count < features.count, "a crowd this close cannot all be named")
        for (index, label) in placed.enumerated() {
            for other in placed[(index + 1)...] where other.row == label.row {
                let apart = other.column >= label.column + label.width || label.column >= other.column + other.width
                #expect(apart, "\(label.text) and \(other.text) overlap on row \(label.row)")
            }
            let drawn = buffer.row(label.row)
            let start = drawn.index(drawn.startIndex, offsetBy: label.column)
            #expect(drawn[start...].hasPrefix(label.text), "\(label.text) is drawn where it was placed")
        }
    }

    @Test func aPlacersMeasurementsAreKeptAcrossFrames() {
        let renderer = MapRenderer()
        let tile = renderTile([VectorLayer(name: "place", features: [
            place("Millbrook", class: "town", at: tilePoint(centre)),
        ])])
        _ = draw([tile], renderer: renderer)
        _ = draw([tile], camera: MapCamera(center: offset(east: 4, south: 4), zoom: Double(tileZoom)),
                 renderer: renderer)
        #expect(renderer.labelMeasurements == 1)
    }

    @Test func aMissingTileIsDrawnFromItsCachedAncestor() {
        let parent = centreTile.parent!
        let renderer = MapRenderer()
        let buffer = draw([renderTile([square("park", class: "park")], id: parent)], renderer: renderer)
        #expect(buffer[20, 6].style.background == MapTestTheme().successSubtle)
        #expect(renderer.statistics.fallbackTiles >= 1)
        #expect(renderer.statistics.tilesDrawn == 0)
    }

    @Test func anAncestorIsDrawnOnlyWhereItsDescendantsAreMissing() {
        // The centre tile has water; its parent, cached, has a park. Where
        // the centre tile is, the water shows, not the park beneath it.
        let renderer = MapRenderer()
        let buffer = draw([renderTile([square("water", class: "lake")]),
                           renderTile([square("park", class: "park")], id: centreTile.parent!)], renderer: renderer)
        #expect(buffer[20, 6].style.background == MapTestTheme().infoSubtle)
    }

    @Test func pastTheSourcesLastZoomItsLastTilesAreDrawnLarger() {
        let camera = MapCamera(center: centre, zoom: 16.5)
        let west = tilePoint(offset(east: -30, south: 0, zoom: 16.5))
        let east = tilePoint(offset(east: 30, south: 0, zoom: 16.5))
        let buffer = draw([renderTile([line("transportation", class: "primary", [west, east])])],
                          camera: camera, zoomRange: 0...tileZoom)
        #expect(MapRenderer.tiles(for: camera, size: CanvasSize(width: 40, height: 12), zoomRange: 0...tileZoom)
            .allSatisfy { $0.zoom == tileZoom })
        #expect(isBraille(buffer[20, 6]))
        #expect(!isBraille(buffer[2, 6]))
    }

    @Test func featuresOffScreenAreCulledAndPointsWithinADotDropped() {
        var wiggle: [TilePoint] = []
        let origin = tilePoint(centre)
        for step in 0..<500 {
            wiggle.append(TilePoint(x: origin.x + Int32(step % 2), y: origin.y))
        }
        let far = [tilePoint(offset(east: 300, south: 0)), tilePoint(offset(east: 310, south: 0))]
        let renderer = MapRenderer()
        _ = draw([renderTile([VectorLayer(name: "transportation", features: [
            .line([wiggle], properties: ["class": "minor"]),
            .line([far], properties: ["class": "minor"]),
        ])])], renderer: renderer)
        #expect(renderer.statistics.featuresCulled == 1)
        #expect(renderer.statistics.featuresDrawn == 1)
        #expect(renderer.statistics.verticesDrawn == 2, "a line within a dot is its two ends")
        #expect(renderer.statistics.verticesDropped == 498)
    }

    @Test func aMarkerIsPinnedAtItsCoordinateWithItsTitleBesideIt() {
        let buffer = draw([], content: Marker("Café", coordinate: centre).mapElements)
        #expect(buffer[20, 6].character == "●")
        #expect(buffer[20, 6].style.foreground == MapTestTheme().accent)
        #expect(buffer.row(6).contains("● Café"))
    }

    @Test func aPolylineIsStrokedThroughItsCoordinates() {
        let polyline = MapPolyline(coordinates: [offset(east: -20, south: 0), offset(east: 20, south: 0)])
        let buffer = draw([], content: polyline.mapElements)
        #expect(isBraille(buffer[20, 6]))
        #expect(buffer[20, 6].style.foreground == MapTestTheme().accent)
        #expect(!isBraille(buffer[20, 2]))
    }

    @Test func aPictureTileIsDrawnInHalfBlocks() throws {
        // Two pixels: red over blue. At zoom 14.0 on a 12-row canvas the
        // tile's top half covers the top rows from the centre up.
        let pixels: [UInt8] = [200, 0, 0, 255, 0, 0, 200, 255]
        let image = try ImageBuffer(rgba: pixels, width: 1, height: 2)
        let tile = RenderTile(id: centreTile, tile: .raster(image))
        let camera = MapCamera(center: centreTile.bounds.center, zoom: Double(tileZoom))
        let buffer = draw([tile], camera: camera)
        #expect(buffer[20, 2].style.background == .rgb(204, 4, 4))
        #expect(buffer[20, 9].style.background == .rgb(4, 4, 204))
    }

    @Test func noTilesDrawsNothingAndDoesNotTrap() {
        let renderer = MapRenderer()
        let buffer = draw([], renderer: renderer)
        #expect(buffer[20, 6].style.background == MapTestTheme().background)
        #expect(renderer.statistics.missingTiles >= 1)
        let empty = drawMap(width: 0, height: 0) { context, size in
            renderer.draw(in: context, camera: MapCamera(center: centre, zoom: 3), size: size,
                          zoomRange: 0...14) { _ in nil }
        }
        #expect(empty.width == 0)
    }
}

@Suite("The map renderer on a real tile")
@MainActor
struct MapRendererFixtureTests {
    static func fixtureTile() throws -> RenderTile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/openfreemap-14-7812-6233.pbf.gz")
        let tile = try VectorTileDecoder.decode(Array(try Data(contentsOf: url)))
        return RenderTile(id: TileID(zoom: 14, x: 7812, y: 6233), tile: .vector(tile))
    }

    @Test func aRealTileDrawsItsRoadsWaterAndNames() throws {
        let tile = try Self.fixtureTile()
        let camera = MapCamera(center: tile.id.bounds.center, zoom: 14.5)
        let renderer = MapRenderer()
        let buffer = drawMap(width: 200, height: 60) { context, size in
            renderer.draw(in: context, camera: camera, size: size, zoomRange: 0...14) { $0 == tile.id ? tile : nil }
        }
        #expect(renderer.statistics.featuresDrawn > 100)
        #expect(renderer.statistics.labelsPlaced > 5)
        let water = MapTestTheme().infoSubtle
        var waterCells = 0, brailleCells = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                if buffer[x, y].style.background == water { waterCells += 1 }
                if isBraille(buffer[x, y]) { brailleCells += 1 }
            }
        }
        #expect(waterCells > 100, "where the Zêzere meets the Tejo")
        #expect(brailleCells > 500)
    }

    /// The frame's cost at 200 × 60 over a real z14 tile, reported with
    /// `TERMINALUI_MAPS_BENCHMARK=1`: a timing has no place in a pass or a
    /// fail on a shared runner.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMINALUI_MAPS_BENCHMARK"] == "1"))
    func benchmark() throws {
        let tile = try Self.fixtureTile()
        let renderer = MapRenderer()
        let raster = CanvasRaster()
        var environment = EnvironmentValues()
        environment.theme = MapTestTheme()
        let frames = 50
        let clock = ContinuousClock()
        var camera = MapCamera(center: tile.id.bounds.center, zoom: 14.5)
        let elapsed = clock.measure {
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
        print("map frame at 200 × 60 over a z14 tile: \(elapsed / frames) (\(renderer.statistics))")
    }
}
