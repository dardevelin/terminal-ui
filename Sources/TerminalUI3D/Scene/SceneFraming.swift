import Foundation

/// How a view places its scene in its cells: through the scene's camera as
/// it is, or with the camera moved along its line of sight until the scene
/// fills the view.
///
/// ```swift
/// SceneView(scene).framing(.fit(padding: 1))
/// ```
public struct SceneFraming: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case camera
        case fit(padding: Double)
    }

    let kind: Kind

    /// The scene's camera, as it is.
    public static let camera = SceneFraming(kind: .camera)

    /// The camera kept looking the way it looks, but aimed at the middle of
    /// the scene's models and moved in or out until they just fit, `padding`
    /// rows inside the view's top and bottom and twice as many columns
    /// inside its sides — the same distance on cells about twice as tall as
    /// they are wide.
    ///
    /// Across, a sphere round every model must fit, so a model turning about
    /// the camera's up keeps its size from frame to frame; up and down, only
    /// the models' boxes, which such a turn leaves alone — so a wide thing
    /// turning, a wordmark, fills the view rather than a sphere's square
    /// round it. Measured in the view's own shape, two samples across a cell
    /// for four down, so a round thing stays round. A perspective camera
    /// keeps its field of view, an orthographic one its direction and takes
    /// the height that fits.
    public static func fit(padding: Double = 1) -> SceneFraming {
        SceneFraming(kind: .fit(padding: max(0, padding)))
    }

    /// The camera that shows `scene` as this framing does, in a view of
    /// `columns` × `rows` cells.
    func camera(for scene: Scene3D, columns: Int, rows: Int) -> Camera3D {
        guard case .fit(let padding) = kind, columns > 0, rows > 0,
              let sphere = Self.boundingSphere(of: scene.models) else { return scene.camera }
        var camera = scene.camera
        var direction = (camera.position - camera.target).normalized
        if direction == .zero { direction = .unitZ }
        // A cell's padding is one row down and two columns across: the same
        // distance on cells twice as tall as wide.
        let usableHeight = max(Self.leastUsable, 1 - 2 * padding / Double(rows))
        let usableWidth = max(Self.leastUsable, 1 - 2 * padding * Self.columnsPerRow / Double(columns))
        let aspect = Double(columns) / (Double(rows) * Self.columnsPerRow)
        let radius = max(sphere.radius, Self.smallestRadius)
        // The camera's up, square to its line of sight.
        let side = direction.cross(camera.up).normalized
        let up = side == .zero ? Vector3.unitY : side.cross(direction).normalized
        let tall = min(radius, max(Self.halfExtent(of: scene.models, about: sphere.centre, along: up),
                                   Self.smallestRadius))
        switch camera.projection.kind {
        case .perspective(let fieldOfView):
            let reach = tan(fieldOfView / 2)
            let across = reach * aspect * usableWidth, down = reach * usableHeight
            // A sphere seen at distance d spans the angle whose sine is r/d.
            // Up and down the boxes may fit nearer: their top may come as
            // near as d − r, where it spans most. Whichever is nearer fits.
            func sphereDistance(_ tangent: Double) -> Double { radius * (1 + tangent * tangent).squareRoot() / tangent }
            let distance = max(sphereDistance(across), min(sphereDistance(down), tall / down + radius))
            camera.position = sphere.centre + direction * distance
            camera.near = max(distance - radius * Self.depthMargin, distance * Self.nearestShare)
            camera.far = distance + radius * Self.depthMargin
        case .orthographic:
            let halfHeight = max(tall / usableHeight, radius / (aspect * usableWidth))
            let distance = max((camera.position - camera.target).length, radius * Self.depthMargin)
            camera.projection = .orthographic(height: halfHeight * 2)
            camera.position = sphere.centre + direction * distance
            camera.near = max(distance - radius * Self.depthMargin, distance * Self.nearestShare)
            camera.far = distance + radius * Self.depthMargin
        }
        camera.target = sphere.centre
        return camera
    }

    /// Columns of cells to a row's height.
    private static let columnsPerRow = 2.0
    /// The least share of the view a fit uses, however much padding it is
    /// asked for.
    private static let leastUsable = 0.1
    /// A scene of a single point is framed as one this big.
    private static let smallestRadius = 1e-6
    /// How far past the sphere the clipping planes sit, in radii.
    private static let depthMargin = 2.0
    /// The nearest a clipping plane comes, as a share of the distance.
    private static let nearestShare = 0.01

    /// How far the models' boxes, each carried by its transform, reach from
    /// `centre` along `axis`, either way.
    static func halfExtent(of models: [Model3D], about centre: Vector3, along axis: Vector3) -> Double {
        var reach = 0.0
        for model in models {
            guard let bounds = model.mesh.bounds else { continue }
            for corner in 0..<Self.boxCorners {
                let point = Vector3(corner & 1 == 0 ? bounds.minimum.x : bounds.maximum.x,
                                    corner & 2 == 0 ? bounds.minimum.y : bounds.maximum.y,
                                    corner & 4 == 0 ? bounds.minimum.z : bounds.maximum.z)
                reach = max(reach, abs((model.transform.transformPoint(point) - centre).dot(axis)))
            }
        }
        return reach
    }

    /// A box's corners, one bit per axis choosing its low or high side.
    private static let boxCorners = 8

    /// A sphere holding every vertex of every model — each model's own,
    /// carried by its transform, then the smallest holding those (Ritter,
    /// "An Efficient Bounding Sphere", Graphics Gems, 1990).
    static func boundingSphere(of models: [Model3D]) -> (centre: Vector3, radius: Double)? {
        var result: (centre: Vector3, radius: Double)?
        for model in models {
            guard let bounds = model.mesh.bounds else { continue }
            let middle = (bounds.minimum + bounds.maximum) / 2
            var radius = 0.0
            for position in model.mesh.positions { radius = max(radius, (position - middle).length) }
            let transform = model.transform
            let scale = max(transform.transformDirection(.unitX).length, transform.transformDirection(.unitY).length,
                            transform.transformDirection(.unitZ).length)
            let sphere = (centre: transform.transformPoint(middle), radius: radius * scale)
            guard let current = result else {
                result = sphere
                continue
            }
            let apart = (sphere.centre - current.centre).length
            if apart + sphere.radius <= current.radius { continue }
            if apart + current.radius <= sphere.radius {
                result = sphere
                continue
            }
            let radiusBoth = (apart + current.radius + sphere.radius) / 2
            let towards = (sphere.centre - current.centre) / apart
            result = (current.centre + towards * (radiusBoth - current.radius), radiusBoth)
        }
        return result
    }
}
