import Foundation

/// How a camera flattens the scene onto the screen.
public struct Projection3D: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case perspective(fieldOfView: Double)
        case orthographic(height: Double)
    }

    let kind: Kind

    /// Things shrink with distance, as an eye sees them: `fieldOfView`
    /// radians from the bottom of the view to its top.
    public static func perspective(fieldOfView: Double = Projection3D.defaultFieldOfView) -> Projection3D {
        Projection3D(kind: .perspective(fieldOfView: fieldOfView))
    }

    /// Things keep their size at any distance, as on a plan: the view is
    /// `height` scene units from bottom to top.
    public static func orthographic(height: Double) -> Projection3D {
        Projection3D(kind: .orthographic(height: height))
    }

    /// Sixty degrees: about what a monitor at arm's length spans.
    public static let defaultFieldOfView = Double.pi / 3

    /// The projection into OpenGL's clip space for a view `aspect` times
    /// wider than it is tall, seeing from `near` to `far`.
    package func matrix(aspect: Double, near: Double, far: Double) -> Matrix4 {
        switch kind {
        case .perspective(let fieldOfView):
            return .perspective(fieldOfView: fieldOfView, aspect: aspect, near: near, far: far)
        case .orthographic(let height):
            let halfHeight = height / 2, halfWidth = halfHeight * aspect
            return .orthographic(left: -halfWidth, right: halfWidth, bottom: -halfHeight, top: halfHeight,
                                 near: near, far: far)
        }
    }

    var isPerspective: Bool {
        if case .perspective = kind { return true }
        return false
    }
}

/// Where a scene is seen from, what it looks at, and how it is projected.
///
/// ```swift
/// var camera = Camera3D(position: Vector3(0, 2, 6), target: .zero)
/// camera = .orbit(around: .zero, distance: 6, azimuth: time * 0.3, elevation: 0.35)
/// ```
public struct Camera3D: Sendable, Equatable {
    /// Where the camera is.
    public var position: Vector3
    /// The point it looks at.
    public var target: Vector3
    /// Which way is up for it; it need not be square to the view.
    public var up: Vector3
    /// How it flattens the scene.
    public var projection: Projection3D
    /// The nearest it sees: anything closer is cut away.
    public var near: Double
    /// The furthest it sees.
    public var far: Double

    /// A camera at `position` looking at `target`.
    public init(position: Vector3 = Vector3(0, 0, Camera3D.defaultDistance), target: Vector3 = .zero,
                up: Vector3 = .unitY, projection: Projection3D = .perspective(),
                near: Double = Camera3D.defaultNear, far: Double = Camera3D.defaultFar) {
        self.position = position
        self.target = target
        self.up = up
        self.projection = projection
        self.near = near
        self.far = far
    }

    /// A camera `distance` from `target`, turned `azimuth` radians round it
    /// from +z toward +x, and raised `elevation` radians above its level.
    public static func orbit(around target: Vector3, distance: Double, azimuth: Double, elevation: Double,
                             projection: Projection3D = .perspective()) -> Camera3D {
        let level = cos(elevation)
        let offset = Vector3(sin(azimuth) * level, sin(elevation), cos(azimuth) * level) * distance
        return Camera3D(position: target + offset, target: target, projection: projection,
                        far: max(defaultFar, distance * 4))
    }

    /// The world as the camera sees it: the camera at the origin, looking
    /// down −z.
    public var viewMatrix: Matrix4 {
        .lookAt(eye: position, target: target, up: up)
    }

    /// Six units back: a unit-sized model fills a third of the view.
    public static let defaultDistance = 6.0
    /// A tenth of a unit.
    public static let defaultNear = 0.1
    /// A hundred units.
    public static let defaultFar = 100.0
}
