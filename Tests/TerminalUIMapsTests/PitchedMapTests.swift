import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// A pitched frame, drawn: the ground runs to the top of the view, the far
// part of it from coarser tiles, and a route's line and a marker land
// where the camera says they do.
@Suite("A pitched map")
@MainActor
struct PitchedMapTests {
    private let size = CanvasSize(width: 100, height: 30)

    private func frame(_ camera: MapCamera, renderer: MapRenderer = MapRenderer(),
                       content: [MapElement] = []) -> (buffer: CellBuffer, tiles: [TileID]) {
        let ids = MapRenderer.tiles(for: camera, size: size, zoomRange: SampleTileSource.zoomRange)
        let tiles = ids.compactMap { id in SampleTileSource.tile(for: id).map { RenderTile(id: id, tile: .vector($0)) } }
        let buffer = renderFrame(tiles, camera: camera, width: Int(size.width), height: Int(size.height),
                                 zoomRange: SampleTileSource.zoomRange, renderer: renderer, content: content)
        if printFrames { print("Pitched \(camera.pitch)° \(renderer.statistics)\n\(buffer.text)\n") }
        return (buffer, ids)
    }

    private func elements(@MapContentBuilder _ content: () -> MapContentGroup) -> [MapElement] {
        content().mapElements
    }

    private func drawnCells(_ buffer: CellBuffer, rows: Range<Int>) -> Int {
        rows.reduce(0) { count, row in count + buffer.row(row).filter { $0 != " " }.count }
    }

    @Test func theGroundRunsToTheTopOfTheView() {
        let renderer = MapRenderer()
        let camera = MapCamera(center: SampleTown.origin, zoom: 16, bearing: 30, pitch: MapCamera.maximumPitch)
        let (buffer, ids) = frame(camera, renderer: renderer)
        #expect(renderer.statistics.missingTiles == 0)
        #expect(renderer.statistics.tilesDrawn == ids.count)
        #expect(drawnCells(buffer, rows: 0..<3) > 0, "the far ground is drawn in the top rows")
        #expect(drawnCells(buffer, rows: 27..<30) > 0, "and the near ground in the bottom ones")
    }

    @Test func aRouteAndAMarkerLandWhereTheCameraSays() throws {
        let camera = MapCamera(center: SampleTown.origin, zoom: 16, pitch: 50)
        let viewport = MapRenderer.viewport(for: size)
        let ahead = SampleTown.coordinate(east: 0, north: 150)
        let content = elements {
            Marker("Mill", coordinate: ahead)
            MapPolyline(coordinates: [SampleTown.coordinate(east: -40, north: -60), ahead])
        }
        let (buffer, _) = frame(camera, content: content)
        let point = try #require(camera.screenPoint(for: ahead, in: viewport))
        let row = Int(point.y / Double(BrailleCell.dotRows))
        #expect(row < Int(size.height) / 2, "ground ahead is drawn above the middle")
        #expect(buffer.row(row).contains("Mill"), "the marker's name is on its row")
    }

    @Test func groundBehindTheEyeLeavesNoMark() {
        // A line from behind the eye to ahead of it: only the part the view
        // shows is drawn, and nothing of it folds over from behind.
        let camera = MapCamera(center: SampleTown.origin, zoom: 17, pitch: MapCamera.maximumPitch)
        let behind = SampleTown.coordinate(east: 0, north: -3_000)
        let line = elements { MapPolyline(coordinates: [behind, SampleTown.coordinate(east: 0, north: 40)]) }
        let renderer = MapRenderer()
        let viewport = MapRenderer.viewport(for: size)
        #expect(camera.screenPoint(for: behind, in: viewport) == nil)
        let (buffer, _) = frame(camera, renderer: renderer, content: line)
        let withoutLine = frame(camera).buffer
        #expect(buffer.text != withoutLine.text, "the visible part is drawn")
        #expect(drawnCells(buffer, rows: 0..<5) == drawnCells(withoutLine, rows: 0..<5),
                "the line ends 40 m ahead, below the top rows")
    }

    @Test func farGroundIsNamedAsItsOwnZoomWouldName() {
        // At zoom 17 house numbers show; the far ground of a pitched view
        // is drawn at a zoom or more less, where they do not, and its
        // labels follow the scale it is drawn at, not the middle's.
        let camera = MapCamera(center: SampleTown.origin, zoom: 17, pitch: MapCamera.maximumPitch)
        let (buffer, _) = frame(camera)
        let isNumber = { (word: Substring) in !word.isEmpty && word.allSatisfy(\.isNumber) }
        let farNumbers = (0..<6).flatMap { buffer.row($0).split(whereSeparator: { !$0.isNumber }).filter(isNumber) }
        let nearNumbers = (20..<30).flatMap { buffer.row($0).split(whereSeparator: { !$0.isNumber }).filter(isNumber) }
        #expect(farNumbers.isEmpty, "house numbers in the far rows: \(farNumbers)")
        #expect(!nearNumbers.isEmpty, "house numbers are still drawn near")
    }
}
