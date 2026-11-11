import Foundation
import TerminalUI
import TerminalUI3D

/// A realistic map's buildings as a TerminalUI3D scene: each tile's
/// footprints extruded to their heights, seen by a camera that puts the
/// ground exactly where ``GroundProjection`` draws it.
///
/// The scene's units are the map's dots. x runs east from the middle of
/// the north-up map, z south from it, y up; a footprint's height is its
/// metres in dots at its latitude, so a building stands as tall as it is
/// long on the ground at the same scale.
enum BuildingScene {
    /// A point of the north-up map, `height` dots above the ground, in the
    /// scene.
    static func scenePoint(x: Double, y: Double, height: Double, in viewport: DotSize) -> Vector3 {
        Vector3(x - viewport.width / 2, height, y - viewport.height / 2)
    }

    /// How many dots a metre spans at `latitude` through `camera`.
    static func dotsPerMetre(camera: MapCamera, latitude: Double) -> Double {
        camera.dotsPerWorld / WebMercator.metresPerWorldUnit(atLatitude: latitude)
    }

    /// The camera that sees the scene as the map's projection sees the
    /// ground: at the projection's eye distance from the middle, tipped
    /// back by the pitch from straight overhead and turned by the bearing,
    /// with the field of view that makes a dot at the middle a dot.
    static func camera(for camera: MapCamera, viewport: DotSize) -> Camera3D {
        let ground = camera.groundProjection(in: viewport)
        let distance = ground.eyeDistance
        // Up the screen, on the north-up map.
        let ahead = camera.rotation.toMap(x: 0, y: -1)
        let forward = Vector3(ahead.x, 0, ahead.y)
        let eye = forward * (-distance * ground.pitchSine) + Vector3.unitY * (distance * ground.pitchCosine)
        let up = forward * ground.pitchCosine + Vector3.unitY * ground.pitchSine
        let halfHeight = max(viewport.height, 1) / 2
        return Camera3D(position: eye, target: .zero, up: up,
                        projection: .perspective(fieldOfView: 2 * atan(halfHeight / distance)),
                        near: distance * Depth.near, far: distance * Depth.far)
    }

    /// The zoom from which buildings stand up, where the ground under them
    /// is drawn at least this close: further out a house is a dot or two,
    /// and raised it reads as noise. MapKit raises them only close in too.
    static let minimumZoom = 16.0

    /// The near and far planes, in eye distances: nearer than the nearest
    /// ground the map draws, and past the furthest (``GroundProjection``).
    private enum Depth {
        static let near = 0.05
        static let far = 5.0
    }

    /// A feature's rings grouped into polygons, each an outline and the
    /// holes after it, as ranges of the geometry's rings. A tile winds an
    /// outline clockwise on its y-down grid, which the shoelace formula
    /// counts positive, and a hole the other way (Mapbox Vector Tile
    /// specification 2.1, §4.3.4.4).
    static func polygonRings(of feature: RoleGeometry.FeatureSpan, in geometry: RoleGeometry) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        for ring in feature.rings {
            if groups.isEmpty || shoelace(points(of: ring, in: geometry)) > 0 {
                groups.append(ring..<(ring + 1))
            } else {
                groups[groups.count - 1] = groups[groups.count - 1].lowerBound..<(ring + 1)
            }
        }
        return groups
    }

    /// The polygon of a group of rings from ``polygonRings(of:in:)``.
    static func polygon(rings: Range<Int>, in geometry: RoleGeometry) -> Polygon2D {
        Polygon2D(points(of: rings.lowerBound, in: geometry),
                  holes: rings.dropFirst().map { points(of: $0, in: geometry) })
    }

    private static func points(of ring: Int, in geometry: RoleGeometry) -> [Vector2] {
        (geometry.ringStart(ring)..<geometry.ringEnds[ring]).map { index in
            Vector2(geometry.xs[index], geometry.ys[index])
        }
    }

    /// Twice a ring's signed area by the shoelace formula.
    private static func shoelace(_ ring: [Vector2]) -> Double {
        ring.indices.reduce(0) { sum, index in sum + ring[index].cross(ring[(index + 1) % ring.count]) }
    }
}

/// A tile's buildings, sorted into a grid of chunks by where each
/// footprint's middle lies, each chunk's mesh built the first time the view
/// reaches it. A close view shows a corner of a coarse tile — a z14 tile of
/// central Paris holds some 150 000 triangles of buildings — and builds and
/// draws only the chunks there.
final class BuildingTile {
    /// A grid cell's buildings and the box they stand in.
    struct Chunk {
        /// Its polygons: a feature's index, for its extrusion, and the
        /// rings of one outline and its holes.
        var polygons: [(feature: Int, rings: Range<Int>)]
        /// The footprints' box in the tile's unit square, grown by the
        /// tallest of them: a roof can show where its footprint does not.
        var minimumX = Double.infinity, minimumY = Double.infinity
        var maximumX = -Double.infinity, maximumY = -Double.infinity
        /// Built the first time the view reaches the chunk; nil when it
        /// raises nothing.
        var mesh: Mesh??
    }

    /// The grid's cells along each side of a tile.
    static let chunksPerSide = 16

    private let geometry: RoleGeometry
    private let metresPerUnit: Double
    private(set) var chunks: [Chunk]

    /// A tile's buildings, or nil for a tile with none to raise.
    init?(_ tile: RenderTile) {
        guard case .vector(let vector) = tile.content,
              let buildings = vector.layers.first(where: { $0.role == .building }),
              buildings.extrusions.contains(where: { $0 != nil }) else { return nil }
        geometry = buildings
        // A unit of the tile is this many metres at its middle.
        let bounds = tile.id.bounds
        metresPerUnit = WebMercator.metresPerWorldUnit(atLatitude: (bounds.north + bounds.south) / 2)
            / Double(TileID.tilesPerSide(atZoom: tile.id.zoom))
        let side = Self.chunksPerSide
        var grid = Array(repeating: Chunk(polygons: []), count: side * side)
        func cell(_ low: Double, _ high: Double) -> Int { min(max(Int((low + high) / 2 * Double(side)), 0), side - 1) }
        for (index, feature) in buildings.features.enumerated() {
            guard index < buildings.extrusions.count, let extrusion = buildings.extrusions[index] else { continue }
            let reach = extrusion.top / metresPerUnit
            // A tile merges a block's buildings into one feature: each of
            // its polygons goes to the cell its own middle lies in.
            for rings in BuildingScene.polygonRings(of: feature, in: buildings) {
                let outline = buildings.ringBounds[rings.lowerBound]
                let chunk = cell(outline.minimumX, outline.maximumX) + cell(outline.minimumY, outline.maximumY) * side
                grid[chunk].polygons.append((index, rings))
                grid[chunk].minimumX = min(grid[chunk].minimumX, outline.minimumX - reach)
                grid[chunk].minimumY = min(grid[chunk].minimumY, outline.minimumY - reach)
                grid[chunk].maximumX = max(grid[chunk].maximumX, outline.maximumX + reach)
                grid[chunk].maximumY = max(grid[chunk].maximumY, outline.maximumY + reach)
            }
        }
        chunks = grid.filter { !$0.polygons.isEmpty }
    }

    /// Chunk `index`'s buildings in the tile's unit square — x and z across
    /// it, y up in the same unit — walls in material 0 and roofs in
    /// material 1, built now if they were not before.
    func mesh(ofChunk index: Int) -> Mesh? {
        if let built = chunks[index].mesh { return built }
        var positions: [Vector3] = [], normals: [Vector3] = [], triangles: [Mesh.Triangle] = []
        for (feature, rings) in chunks[index].polygons {
            guard let extrusion = geometry.extrusions[feature] else { continue }
            let mesh = Mesh.extrusion(of: BuildingScene.polygon(rings: rings, in: geometry),
                                      height: (extrusion.top - extrusion.base) / metresPerUnit,
                                      base: extrusion.base / metresPerUnit, material: 0, roofMaterial: 1)
            let offset = positions.count
            positions += mesh.positions
            normals += mesh.normals
            triangles += mesh.triangles.map { triangle in
                Mesh.Triangle(triangle.first + offset, triangle.second + offset, triangle.third + offset,
                              material: triangle.material)
            }
        }
        let mesh = triangles.isEmpty ? nil : Mesh(positions: positions, normals: normals, triangles: triangles)
        chunks[index].mesh = .some(mesh)
        return mesh
    }
}

extension MapRenderer {
    /// A realistic map's buildings, over the ground and its lines and
    /// beneath the routes and names: every chunk of every tile the view's
    /// ground reaches, raised through one scene, so a building hides the
    /// ones behind it. A tile standing in for a missing one is left flat,
    /// its buildings waiting for the tile they belong to.
    func drawBuildings(_ items: [Item], camera: MapCamera, projection: Projection, size: CanvasSize,
                       context: GraphicsContext, theme: any Theme) {
        let viewport = projection.viewport
        var scene = Scene3D(camera: BuildingScene.camera(for: camera, viewport: viewport))
        let materials = [Material(theme.foregroundMuted), Material(theme.foregroundSubtle)]
        var used: Set<TileID> = []
        for item in items where item.standsIn == nil {
            // Judged where the view shows the tile nearest: a tile's
            // buildings stand or lie together, and a coarse tile's middle
            // can lie far up the view while its near edge is at the
            // camera's feet.
            guard projection.nearestZoom(of: item) >= BuildingScene.minimumZoom else { continue }
            let id = item.tile.id
            used.insert(id)
            let buildings: BuildingTile
            if let cached = buildingTiles[id] {
                guard let cached else { continue }
                buildings = cached
            } else {
                let made = BuildingTile(item.tile)
                buildingTiles[id] = .some(made)
                guard let made else { continue }
                buildings = made
            }
            let corner = BuildingScene.scenePoint(x: item.originX, y: item.originY, height: 0, in: viewport)
            let transform = Matrix4.translation(corner) * .scale(item.side)
            for index in buildings.chunks.indices {
                let chunk = buildings.chunks[index]
                let box = CanvasRect(x: item.originX + chunk.minimumX * item.side,
                                     y: item.originY + chunk.minimumY * item.side,
                                     width: (chunk.maximumX - chunk.minimumX) * item.side,
                                     height: (chunk.maximumY - chunk.minimumY) * item.side)
                // Raised only where the ground is drawn close enough: the
                // far part of a pitched view lies flat, as MapKit's does.
                guard projection.nearestZoom(of: box) >= BuildingScene.minimumZoom,
                      let mesh = buildings.mesh(ofChunk: index) else { continue }
                scene.add(mesh, transform: transform, materials: materials)
            }
        }
        if buildingTiles.count > Self.buildingTileLimit {
            buildingTiles = buildingTiles.filter { used.contains($0.key) }
        }
        guard !scene.models.isEmpty else { return }
        buildingRenderer.draw(scene, in: context, size: size, shading: .image(), framing: .camera)
    }

    /// How many tiles' buildings are kept between frames: a view's worth
    /// and more, so a pan back finds them built.
    static let buildingTileLimit = 64
}
