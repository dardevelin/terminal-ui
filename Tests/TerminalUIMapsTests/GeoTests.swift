import Testing
@testable import TerminalUIMaps

private func isClose(_ first: Double, _ second: Double, within tolerance: Double = 1e-9) -> Bool {
    abs(first - second) <= tolerance
}

@Suite struct WebMercatorTests {
    @Test func nullIslandIsTheMiddleOfTheWorld() {
        let point = WebMercator.project(GeoCoordinate(latitude: 0, longitude: 0))
        #expect(isClose(point.x, 0.5))
        #expect(isClose(point.y, 0.5))
    }

    @Test func theLatitudeLimitIsTheWorldsTopEdge() {
        let top = WebMercator.project(GeoCoordinate(latitude: WebMercator.maximumLatitude, longitude: -180))
        #expect(isClose(top.x, 0))
        #expect(isClose(top.y, 0, within: 1e-12))
        let bottom = WebMercator.project(GeoCoordinate(latitude: -WebMercator.maximumLatitude, longitude: 180))
        #expect(isClose(bottom.y, 1, within: 1e-12))
    }

    @Test func latitudesBeyondTheLimitClamp() {
        let pole = WebMercator.project(GeoCoordinate(latitude: 90, longitude: 0))
        #expect(pole.y.isFinite)
        #expect(isClose(pole.y, 0, within: 1e-12))
    }

    @Test(arguments: [(39.4758, -8.3357), (51.5007, -0.1246), (-33.8568, 151.2153), (64.1466, -21.9426)])
    func unprojectInvertsProject(latitude: Double, longitude: Double) {
        let back = WebMercator.unproject(WebMercator.project(GeoCoordinate(latitude: latitude, longitude: longitude)))
        #expect(isClose(back.latitude, latitude))
        #expect(isClose(back.longitude, longitude))
    }

    @Test func aMidpointIsHalfwayAlong() throws {
        let line = [GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0, longitude: 2),
                    GeoCoordinate(latitude: 0, longitude: 4)]
        let middle = try #require(WebMercator.midpoint(of: line))
        #expect(isClose(middle.longitude, 2))
        #expect(WebMercator.midpoint(of: []) == nil)
    }
}

@Suite struct TileIDTests {
    @Test func theTileOfConstancia() {
        let tile = TileID(containing: GeoCoordinate(latitude: 39.4758, longitude: -8.3357), zoom: 14)
        #expect(tile == TileID(zoom: 14, x: 7812, y: 6233))
    }

    @Test func parentsAndChildrenAreInverse() throws {
        let tile = TileID(zoom: 14, x: 7812, y: 6233)
        let parent = try #require(tile.parent)
        #expect(parent == TileID(zoom: 13, x: 3906, y: 3116))
        #expect(parent.children.contains(tile))
        #expect(Set(parent.children.compactMap(\.parent)) == [parent])
        #expect(TileID(zoom: 0, x: 0, y: 0).parent == nil)
        #expect(tile.ancestor(atZoom: 10) == TileID(zoom: 10, x: 488, y: 389))
    }

    @Test func aChildsBoundsLieInItsParents() throws {
        let tile = TileID(zoom: 5, x: 15, y: 12)
        for child in tile.children {
            #expect(tile.bounds.contains(child.bounds.center))
        }
    }

    @Test func validityChecksTheGrid() {
        #expect(TileID(zoom: 2, x: 3, y: 3).isValid)
        #expect(!TileID(zoom: 2, x: 4, y: 0).isValid)
        #expect(!TileID(zoom: -1, x: 0, y: 0).isValid)
    }

    @Test func coveringATileBoxGivesThatTile() {
        let tile = TileID(zoom: 9, x: 200, y: 180)
        let inset = tile.bounds
        let small = GeoRect(south: inset.south + 0.01, west: inset.west + 0.01,
                            north: inset.north - 0.01, east: inset.east - 0.01)
        #expect(TileID.covering(small, zoom: 9) == [tile])
        #expect(TileID.covering(small, zoom: 10).count == 4)
        #expect(TileID.count(covering: small, zoom: 10) == 4)
    }

    @Test func coveringTheWorld() {
        #expect(TileID.covering(TileSourceInfo.world, zoom: 0) == [TileID(zoom: 0, x: 0, y: 0)])
        #expect(TileID.count(covering: TileSourceInfo.world, zoom: 3) == 64)
    }

    @Test func tilePointsRoundTrip() {
        let tile = TileID(zoom: 14, x: 7812, y: 6233)
        let middle = tile.coordinate(of: TilePoint(x: 2048, y: 2048), extent: 4096)
        #expect(tile.bounds.contains(middle))
        #expect(tile.tilePoint(for: middle, extent: 4096) == TilePoint(x: 2048, y: 2048))
    }
}

@Suite struct MapCameraTests {
    let viewport = DotSize(columns: 80, rows: 24)

    @Test func aViewportIsMeasuredInBrailleDots() {
        #expect(viewport == DotSize(width: 160, height: 96))
    }

    @Test func theCentreIsTheMiddleOfTheViewport() throws {
        let camera = MapCamera(center: GeoCoordinate(latitude: 39.47, longitude: -8.33), zoom: 13.5)
        let point = try #require(camera.screenPoint(for: camera.center, in: viewport))
        #expect(isClose(point.x, 80))
        #expect(isClose(point.y, 48))
    }

    @Test func screenAndGeoRoundTrip() throws {
        let camera = MapCamera(center: GeoCoordinate(latitude: 51.5, longitude: -0.12), zoom: 12.25)
        let point = DotPoint(x: 13, y: 71)
        let coordinate = camera.coordinate(at: point, in: viewport)
        let back = try #require(camera.screenPoint(for: coordinate, in: viewport))
        #expect(isClose(back.x, point.x, within: 1e-6))
        #expect(isClose(back.y, point.y, within: 1e-6))
    }

    @Test func oneZoomLevelDoublesTheScale() {
        let camera = MapCamera(center: GeoCoordinate(latitude: 0, longitude: 0), zoom: 3)
        #expect(camera.dotsPerWorld == 256 * 8)
        #expect(camera.zoomed(by: 1).dotsPerWorld == 256 * 16)
    }

    @Test func zoomIsClampedToItsRange() {
        var camera = MapCamera(center: GeoCoordinate(latitude: 0, longitude: 0), zoom: 40, zoomRange: 0...18)
        #expect(camera.zoom == 18)
        camera.zoom = -3
        #expect(camera.zoom == 0)
    }

    @Test func panningFollowsTheDrag() {
        let camera = MapCamera(center: GeoCoordinate(latitude: 10, longitude: 10), zoom: 8)
        let east = camera.coordinate(at: DotPoint(x: 100, y: 48), in: viewport)
        let panned = camera.panned(byDotsX: -20, y: 0)
        #expect(isClose(panned.center.longitude, east.longitude, within: 1e-9))
        #expect(isClose(panned.center.latitude, 10, within: 1e-9))
    }

    @Test func panningAcrossTheAntimeridianWraps() {
        let camera = MapCamera(center: GeoCoordinate(latitude: 0, longitude: 179.9), zoom: 6)
        let panned = camera.panned(byDotsX: -1_000, y: 0)
        #expect(isClose(panned.center.longitude, 179.9 + 1_000.0 / 16_384 * 360 - 360, within: 1e-9))
    }

    @Test func zoomingAboutAPointKeepsItStill() throws {
        let camera = MapCamera(center: GeoCoordinate(latitude: 39.47, longitude: -8.33), zoom: 12)
        let anchor = DotPoint(x: 30, y: 20)
        let under = camera.coordinate(at: anchor, in: viewport)
        let zoomed = camera.zoomed(by: 1.5, about: anchor, in: viewport)
        #expect(zoomed.zoom == 13.5)
        let after = try #require(zoomed.screenPoint(for: under, in: viewport))
        #expect(isClose(after.x, anchor.x, within: 1e-6))
        #expect(isClose(after.y, anchor.y, within: 1e-6))
    }

    @Test func coveringTilesStartAtTheCentre() {
        let camera = MapCamera(center: TileID(zoom: 14, x: 7812, y: 6233).bounds.center, zoom: 14.7)
        let tiles = camera.coveringTiles(in: DotSize(width: 600, height: 600), sourceZoomRange: 0...14)
        #expect(tiles.first == TileID(zoom: 14, x: 7812, y: 6233))
        #expect(tiles.allSatisfy { $0.zoom == 14 })
        #expect(Set(tiles).count == tiles.count)
        #expect(tiles.count == 9)
    }

    @Test func aWorldWideViewHasEveryTileOnce() {
        let camera = MapCamera(center: GeoCoordinate(latitude: 0, longitude: 0), zoom: 0)
        let tiles = camera.coveringTiles(in: DotSize(width: 2_000, height: 2_000))
        #expect(tiles == [TileID(zoom: 0, x: 0, y: 0)])
    }

    @Test func fittingARectShowsAllOfIt() {
        let rect = GeoRect(south: 39.4, west: -8.4, north: 39.5, east: -8.2)
        let camera = MapCamera.fitting(rect, in: viewport)
        let visible = camera.visibleRect(in: viewport)
        #expect(visible.south <= rect.south + 1e-9 && visible.north >= rect.north - 1e-9)
        #expect(visible.west <= rect.west + 1e-9 && visible.east >= rect.east - 1e-9)
    }
}
