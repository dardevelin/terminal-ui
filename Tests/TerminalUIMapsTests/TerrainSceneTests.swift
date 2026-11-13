import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// A realistic map with a terrain layer stands its ground up: the view sees
// the ground the field raises, and what stands behind a ridge — a road, a
// name, a marker — is hidden by it.
@Suite("Terrain scene")
@MainActor
struct TerrainSceneTests {
    private let centre = GeoCoordinate(latitude: 0.02, longitude: 0.02)
    private let size = CanvasSize(width: 100, height: 30)

    /// A ridge running east to west `ridgeNorth` metres north of the
    /// centre, `ridgeHeight` metres tall: a terrain tile for any id.
    private func ridgeTile(_ id: TileID, ridgeNorth: Double = 400, ridgeHeight: Double = 600) -> RenderTile {
        let samples = 64
        var metres = [Float]()
        for row in 0..<samples {
            for column in 0..<samples {
                let extent = 4096
                let point = TilePoint(x: Int32((Double(column) + 0.5) / Double(samples) * Double(extent)),
                                      y: Int32((Double(row) + 0.5) / Double(samples) * Double(extent)))
                let coordinate = id.coordinate(of: point, extent: extent)
                let north = (coordinate.latitude - centre.latitude) * GeoMeasure.meanEarthRadius * .pi / 180
                let across = north - ridgeNorth
                metres.append(Float(ridgeHeight * exp(-(across * across) / (2 * 60 * 60))))
            }
        }
        return RenderTile(id: id, tile: .elevation(ElevationTile(checkedWidth: samples, height: samples, metres: metres)))
    }

    private func frame(terrain: Bool, content: [MapElement] = [], renderer: MapRenderer = MapRenderer()) -> CellBuffer {
        let camera = MapCamera(center: centre, zoom: 15, pitch: 55)
        let layers = MapFrameLayers(
            terrain: terrain ? MapLayerTiles(zoomRange: 0...15) { ridgeTile($0) } : nil,
            elevation: .realistic)
        return drawMap(width: Int(size.width), height: Int(size.height)) { context, size in
            renderer.draw(in: context, camera: camera, size: size, zoomRange: 0...15, content: content,
                          layers: layers) { id in RenderTile(id: id, tile: .vector(VectorTile(layers: []))) }
        }
    }

    private func north(_ metres: Double) -> GeoCoordinate {
        GeoMeasure.destination(from: centre, bearing: 0, distance: metres)
    }

    @Test func theGroundStandsUpAndCoversTheView() {
        let flat = frame(terrain: false), raised = frame(terrain: true)
        #expect(flat.text != raised.text || flat[50, 10] != raised[50, 10], "the ridge changes the view")
        // The ground is a surface drawn into every cell, lit by the scene.
        let painted = (0..<Int(size.height)).allSatisfy { row in
            (0..<Int(size.width)).allSatisfy { column in raised[column, row].style.background != nil }
        }
        #expect(painted, "every cell shows the ground")
    }

    @Test func aMarkerBehindTheRidgeIsHiddenAndOneBeforeItShown() {
        let markers = Marker("Front", coordinate: north(150)).mapElements
            + Marker("Behind", coordinate: north(900)).mapElements
        let flat = frame(terrain: false, content: markers).text
        #expect(flat.contains("Front") && flat.contains("Behind"), "on a plane both are seen")
        let raised = frame(terrain: true, content: markers).text
        #expect(raised.contains("Front"), "before the ridge, the marker shows:\n\(raised)")
        #expect(!raised.contains("Behind"), "behind it, the ridge hides the marker:\n\(raised)")
    }
}
