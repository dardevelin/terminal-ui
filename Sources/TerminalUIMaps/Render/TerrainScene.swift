import TerminalUI
import TerminalUI3D

/// What a frame drawn over terrain projects its points through: the ground's
/// heights, and the scene of the ground and the buildings drawn of them, so
/// a point a hill or a building hides is not drawn.
struct TerrainDrape {
    let projection: TerrainProjection
    /// The renderer that drew the frame's scene, holding its depths.
    let scene: SceneRenderer

    /// How far apart, in north-up dots, a line is stepped along to follow
    /// the ground between its points: a half cell's two dots across and a
    /// little more, finer than a hill's shape at a terminal's resolution.
    static let step = 3.0

    /// How much nearer than its point a surface must be to hide it: a few
    /// dots, and a share of the distance, since a line follows the field's
    /// interpolated heights and the ground mesh is flat between its grid's
    /// points — the two can part by a little.
    private enum Occlusion {
        static let slackDots = 3.0
        static let slackShare = 0.02
    }

    /// Where a north-up point is drawn, lifted to the ground, or nil when
    /// it is behind the eye or a surface of the scene stands in front of it.
    func visiblePoint(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard let point = projection.toScreen(x: x, y: y, height: projection.field.height(x: x, y: y)) else {
            return nil
        }
        if let surface = scene.depth(atSampleX: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down))),
           surface < point.depth - max(Occlusion.slackDots, point.depth * Occlusion.slackShare) {
            return nil
        }
        return (point.x, point.y)
    }
}

/// The ground of a basemap tile over terrain: a grid of points raised to the
/// field's heights, each triangle coloured by the area under its middle —
/// water, a park, landuse, or the plain ground — as the flat map fills them.
enum TerrainGround {
    /// The grid's points along a tile's side at its own zoom: 32 cells of
    /// eight dots, a hill's shape in steps finer than a cell.
    static let pointsPerSide = 33

    /// The areas a triangle can take, topmost first, and their materials
    /// after the plain ground's 0: water lies over a park over landuse.
    static let coverRoles: [MapRole] = [.water, .park, .landcover, .landuse]

    /// The materials of the ground, in the theme: the plain ground first,
    /// then ``coverRoles``' fills.
    static func materials(in theme: any Theme) -> [Material] {
        [Material(theme.backgroundOverlay, specular: 0)]
            + coverRoles.map { Material($0.colour(in: theme), specular: 0) }
    }

    /// The light the ground is shaded by: hillshade's sun, from the
    /// north-west 45° up (``Hillshade/standard``), with enough of the sky
    /// that a slope turned from it keeps its colour. A key light from high
    /// in front, as an object's scene has, leaves a gentle hill almost
    /// unshaded.
    static let lights: [Light3D] = [
        .ambient(Sun.sky),
        // North-west is −x and −z here, x running east and z south.
        .directional(toward: Vector3(-Sun.across, Sun.up, -Sun.across), intensity: Sun.intensity),
    ]

    private enum Sun {
        /// sin 45°: the sun's height, and its reach along each of west and
        /// north, cos 45° × cos 45°.
        static let up = 0.7071
        static let across = 0.5
        static let intensity = 0.8
        static let sky = 0.35
    }

    /// The ground over the part of `tile` from `unitRect` of its unit
    /// square, in that square's units — x and z across, y up — its heights
    /// above sea level by `metres` at a point of the unit square.
    static func mesh(for tile: RenderTile, unitRect: CanvasRect,
                     metresPerUnit: Double, metres: (Double, Double) -> Double) -> Mesh {
        let across = max(2, Int((unitRect.width * Double(pointsPerSide - 1)).rounded(.up)) + 1)
        let down = max(2, Int((unitRect.height * Double(pointsPerSide - 1)).rounded(.up)) + 1)
        var positions: [Vector3] = []
        positions.reserveCapacity(across * down)
        for row in 0..<down {
            for column in 0..<across {
                let unitX = unitRect.x + unitRect.width * Double(column) / Double(across - 1)
                let unitY = unitRect.y + unitRect.height * Double(row) / Double(down - 1)
                positions.append(Vector3(unitX, metres(unitX, unitY) / metresPerUnit, unitY))
            }
        }
        let areas: [RoleGeometry]
        if case .vector(let vector) = tile.content {
            areas = coverRoles.compactMap { role in vector.layers.first { $0.role == role } }
        } else {
            areas = []
        }
        var triangles: [Mesh.Triangle] = []
        triangles.reserveCapacity((across - 1) * (down - 1) * 2)
        for row in 0..<(down - 1) {
            for column in 0..<(across - 1) {
                let corner = row * across + column
                let first = positions[corner], last = positions[corner + across + 1]
                let material = cover(atUnitX: (first.x + last.x) / 2, y: (first.z + last.z) / 2, in: areas)
                // Wound so the face looks up, toward a camera above it.
                triangles.append(Mesh.Triangle(corner, corner + across, corner + across + 1, material: material))
                triangles.append(Mesh.Triangle(corner, corner + across + 1, corner + 1, material: material))
            }
        }
        return Mesh(positions: positions, triangles: triangles)
    }

    /// The material of the area at a point of the unit square: the topmost
    /// of ``coverRoles`` whose rings hold it, by the even-odd rule, or the
    /// plain ground's 0.
    private static func cover(atUnitX x: Double, y: Double, in areas: [RoleGeometry]) -> Int {
        for geometry in areas {
            var inside = false
            for ring in geometry.ringEnds.indices {
                let bounds = geometry.ringBounds[ring]
                guard x >= bounds.minimumX, x <= bounds.maximumX, y >= bounds.minimumY, y <= bounds.maximumY else {
                    continue
                }
                let start = geometry.ringStart(ring), end = geometry.ringEnds[ring]
                var previous = end - 1
                for index in start..<end {
                    let yi = geometry.ys[index], yj = geometry.ys[previous]
                    if (yi > y) != (yj > y) {
                        let crossing = geometry.xs[index]
                            + (y - yi) * (geometry.xs[previous] - geometry.xs[index]) / (yj - yi)
                        if x < crossing { inside.toggle() }
                    }
                    previous = index
                }
            }
            if inside, let index = coverRoles.firstIndex(of: geometry.role) { return index + 1 }
        }
        return 0
    }
}

extension MapRenderer {
    /// The terrain under a frame: the terrain layer's tiles at hand as a
    /// field over the north-up map, measured from the ground under the
    /// camera's centre. Flat with no terrain layer, or none of its tiles.
    func elevationField(_ layers: MapFrameLayers, camera: MapCamera, viewport: DotSize,
                        dots: GraphicsContext) -> ElevationField {
        guard layers.elevation == .realistic, let terrain = layers.terrain else { return .flat }
        let planning = Projection(camera: camera, viewport: viewport)
        let items = plan(camera: camera, viewport: viewport, zoomRange: terrain.zoomRange, projection: planning,
                         dots: dots, countsTiles: false, lookup: terrain.lookup)
        let patches = items.compactMap { item -> ElevationField.Patch? in
            guard case .elevation(let elevation) = item.tile.content else { return nil }
            return ElevationField.Patch(originX: item.originX, originY: item.originY, side: item.side,
                                        tile: elevation.elevation, id: item.tile.id)
        }
        guard !patches.isEmpty else { return .flat }
        return ElevationField(patches: patches,
                              dotsPerMetre: BuildingScene.dotsPerMetre(camera: camera, latitude: camera.center.latitude),
                              referenceX: viewport.width / 2, referenceY: viewport.height / 2)
    }

    /// The ground and the buildings of a frame over terrain, as one scene
    /// drawn into the canvas's fill plane, beneath the lines and names:
    /// those are drawn after, each point tested against its depths.
    func drawTerrainScene(_ items: [Item], camera: MapCamera, projection: Projection, size: CanvasSize,
                          context: GraphicsContext, theme: any Theme) {
        guard let drape = projection.drape else { return }
        let field = drape.projection.field
        let viewport = projection.viewport
        var scene = Scene3D(camera: BuildingScene.camera(for: camera, viewport: viewport),
                            lights: TerrainGround.lights)
        let materials = TerrainGround.materials(in: theme)
        let lift = -field.reference * field.dotsPerMetre
        for item in items {
            let bounds = item.tile.id.bounds
            let metresPerUnit = WebMercator.metresPerWorldUnit(atLatitude: (bounds.north + bounds.south) / 2)
                / Double(TileID.tilesPerSide(atZoom: item.tile.id.zoom))
            let originX = item.originX, originY = item.originY, side = item.side
            // A tile standing in for missing ones lays its ground over
            // theirs alone: over the rest, the tiles there have their own.
            let rects = item.standsIn.map { squares in
                squares.map { CanvasRect(x: ($0.x - originX) / side, y: ($0.y - originY) / side,
                                         width: $0.width / side, height: $0.height / side) }
            } ?? [CanvasRect(x: 0, y: 0, width: 1, height: 1)]
            let corner = BuildingScene.scenePoint(x: originX, y: originY, height: lift, in: viewport)
            for rect in rects {
                let mesh = TerrainGround.mesh(for: item.tile, unitRect: rect, metresPerUnit: metresPerUnit) {
                    unitX, unitY in field.metres(x: originX + unitX * side, y: originY + unitY * side) ?? field.reference
                }
                scene.add(mesh, transform: .translation(corner) * .scale(side), materials: materials)
            }
        }
        addBuildings(items, to: &scene, projection: projection, theme: theme)
        buildingRenderer.draw(scene, in: context, size: size, shading: .halfBlock, framing: .camera)
    }
}
