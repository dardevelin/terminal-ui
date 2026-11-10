/// A light on a scene: white, an intensity, and where it comes from.
///
/// Light has no colour of its own here — the materials carry the colour,
/// so that the theme alone decides what the scene is painted in. A scene's
/// lights add up: an ambient term lifts the shadowed sides off the
/// background, a directional key models the form, and a rim light outlines
/// the silhouette, which is what keeps a shape legible against a dark
/// ground.
///
/// ```swift
/// scene.lights = [
///     .ambient(0.15),
///     .directional(toward: Vector3(-0.4, 0.8, 0.6), intensity: 0.9),
///     .rim(0.4),
/// ]
/// ```
public struct Light3D: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case ambient
        case directional(Vector3)
        case rim(power: Double)
    }

    let kind: Kind
    /// How bright the light is: 1 lights a surface facing it fully.
    public var intensity: Double

    /// Light from everywhere at once, the same on every surface.
    public static func ambient(_ intensity: Double) -> Light3D {
        Light3D(kind: .ambient, intensity: intensity)
    }

    /// Light from far off — the sun — arriving from `direction`: the way
    /// toward the light, in the scene's coordinates.
    public static func directional(toward direction: Vector3, intensity: Double = 1) -> Light3D {
        Light3D(kind: .directional(direction.normalized), intensity: intensity)
    }

    /// Light that grazes the outline: brightest where a surface turns away
    /// from the camera, as `(1 − n·v)^power`. A higher `power` keeps it to a
    /// thinner rim.
    public static func rim(_ intensity: Double, power: Double = Light3D.defaultRimPower) -> Light3D {
        Light3D(kind: .rim(power: power), intensity: intensity)
    }

    /// A rim that falls off over about the outer third of a curved surface.
    public static let defaultRimPower = 3.0

    /// A key from above, front and left, a weak fill from the other side,
    /// ambient and a rim: what a scene that says nothing else is lit by.
    public static let standard: [Light3D] = [
        .ambient(0.12),
        .directional(toward: Vector3(-0.45, 0.75, 0.55), intensity: 0.85),
        .directional(toward: Vector3(0.6, -0.2, 0.3), intensity: 0.2),
        .rim(0.35),
    ]
}
