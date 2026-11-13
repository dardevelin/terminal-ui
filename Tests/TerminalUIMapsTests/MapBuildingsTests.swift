import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUI3D
@testable import TerminalUIMaps

// Buildings stand up from their footprints on a realistic map, as SwiftUI
// MapKit's `.mapStyle(.standard(elevation: .realistic))` raises them: each
// tile's footprints extruded to the heights OpenMapTiles gives, and drawn
// by TerminalUI3D's renderer through a camera that sees the ground exactly
// where the map draws it.
@Suite("Buildings")
@MainActor
struct MapBuildingsTests {
    private let centre = GeoCoordinate(latitude: 38.5, longitude: -8.2)
    private let viewport = DotSize(columns: 100, rows: 30)

    /// Where a point of the scene lands through `camera`, in dots: what the
    /// renderer's rasterizer does with it.
    private func screen(_ point: Vector3, through camera: Camera3D, in viewport: DotSize) -> DotPoint? {
        let projection = camera.projection.matrix(aspect: viewport.width / viewport.height, near: camera.near,
                                                  far: camera.far)
        // One product at a time: Linux's type checker read the chain as a
        // matrix times a matrix times a vector, and could not.
        let seen: Vector4 = camera.viewMatrix * Vector4(point, 1)
        let clip: Vector4 = projection * seen
        guard clip.w > 0 else { return nil }
        return DotPoint(x: (clip.x / clip.w + 1) / 2 * viewport.width,
                        y: (1 - clip.y / clip.w) / 2 * viewport.height)
    }

    @Test(arguments: [(0.0, 0.0), (37.0, 50.0), (200.0, 60.0)])
    func theSceneSeesTheGroundWhereTheMapDrawsIt(bearing: Double, pitch: Double) throws {
        let camera = MapCamera(center: centre, zoom: 16, bearing: bearing, pitch: pitch)
        let ground = camera.groundProjection(in: viewport)
        let scene = BuildingScene.camera(for: camera, viewport: viewport)
        for (x, y) in [(200.0, 60.0), (10, 5), (390, 110), (150, 20)] {
            let drawn = try #require(ground.toScreen(x: x, y: y))
            let seen = try #require(screen(BuildingScene.scenePoint(x: x, y: y, height: 0, in: viewport),
                                           through: scene, in: viewport))
            #expect(abs(seen.x - drawn.x) < 1e-6 && abs(seen.y - drawn.y) < 1e-6,
                    "(\(x), \(y)): the map draws it at \(drawn), the scene at \(seen)")
        }
    }

    @Test func aTileKeepsItsBuildingsHeights() throws {
        func building(_ properties: [String: VectorValue], at offset: Int32) -> VectorFeature {
            let ring = [TilePoint(x: offset, y: offset), TilePoint(x: offset + 100, y: offset),
                        TilePoint(x: offset + 100, y: offset + 100), TilePoint(x: offset, y: offset + 100)]
            return VectorFeature(polygons: [VectorPolygon(exterior: ring)], properties: properties)
        }
        let layer = VectorLayer(name: "building", features: [
            building(["render_height": .double(20), "render_min_height": .double(5)], at: 0),
            building(["render_height": .int(30), "hide_3d": .bool(true)], at: 1000),
            building([:], at: 2000),
        ])
        let content = VectorContent(VectorTile(layers: [layer]))
        let buildings = try #require(content.layers.first { $0.role == .building })
        #expect(buildings.features.count == 3, "every footprint is still drawn flat")
        #expect(buildings.extrusions == [BuildingExtrusion(base: 5, top: 20),
                                         nil,  // a building:part stands for the outline that says hide_3d
                                         BuildingExtrusion(base: 0, top: BuildingExtrusion.defaultHeight)])
    }

    @Test func aTallBuildingStandsAboveItsFootprint() throws {
        // One 40-metre block a little ahead of the middle, seen pitched: its
        // roof is drawn where its footprint, raised forty metres, lands —
        // above the footprint on screen — and only on a realistic map.
        let tileZoom = 16
        let camera = MapCamera(center: centre, zoom: 16, pitch: 50)
        let tile = TileID(containing: centre, zoom: tileZoom)
        let corner = tile.tilePoint(for: GeoMeasure.destination(from: centre, bearing: 0, distance: 30),
                                    extent: VectorLayer.defaultExtent)
        let side: Int32 = 60
        let ring = [corner, TilePoint(x: corner.x + side, y: corner.y), TilePoint(x: corner.x + side, y: corner.y + side),
                    TilePoint(x: corner.x, y: corner.y + side)]
        let layer = VectorLayer(name: "building", features: [
            VectorFeature(polygons: [VectorPolygon(exterior: ring)], properties: ["render_height": .double(40)]),
        ])
        let render = RenderTile(id: tile, tile: .vector(VectorTile(layers: [layer])))
        func frame(_ elevation: MapElevation) -> CellBuffer {
            drawMap(width: 100, height: 30) { context, size in
                MapRenderer().draw(in: context, camera: camera, size: size, zoomRange: 0...tileZoom,
                                   layers: MapFrameLayers(elevation: elevation)) { $0 == tile ? render : nil }
            }
        }
        let flat = frame(.flat), realistic = frame(.realistic)
        #expect(flat.text != realistic.text, "the building stands up")
        // The roof's middle: the footprint's middle raised forty metres.
        let middle = tile.coordinate(of: TilePoint(x: corner.x + side / 2, y: corner.y + side / 2),
                                     extent: VectorLayer.defaultExtent)
        let northUp = camera.northUpPoint(for: middle, in: viewport)
        let metres = BuildingScene.dotsPerMetre(camera: camera, latitude: middle.latitude)
        let roof = try #require(screen(BuildingScene.scenePoint(x: northUp.x, y: northUp.y, height: 40 * metres,
                                                                in: viewport),
                                       through: BuildingScene.camera(for: camera, viewport: viewport), in: viewport))
        let footprint = try #require(camera.screenPoint(for: middle, in: viewport))
        #expect(roof.y < footprint.y - Double(BrailleCell.dotRows), "the roof is drawn above the footprint")
        let column = Int(roof.x) / BrailleCell.dotColumns, row = Int(roof.y) / BrailleCell.dotRows
        #expect(realistic[column, row] != flat[column, row], "the roof covers the cell it lands in")
    }

    @Test func aCloseViewOfACityBuildsOnlyWhatItShows() throws {
        // A z14 tile of central Paris holds some 150 000 triangles of
        // buildings, merged into a few features per block. A close, pitched
        // view shows a corner of it: only the chunks there are built, and
        // the far ground lies flat. Counts, not time, so the budget holds on
        // any machine; measured at 11 698 (design/maps.md, §E).
        let tile = try ParisFixture.tile()
        let renderer = MapRenderer()
        let camera = MapCamera(center: ParisFixture.centre, zoom: 16.5, bearing: 30, pitch: 55)
        _ = drawMap(width: 200, height: 60) { context, size in
            renderer.draw(in: context, camera: camera, size: size, zoomRange: 0...14,
                          layers: MapFrameLayers(elevation: .realistic)) { $0 == tile.id ? tile : nil }
        }
        let buildings = try #require(renderer.buildingTiles[tile.id] ?? nil)
        let built = buildings.chunks.compactMap { $0.mesh ?? nil }
        let triangles = built.reduce(0) { $0 + $1.triangles.count }
        #expect(triangles > 0, "the buildings in view stand up")
        #expect(triangles < 20_000, "\(triangles) triangles built for one close view")
        #expect(built.count < buildings.chunks.count / 4,
                "\(built.count) of \(buildings.chunks.count) chunks built")
    }
}
