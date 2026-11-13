import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// The ground of a realistic map with a terrain layer is a surface: a point
// of it is drawn where the map's one 3D camera sees it at its height, and a
// point of the screen is the ground the view ray meets first — a hill's
// face before what stands behind it.
@Suite("Terrain projection")
struct TerrainProjectionTests {
    private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
    private let viewport = DotSize(columns: 100, rows: 30)

    /// A field over the whole view from one tile of `samples` a side whose
    /// heights `metres` gives from the unit square, the reference at the
    /// view's middle.
    private func field(samples: Int = 65, dotsPerMetre: Double = 1,
                       _ metres: (Double, Double) -> Double) -> ElevationField {
        var heights = [Float]()
        for row in 0..<samples {
            for column in 0..<samples {
                heights.append(Float(metres((Double(column) + 0.5) / Double(samples),
                                            (Double(row) + 0.5) / Double(samples))))
            }
        }
        let tile = ElevationTile(checkedWidth: samples, height: samples, metres: heights)
        // The tile spans 600 dots, centred on the view's middle.
        let patch = ElevationField.Patch(originX: viewport.width / 2 - 300, originY: viewport.height / 2 - 300,
                                         side: 600, tile: tile)
        return ElevationField(patches: [patch], dotsPerMetre: dotsPerMetre,
                              referenceX: viewport.width / 2, referenceY: viewport.height / 2)
    }

    /// A round hill north of the middle, 60 m above the plain.
    private func hill(_ unitX: Double, _ unitY: Double) -> Double {
        let east = unitX - 0.5, south = unitY - 0.35
        return 20 + 60 * exp(-(east * east + south * south) / (2 * 0.06 * 0.06))
    }

    @Test func heightsAreMeasuredFromTheGroundUnderTheMiddle() {
        let slope = field(dotsPerMetre: 2) { unitX, _ in 100 + 50 * unitX }
        #expect(abs(slope.height(x: viewport.width / 2, y: viewport.height / 2)) < 1e-6,
                "the middle's ground is the reference")
        // 600 dots of tile are 50 m of rise, so 60 dots east is 5 m higher: 10 dots.
        #expect(abs(slope.height(x: viewport.width / 2 + 60, y: viewport.height / 2) - 10) < 0.1)
        #expect(ElevationField.flat.height(x: 3, y: 4) == 0)
    }

    @Test func onTheReferenceGroundItIsTheMapsOwnProjection() throws {
        let camera = MapCamera(center: centre, zoom: 16, bearing: 40, pitch: 50)
        let projection = TerrainProjection(camera: camera, viewport: viewport, field: .flat)
        let ground = camera.groundProjection(in: viewport)
        for (x, y) in [(200.0, 60.0), (20, 10), (380, 110)] {
            let flat = try #require(ground.toScreen(x: x, y: y))
            let seen = try #require(projection.toScreen(x: x, y: y, height: 0))
            #expect(abs(seen.x - flat.x) < 1e-6 && abs(seen.y - flat.y) < 1e-6)
        }
    }

    @Test func raisedGroundIsDrawnHigherUpTheScreen() throws {
        let camera = MapCamera(center: centre, zoom: 16, pitch: 50)
        let projection = TerrainProjection(camera: camera, viewport: viewport, field: .flat)
        let low = try #require(projection.toScreen(x: viewport.width / 2, y: 60, height: 0))
        let high = try #require(projection.toScreen(x: viewport.width / 2, y: 60, height: 30))
        #expect(high.y < low.y - 10 && abs(high.x - low.x) < 1e-6)
        #expect(high.depth < low.depth, "nearer the eye, which looks down on it")
    }

    @Test(arguments: [0.0, 35, 60])
    func aPointOfTheScreenIsTheGroundTheViewMeetsFirst(pitch: Double) throws {
        let camera = MapCamera(center: centre, zoom: 16, bearing: 15, pitch: pitch)
        let terrain = field(hill)
        let projection = TerrainProjection(camera: camera, viewport: viewport, field: terrain)
        for (x, y) in [(200.0, 60.0), (40, 100), (360, 20), (200, 5)] {
            let ground = projection.toGround(x: x, y: y)
            let back = try #require(projection.toScreen(x: ground.x, y: ground.y,
                                                        height: terrain.height(x: ground.x, y: ground.y)))
            #expect(abs(back.x - x) < 0.5 && abs(back.y - y) < 0.5,
                    "(\(x), \(y)) is ground at \(ground), drawn back at \(back)")
        }
    }

    @Test func aHillHidesTheGroundBehindIt() throws {
        // Looking north over the hill: the plain behind its top is drawn,
        // on screen, where the hill's face is — so that point of the screen
        // is the face, nearer the eye.
        let camera = MapCamera(center: centre, zoom: 16, pitch: 55)
        let terrain = field(hill)
        let projection = TerrainProjection(camera: camera, viewport: viewport, field: terrain)
        // The top is 90 dots north of the middle; this lies 60 beyond it,
        // down the far slope.
        let behind = (x: viewport.width / 2, y: viewport.height / 2 - 150)
        let drawn = try #require(projection.toScreen(x: behind.x, y: behind.y,
                                                     height: terrain.height(x: behind.x, y: behind.y)))
        let met = projection.toGround(x: drawn.x, y: drawn.y)
        #expect(met.y > behind.y + 5, "the ray meets the hill \(behind.y - met.y) dots short of the point behind it")
    }
}
