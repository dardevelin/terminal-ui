import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

@Suite("A turned camera")
struct CameraBearingTests {
    private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
    private let viewport = DotSize(width: 80, height: 48)

    @Test func atNinetyDegreesEastIsUp() {
        let camera = MapCamera(center: centre, zoom: 16, bearing: 90)
        let east = camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 90, distance: 20), in: viewport)
        let north = camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 0, distance: 20), in: viewport)
        #expect(abs(east.x - 40) < 0.01 && east.y < 24)
        #expect(abs(north.y - 24) < 0.01 && north.x < 40, "north is to the left")
    }

    @Test(arguments: [0.0, 37, 90, 211.5])
    func screenAndGroundAgreeWhateverTheBearing(bearing: Double) {
        let camera = MapCamera(center: centre, zoom: 15.3, bearing: bearing)
        for point in [DotPoint(x: 3, y: 7), DotPoint(x: 70, y: 40), DotPoint(x: 40, y: 24)] {
            let back = camera.screenPoint(for: camera.coordinate(at: point, in: viewport), in: viewport)
            #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
        }
    }

    @Test func aDragMovesTheMapWithThePointer() {
        // Whatever the bearing, the ground under the pointer stays under it.
        let camera = MapCamera(center: centre, zoom: 15, bearing: 120)
        let grabbed = camera.coordinate(at: DotPoint(x: 20, y: 10), in: viewport)
        let moved = camera.panned(byDotsX: 6, y: -4)
        let landed = moved.screenPoint(for: grabbed, in: viewport)
        #expect(abs(landed.x - 26) < 1e-6 && abs(landed.y - 6) < 1e-6)
    }

    @Test func zoomingAboutThePointerKeepsItsGroundTurned() {
        let camera = MapCamera(center: centre, zoom: 15, bearing: 300)
        let anchor = DotPoint(x: 66, y: 9)
        let ground = camera.coordinate(at: anchor, in: viewport)
        let zoomed = camera.zoomed(by: 1, about: anchor, in: viewport)
        let landed = zoomed.screenPoint(for: ground, in: viewport)
        #expect(abs(landed.x - anchor.x) < 1e-6 && abs(landed.y - anchor.y) < 1e-6)
        #expect(zoomed.bearing == 300)
    }

    @Test func theTilesCoverTheTurnedView() {
        // A wide view turned a quarter is tall on the ground: the tiles
        // must reach as far north and south as it is wide.
        let wide = DotSize(width: 600, height: 40)
        let north = MapCamera(center: centre, zoom: 15)
        let turned = MapCamera(center: centre, zoom: 15, bearing: 90)
        let northRows = Set(north.coveringTiles(in: wide).map(\.y))
        let turnedRows = Set(turned.coveringTiles(in: wide).map(\.y))
        #expect(turnedRows.count > northRows.count)
        let box = turned.visibleRect(in: wide)
        #expect(box.north - box.south > box.east - box.west)
    }

    @Test func aBearingIsKeptWithinATurn() {
        var camera = MapCamera(center: centre, zoom: 15, bearing: -90)
        #expect(camera.bearing == 270)
        camera.bearing = 725
        #expect(camera.bearing == 5)
    }
}

@Suite("The renderer turned")
@MainActor
struct TurnedRendererTests {
    private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
    private let width = 40, height = 12

    private func isBraille(_ cell: Cell) -> Bool {
        guard let scalar = cell.character.unicodeScalars.first else { return false }
        return (0x2801...0x28FF).contains(scalar.value)
    }

    /// A road running north–south through the centre, on its tile.
    private func northSouthRoad() -> RenderTile {
        let tile = TileID(containing: centre, zoom: 14)
        let north = tile.tilePoint(for: GeoMeasure.destination(from: centre, bearing: 0, distance: 120),
                                   extent: VectorLayer.defaultExtent)
        let south = tile.tilePoint(for: GeoMeasure.destination(from: centre, bearing: 180, distance: 120),
                                   extent: VectorLayer.defaultExtent)
        let layer = VectorLayer(name: "transportation",
                                features: [.line([[north, south]], properties: ["class": "primary"])])
        return RenderTile(id: tile, tile: .vector(VectorTile(layers: [layer])))
    }

    private func draw(bearing: Double, content: [MapElement] = []) -> CellBuffer {
        let tile = northSouthRoad()
        let camera = MapCamera(center: centre, zoom: 16, bearing: bearing)
        return drawMap(width: width, height: height) { context, size in
            MapRenderer().draw(in: context, camera: camera, size: size, zoomRange: 0...14, content: content) {
                $0 == tile.id ? tile : nil
            }
        }
    }

    @Test func aNorthSouthRoadLiesAcrossAMapTurnedAQuarter() {
        let upright = draw(bearing: 0)
        #expect(isBraille(upright[20, 1]) && isBraille(upright[20, 10]))
        #expect(!isBraille(upright[5, 6]))
        let turned = draw(bearing: 90)
        #expect(isBraille(turned[5, 6]) && isBraille(turned[34, 6]), "the road now runs along the middle row")
        #expect(!isBraille(turned[20, 1]))
    }

    @Test func theTravellerIsAnArrowTheirWayAndRouteBehindIsDimmer() {
        let behind = GeoMeasure.destination(from: centre, bearing: 180, distance: 100)
        let ahead = GeoMeasure.destination(from: centre, bearing: 0, distance: 100)
        let buffer = draw(bearing: 0, content: [
            .polyline(MapPolyline(coordinates: [behind, centre], style: .travelled)),
            .polyline(MapPolyline(coordinates: [centre, ahead])),
            .traveller(TravellerMarker(coordinate: centre, course: 0)),
        ])
        #expect(buffer[20, 6].character == "↑")
        #expect(buffer[20, 6].style.background == MapTestTheme().info)
        let theme = MapTestTheme()
        #expect(buffer[20, 2].style.foreground == theme.accent)
        #expect(buffer[20, 9].style.foreground == theme.accent.blended(with: theme.background, amount: 0.6))
    }
}
