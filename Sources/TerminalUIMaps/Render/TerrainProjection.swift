import TerminalUI
import TerminalUI3D

/// Where the ground of a realistic map with terrain lands on screen, and
/// what ground a point of the screen shows.
///
/// Raised ground is no longer a plane, so ``GroundProjection``'s homography
/// does not hold for it; this projects through the map's one 3D camera
/// (``BuildingScene/camera(for:viewport:)``), which on the reference ground
/// draws every point where the homography does. Back from the screen, the
/// view ray is marched over the field and its crossing bisected: the first
/// ground it meets is what the point shows — a hill's face before what
/// stands behind it.
struct TerrainProjection {
    let viewport: DotSize
    let field: ElevationField
    private let flatGround: GroundProjection
    private let viewProjection: Matrix4
    private let eye: Vector3

    init(camera: MapCamera, viewport: DotSize, field: ElevationField) {
        self.viewport = viewport
        self.field = field
        flatGround = camera.groundProjection(in: viewport)
        let scene = BuildingScene.camera(for: camera, viewport: viewport)
        eye = scene.position
        viewProjection = scene.projection.matrix(aspect: viewport.width / max(viewport.height, 1),
                                                 near: scene.near, far: scene.far) * scene.viewMatrix
    }

    /// Where a north-up point `height` dots above the reference is drawn,
    /// and its depth — its distance from the eye along the view, as the
    /// scene's depth buffer holds it; nil behind the eye.
    func toScreen(x: Double, y: Double, height: Double) -> (x: Double, y: Double, depth: Double)? {
        let clip = viewProjection * Vector4(BuildingScene.scenePoint(x: x, y: y, height: height, in: viewport), 1)
        guard clip.w > 0 else { return nil }
        return ((clip.x / clip.w + 1) / 2 * viewport.width, (1 - clip.y / clip.w) / 2 * viewport.height, clip.w)
    }

    /// The north-up point of the ground a point of the screen shows.
    func toGround(x: Double, y: Double) -> (x: Double, y: Double) {
        let flat = flatGround.toGround(x: x, y: y)
        guard !field.isFlat else { return flat }
        // The ray from the eye through the reference ground under the
        // screen point, as a share of that far: t = 1 is the flat ground.
        let target = BuildingScene.scenePoint(x: flat.x, y: flat.y, height: 0, in: viewport)
        let direction = target - eye
        let middleX = viewport.width / 2, middleY = viewport.height / 2
        func above(_ share: Double) -> Double {
            let point = eye + direction * share
            return point.y - field.height(x: point.x + middleX, y: point.z + middleY)
        }
        func groundOnRay(at share: Double) -> (x: Double, y: Double) {
            let point = eye + direction * share
            return (point.x + middleX, point.z + middleY)
        }
        // Steps of about `March.step` dots along the ground, out to past the
        // reference ground by as far again: a valley lies beyond it.
        let across = (direction.x * direction.x + direction.z * direction.z).squareRoot()
        let step = across > 0 ? March.step / across : March.furthestShare
        var previous = 0.0
        var share = step
        while share <= March.furthestShare {
            if above(share) <= 0 {
                var low = previous, high = share
                for _ in 0..<March.bisections {
                    let middle = (low + high) / 2
                    if above(middle) > 0 { low = middle } else { high = middle }
                }
                return groundOnRay(at: high)
            }
            previous = share
            share += step
        }
        return flat
    }

    private enum March {
        /// Dots of ground a step of the march crosses: fine enough that no
        /// ridge narrower than it is stepped over at a terminal's
        /// resolution, two dots being a half cell.
        static let step = 2.0
        /// Twice the distance to the reference ground: a valley floor
        /// below it lies further along the ray.
        static let furthestShare = 2.0
        /// Halvings of the step the crossing is narrowed by: 2 / 2¹⁶ of a
        /// dot.
        static let bisections = 16
    }
}

extension MapCamera {
    /// The unit-world point of the ground under a point of a viewport, on
    /// `terrain`: the first ground the view ray meets there.
    func groundWorldPoint(at point: DotPoint, in viewport: DotSize, terrain: TerrainSampler) -> WorldPoint {
        let field = ElevationField(camera: self, viewport: viewport, sampler: terrain)
        guard !field.isFlat else { return worldPoint(at: point, in: viewport) }
        let ground = TerrainProjection(camera: self, viewport: viewport, field: field).toGround(x: point.x, y: point.y)
        let centre = WebMercator.project(center)
        return WorldPoint(x: centre.x + (ground.x - viewport.width / 2) / dotsPerWorld,
                          y: centre.y + (ground.y - viewport.height / 2) / dotsPerWorld)
    }

    /// The coordinate under the middle of a cell of a map of `size` cells,
    /// on `terrain`: where a tap on a hillside lands.
    func coordinate(atCell cell: Point, in size: CanvasSize, terrain: TerrainSampler) -> GeoCoordinate {
        let dot = DotPoint(x: (Double(cell.x) + PointerOnTerrain.cellMiddle) * Double(BrailleCell.dotColumns),
                           y: (Double(cell.y) + PointerOnTerrain.cellMiddle) * Double(BrailleCell.dotRows))
        return WebMercator.unproject(groundWorldPoint(at: dot, in: MapRenderer.viewport(for: size), terrain: terrain))
            .normalized
    }

    /// The coordinate under the middle of a cell of a map of `size` cells
    /// drawn with `layers` — where a tap landed. On a realistic map with a
    /// terrain layer it is the ground the view shows there, a hill's face
    /// before the plain behind it; otherwise as
    /// ``coordinate(atCell:in:)``.
    @MainActor
    public func coordinate(atCell cell: Point, in size: CanvasSize, layers: MapLayers) -> GeoCoordinate {
        guard let terrain = layers.terrainSampler else { return coordinate(atCell: cell, in: size) }
        return coordinate(atCell: cell, in: size, terrain: terrain)
    }

    /// The camera moved by a drag on `terrain`: the ground grabbed at
    /// `start` ends under `end`.
    ///
    /// The heights are measured from the ground under the camera's centre,
    /// which the drag moves, so no one step lands it: from the flat drag,
    /// the centre is moved by however far the ground now under `end` lies
    /// from the ground grabbed, until it lies within a hundredth of a dot.
    func panned(dragging start: DotPoint, to end: DotPoint, in viewport: DotSize,
                terrain: TerrainSampler) -> MapCamera {
        let grabbed = groundWorldPoint(at: start, in: viewport, terrain: terrain)
        return settled(panned(dragging: start, to: end, in: viewport), holding: grabbed, at: end,
                       in: viewport, terrain: terrain)
    }

    /// The camera zoomed by `delta` levels on `terrain`, keeping the ground
    /// under `anchor` where it is on screen.
    func zoomed(by delta: Double, about anchor: DotPoint, in viewport: DotSize,
                terrain: TerrainSampler) -> MapCamera {
        let grabbed = groundWorldPoint(at: anchor, in: viewport, terrain: terrain)
        return settled(zoomed(by: delta, about: anchor, in: viewport), holding: grabbed, at: anchor,
                       in: viewport, terrain: terrain)
    }

    /// `camera`, its centre moved until the ground at `world` is under
    /// `point`: a few steps, each the miss between that ground and what is
    /// under the point, which shrinks as the ground under the centre settles.
    private func settled(_ camera: MapCamera, holding world: WorldPoint, at point: DotPoint, in viewport: DotSize,
                         terrain: TerrainSampler) -> MapCamera {
        var moved = camera
        for _ in 0..<PointerOnTerrain.settlingSteps {
            let under = moved.groundWorldPoint(at: point, in: viewport, terrain: terrain)
            let missX = world.x - under.x, missY = world.y - under.y
            guard (missX * missX + missY * missY).squareRoot() * moved.dotsPerWorld > PointerOnTerrain.closeEnough
            else { break }
            let centre = WebMercator.project(moved.center)
            moved.center = WebMercator.unproject(WorldPoint(x: centre.x + missX, y: centre.y + missY))
        }
        return moved
    }
}

private enum PointerOnTerrain {
    static let cellMiddle = 0.5
    /// A miss under this many dots is no miss a terminal can show.
    static let closeEnough = 0.01
    /// Each step leaves only the change in the centre's ground over the
    /// last, a small share of it: a few steps reach a hundredth of a dot.
    static let settlingSteps = 8
}
