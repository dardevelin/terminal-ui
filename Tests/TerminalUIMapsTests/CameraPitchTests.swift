import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// A pitched camera looks at the ground at an angle, as SwiftUI MapKit's
// `MapCamera(…, pitch:)` does: the middle stays where it was, the ground
// ahead recedes, and the pointer, the drawing and the tiles all agree on
// where a coordinate lies.
@Suite("A pitched camera")
struct CameraPitchTests {
    private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
    private let viewport = DotSize(width: 160, height: 96)

    private func near(_ point: DotPoint?, _ expected: DotPoint, within tolerance: Double = 1e-6) -> Bool {
        guard let point else { return false }
        return abs(point.x - expected.x) < tolerance && abs(point.y - expected.y) < tolerance
    }

    @Test func aPitchIsKeptBetweenStraightDownAndTheMost() {
        var camera = MapCamera(center: centre, zoom: 16, pitch: 75)
        #expect(camera.pitch == MapCamera.maximumPitch)
        camera.pitch = -10
        #expect(camera.pitch == 0)
        #expect(MapCamera(center: centre, zoom: 16).pitch == 0, "a camera made without one looks straight down")
    }

    @Test func theMiddleStaysAndTheGroundAheadRecedes() throws {
        let camera = MapCamera(center: centre, zoom: 16, pitch: 45)
        #expect(near(camera.screenPoint(for: centre, in: viewport), DotPoint(x: 80, y: 48)))
        let ahead = try #require(camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 0, distance: 30),
                                                    in: viewport))
        let behind = try #require(camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 180,
                                                                                distance: 30), in: viewport))
        #expect(ahead.y < 48 && behind.y > 48)
        #expect(48 - ahead.y < behind.y - 48, "the same distance draws shorter further away")
        // Across the middle, the scale is the flat camera's: zoom keeps
        // meaning what it meant. (Along the parallel: a great circle east
        // drifts south of the middle row.)
        let east = GeoCoordinate(latitude: centre.latitude, longitude: centre.longitude + 0.0004)
        let flat = try #require(MapCamera(center: centre, zoom: 16).screenPoint(for: east, in: viewport))
        #expect(near(camera.screenPoint(for: east, in: viewport), flat))
    }

    @Test(arguments: [(0.0, 30.0), (37, 45), (211.5, 60)])
    func screenAndGroundAgree(bearing: Double, pitch: Double) {
        let camera = MapCamera(center: centre, zoom: 15.3, bearing: bearing, pitch: pitch)
        for point in [DotPoint(x: 0, y: 0), DotPoint(x: 160, y: 0), DotPoint(x: 3, y: 90), DotPoint(x: 120, y: 30),
                      DotPoint(x: 80, y: 96)] {
            let back = camera.screenPoint(for: camera.coordinate(at: point, in: viewport), in: viewport)
            #expect(near(back, point, within: 1e-5), "\(point) came back as \(String(describing: back))")
        }
    }

    @Test func aStraightRoadStaysStraight() throws {
        // A flat ground seen in perspective is a homography of the plane:
        // what is straight on the ground is straight on screen.
        let camera = MapCamera(center: centre, zoom: 16, bearing: 20, pitch: 50)
        let start = WebMercator.project(GeoMeasure.destination(from: centre, bearing: 300, distance: 80))
        let end = WebMercator.project(GeoMeasure.destination(from: centre, bearing: 60, distance: 120))
        let middle = WorldPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let points = try [start, middle, end].map { world in
            try #require(camera.screenPoint(for: WebMercator.unproject(world), in: viewport))
        }
        let first = (x: points[1].x - points[0].x, y: points[1].y - points[0].y)
        let second = (x: points[2].x - points[0].x, y: points[2].y - points[0].y)
        let cross: Double = first.x * second.y - first.y * second.x
        #expect(abs(cross) < 1e-6)
    }

    @Test(arguments: [DotSize(width: 160, height: 96), DotSize(width: 400, height: 16), DotSize(width: 8, height: 8)])
    func everyPointOfTheViewIsGroundAtTheMostPitch(view: DotSize) {
        let camera = MapCamera(center: centre, zoom: 17, pitch: MapCamera.maximumPitch)
        for point in [DotPoint(x: 0, y: 0), DotPoint(x: view.width / 2, y: 0), DotPoint(x: view.width, y: 0)] {
            #expect(near(camera.screenPoint(for: camera.coordinate(at: point, in: view), in: view), point,
                         within: 1e-5), "the top edge, \(point), lies below the horizon")
        }
    }

    @Test func groundBehindTheEyeIsNotDrawn() {
        let camera = MapCamera(center: centre, zoom: 16, pitch: 60)
        #expect(camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 180, distance: 2_000),
                                   in: viewport) == nil)
        #expect(camera.screenPoint(for: GeoMeasure.destination(from: centre, bearing: 0, distance: 2_000),
                                   in: viewport) != nil, "far ahead is still ground, however small")
    }

    @Test func aDragKeepsTheGroundUnderThePointer() {
        let camera = MapCamera(center: centre, zoom: 15, bearing: 120, pitch: 50)
        let from = DotPoint(x: 30, y: 20), to = DotPoint(x: 50, y: 70)
        let grabbed = camera.coordinate(at: from, in: viewport)
        let moved = camera.panned(dragging: from, to: to, in: viewport)
        #expect(near(moved.screenPoint(for: grabbed, in: viewport), to, within: 1e-5))
    }

    @Test func aDragOnAFlatCameraIsThePanItWas() {
        let camera = MapCamera(center: centre, zoom: 15, bearing: 120)
        let dragged = camera.panned(dragging: DotPoint(x: 20, y: 10), to: DotPoint(x: 26, y: 6), in: viewport)
        let panned = camera.panned(byDotsX: 6, y: -4)
        #expect(abs(dragged.center.latitude - panned.center.latitude) < 1e-9)
        #expect(abs(dragged.center.longitude - panned.center.longitude) < 1e-9)
    }

    @Test func zoomingAboutThePointerKeepsItsGroundPitched() {
        let camera = MapCamera(center: centre, zoom: 15, bearing: 300, pitch: 55)
        let anchor = DotPoint(x: 140, y: 12)
        let ground = camera.coordinate(at: anchor, in: viewport)
        let zoomed = camera.zoomed(by: 1, about: anchor, in: viewport)
        #expect(near(zoomed.screenPoint(for: ground, in: viewport), anchor, within: 1e-5))
        #expect(zoomed.pitch == 55)
    }

    @Test func farTilesAreCoarserAndEveryPointHasOne() {
        // A 200 × 60 terminal: the ground it shows pitched runs several
        // tiles deep.
        let viewport = DotSize(columns: 200, rows: 60)
        let camera = MapCamera(center: centre, zoom: 16, bearing: 25, pitch: 60)
        let tiles = camera.coveringTiles(in: viewport)
        let zooms = Set(tiles.map(\.zoom))
        #expect(zooms.max() == 16, "the nearest ground is drawn at the camera's own tile zoom")
        #expect(zooms.count > 1, "the far ground is drawn from coarser tiles")
        #expect(Set(tiles).count == tiles.count)
        // Every point of the view lies in exactly one tile: nothing is
        // drawn twice, and nothing is left out.
        for column in stride(from: 0.0, through: viewport.width, by: 20) {
            for row in stride(from: 0.0, through: viewport.height, by: 16) {
                let world = camera.worldPoint(at: DotPoint(x: column, y: row), in: viewport)
                let holding = tiles.filter { tile in
                    let (minimum, maximum) = tile.worldBounds
                    return world.x >= minimum.x && world.x < maximum.x && world.y >= minimum.y && world.y < maximum.y
                }
                #expect(holding.count == 1, "(\(column), \(row)) lies in \(holding.count) tiles")
            }
        }
        let flatCount = MapCamera(center: centre, zoom: 16, bearing: 25).coveringTiles(in: viewport).count
        #expect(tiles.count < flatCount * 4, "the far ground does not cost a near tile's worth each")
    }

    @Test func theNearestTilesComeFirst() throws {
        let camera = MapCamera(center: centre, zoom: 16, pitch: 60)
        let tiles = camera.coveringTiles(in: viewport)
        let first = try #require(tiles.first)
        #expect(first.zoom == 16 && first == TileID(containing: centre, zoom: 16))
    }
}
