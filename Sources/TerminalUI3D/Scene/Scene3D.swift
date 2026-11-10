import TerminalUI

/// A mesh placed in a scene, and the materials its triangles are drawn in.
public struct Model3D: Sendable, Equatable {
    /// The surface.
    public var mesh: Mesh
    /// Where the mesh is placed: model space to the scene's.
    public var transform: Matrix4
    /// The materials the mesh's triangles name by index; a triangle naming
    /// one past the end takes the last, and a model with none takes the
    /// theme's accent.
    public var materials: [Material]

    /// `mesh` placed by `transform`, drawn in `materials`.
    public init(_ mesh: Mesh, transform: Matrix4 = .identity, materials: [Material] = []) {
        self.mesh = mesh
        self.transform = transform
        self.materials = materials
    }
}

/// Text pinned to a point in the scene: a place name on a map, a callout.
///
/// A label is drawn upright, on whole cells, beside the point it names. It
/// is hidden when something in the scene stands in front of that point,
/// and when it would overlap a label drawn before it — so the labels that
/// matter most come first.
public struct Label3D: Sendable, Equatable {
    /// What it says.
    public var text: String
    /// The point it names, in the scene's coordinates.
    public var position: Vector3
    /// Its colour; nil takes the theme's foreground.
    public var colour: Color?
    /// Whether it is bold.
    public var bold: Bool
    /// Whether a mark is drawn on the point itself.
    public var marksPoint: Bool

    /// `text` naming `position`.
    public init(_ text: String, at position: Vector3, colour: Color? = nil, bold: Bool = false,
                marksPoint: Bool = true) {
        self.text = text
        self.position = position
        self.colour = colour
        self.bold = bold
        self.marksPoint = marksPoint
    }
}

/// Haze that thickens with distance from the camera, mixing what is far
/// toward the background — depth a flat terminal can show.
///
/// It needs a background colour to mix toward: the scene's, or else the
/// theme's. A theme whose background is the terminal's own, which no
/// program can know, draws no fog.
public struct Fog3D: Sendable, Equatable {
    /// Where the haze begins, in scene units from the camera.
    public var start: Double
    /// Where it is thickest.
    public var end: Double
    /// How thick it is at its thickest, 0 to 1: 1 hides what lies beyond
    /// `end` altogether.
    public var density: Double

    /// Haze from `start` to `end`, `density` thick at its thickest.
    public init(start: Double, end: Double, density: Double = 1) {
        self.start = start
        self.end = end
        self.density = density
    }
}

/// What a ``SceneView`` draws: models, the lights they are lit by, the
/// camera they are seen from, and labels pinned to points among them.
///
/// A scene is a value, built afresh in a body as cheaply as a view is —
/// keep a large mesh in a constant or a model and place it, rather than
/// building its triangles again each frame.
///
/// ```swift
/// var scene = Scene3D(camera: .orbit(around: .zero, distance: 5, azimuth: angle, elevation: 0.4))
/// scene.add(.torus(), materials: [Material(theme.accent)])
/// scene.add(Label3D("north", at: Vector3(0, 0, -2)))
/// ```
public struct Scene3D: Sendable, Equatable {
    /// Where the scene is seen from.
    public var camera: Camera3D
    /// What is in it.
    public var models: [Model3D]
    /// What lights it.
    public var lights: [Light3D]
    /// Text pinned to points in it.
    public var labels: [Label3D]
    /// Haze with distance, or none.
    public var fog: Fog3D?
    /// The colour behind everything, or nil to draw nothing there and let
    /// what lies beneath the view show. Fog and the edges of shapes are
    /// mixed toward it, or toward the theme's background when it is nil.
    public var background: Color?

    /// A scene seen through `camera`, lit by `lights`.
    public init(camera: Camera3D = Camera3D(), models: [Model3D] = [], lights: [Light3D] = Light3D.standard,
                labels: [Label3D] = [], fog: Fog3D? = nil, background: Color? = nil) {
        self.camera = camera
        self.models = models
        self.lights = lights
        self.labels = labels
        self.fog = fog
        self.background = background
    }

    /// Place `mesh` in the scene by `transform`, drawn in `materials`.
    public mutating func add(_ mesh: Mesh, transform: Matrix4 = .identity, materials: [Material] = []) {
        models.append(Model3D(mesh, transform: transform, materials: materials))
    }

    /// Pin `label` in the scene.
    public mutating func add(_ label: Label3D) {
        labels.append(label)
    }
}
