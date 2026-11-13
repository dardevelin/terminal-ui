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
