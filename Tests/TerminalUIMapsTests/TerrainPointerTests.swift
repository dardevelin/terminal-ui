import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// On a realistic map with terrain, the pointer meets the ground the view
// shows: what a click lands on, what a drag holds under the pointer, what
// the wheel zooms about — the hill's face, not the plane beneath it.
@Suite("The pointer on terrain")
struct TerrainPointerTests {
    private let centre = GeoCoordinate(latitude: 0.02, longitude: 0.02)
    private let viewport = DotSize(columns: 100, rows: 30)

    /// A 300 m ridge running east to west 300 m north of the centre, at
    /// every zoom from 10 to 15.
    private var ridge: TerrainSampler {
        let centre = centre
        return TerrainSampler(zoomRange: 10...15) { id in
            let samples = 64
            var metres = [Float]()
            for row in 0..<samples {
                for column in 0..<samples {
                    let extent = 4096
                    let point = TilePoint(x: Int32((Double(column) + 0.5) / Double(samples) * Double(extent)),
                                          y: Int32((Double(row) + 0.5) / Double(samples) * Double(extent)))
                    let north = (id.coordinate(of: point, extent: extent).latitude - centre.latitude)
                        * GeoMeasure.meanEarthRadius * .pi / 180
                    metres.append(Float(300 * exp(-((north - 300) * (north - 300)) / (2 * 120 * 120))))
                }
            }
            return ElevationTile(checkedWidth: samples, height: samples, metres: metres)
        }
    }

    /// Where the ground at `world` is drawn through `camera`.
    private func drawn(_ world: WorldPoint, by camera: MapCamera) -> DotPoint? {
        let field = ElevationField(camera: camera, viewport: viewport, sampler: ridge)
        let northUp = camera.northUpPoint(forWorld: world, in: viewport)
        return TerrainProjection(camera: camera, viewport: viewport, field: field)
            .toScreen(x: northUp.x, y: northUp.y, height: field.height(x: northUp.x, y: northUp.y))
            .map { DotPoint(x: $0.x, y: $0.y) }
    }

    @Test func theSamplerReadsTheFinestTileAtHand() {
        let coarse = TerrainSampler(zoomRange: 10...15) { id in
            id.zoom == 12 ? ElevationTile(checkedWidth: 1, height: 1, metres: [12]) : nil
        }
        #expect(coarse.metres(at: WebMercator.project(centre)) == 12)
        let both = TerrainSampler(zoomRange: 10...15) { id in
            ElevationTile(checkedWidth: 1, height: 1, metres: [Float(id.zoom)])
        }
        #expect(both.metres(at: WebMercator.project(centre)) == 15, "the finest zoom first")
        #expect(TerrainSampler(zoomRange: 10...15) { _ in nil }.metres(at: WebMercator.project(centre)) == nil)
    }

    @Test func aClickLandsOnTheHillsFace() {
        let camera = MapCamera(center: centre, zoom: 15, pitch: 55)
        let cell = Point(x: 50, y: 6)
        let flat = camera.coordinate(atCell: cell, in: CanvasSize(width: 100, height: 30))
        let ground = camera.coordinate(atCell: cell, in: CanvasSize(width: 100, height: 30), terrain: ridge)
        #expect(ground.latitude < flat.latitude, "the ridge's near face stands before the plane's point")
    }

    @Test(arguments: [(DotPoint(x: 100, y: 40), DotPoint(x: 130, y: 70)),
                      (DotPoint(x: 60, y: 90), DotPoint(x: 140, y: 30))])
    func aDragKeepsTheGroundUnderThePointer(from: DotPoint, to: DotPoint) throws {
        // The camera's heights are measured from the ground under its
        // centre, which the drag moves; the grabbed ground still ends up
        // under the pointer.
        let camera = MapCamera(center: centre, zoom: 15, bearing: 20, pitch: 50)
        let grabbed = camera.groundWorldPoint(at: from, in: viewport, terrain: ridge)
        let moved = camera.panned(dragging: from, to: to, in: viewport, terrain: ridge)
        let landed = try #require(drawn(grabbed, by: moved))
        #expect(abs(landed.x - to.x) < 0.5 && abs(landed.y - to.y) < 0.5, "drawn at \(landed), not \(to)")
    }

    @Test func theWheelZoomsAboutTheGroundUnderThePointer() throws {
        let camera = MapCamera(center: centre, zoom: 15, pitch: 50)
        let anchor = DotPoint(x: 150, y: 20)
        let ground = camera.groundWorldPoint(at: anchor, in: viewport, terrain: ridge)
        let zoomed = camera.zoomed(by: 1, about: anchor, in: viewport, terrain: ridge)
        let landed = try #require(drawn(ground, by: zoomed))
        #expect(abs(landed.x - anchor.x) < 0.5 && abs(landed.y - anchor.y) < 0.5, "drawn at \(landed)")
        #expect(zoomed.zoom == 16)
    }

    @Test func withoutTerrainEveryOneIsThePlanesOwn() {
        let camera = MapCamera(center: centre, zoom: 15, bearing: 20, pitch: 50)
        let none = TerrainSampler(zoomRange: 10...15) { _ in nil }
        let from = DotPoint(x: 100, y: 40), to = DotPoint(x: 130, y: 70)
        #expect(camera.panned(dragging: from, to: to, in: viewport, terrain: none)
                    == camera.panned(dragging: from, to: to, in: viewport))
    }

    @Test @MainActor func aTapOnFlatLayersIsThePlanesOwn() {
        let camera = MapCamera(center: centre, zoom: 15, pitch: 40)
        let size = CanvasSize(width: 100, height: 30)
        let cell = Point(x: 30, y: 8)
        #expect(camera.coordinate(atCell: cell, in: size, layers: .explore) == camera.coordinate(atCell: cell, in: size))
        var realistic = MapLayers.explore
        realistic.elevation = .realistic
        #expect(camera.coordinate(atCell: cell, in: size, layers: realistic) == camera.coordinate(atCell: cell, in: size),
                "realistic with no terrain layer is still a plane")
    }
}
