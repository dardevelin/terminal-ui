import TerminalUI

/// Keeps a view's renderer for as long as the view is on screen, built the
/// first time it draws: a view value is made afresh every frame, and only
/// this small box with it.
final class SceneRendererBox {
    private(set) lazy var renderer = SceneRenderer()
}

/// A view that draws a ``Scene3D``, as SceneKit's `SceneView` does.
///
/// Like a ``Canvas`` it is greedy, filling what it is offered: give it a
/// flexible slot or a `.frame`. To animate it, build the scene from a
/// ``TimelineView``'s date:
///
/// ```swift
/// TimelineView(.animation) { context in
///     let angle = context.date.timeIntervalSinceReferenceDate
///     var scene = Scene3D(camera: Camera3D(position: Vector3(0, 1.5, 4)))
///     scene.add(.torus(), transform: Quaternion(axis: Vector3(1, 1, 0), angle: angle).matrix,
///               materials: [Material(theme.accent)])
///     SceneView(scene).framing(.fit())
/// }
/// ```
public struct SceneView: TerminalView {
    /// What is drawn.
    public let scene: Scene3D
    /// How the rendered scene becomes cells.
    public let shading: ShadingStyle
    /// How the scene is placed in the view.
    public private(set) var sceneFraming: SceneFraming = .camera
    @TerminalState private var box = SceneRendererBox()

    /// A view of `scene` in `shading`.
    public init(_ scene: Scene3D, shading: ShadingStyle = .image()) {
        self.scene = scene
        self.shading = shading
    }

    /// A view of `scene` seen through `camera`, in `shading`.
    public init(scene: Scene3D, camera: Camera3D, shading: ShadingStyle = .image()) {
        var placed = scene
        placed.camera = camera
        self.init(placed, shading: shading)
    }

    /// This view, placing its scene by `framing`: `.fit()` aims the camera
    /// at the scene and brings it in until the scene fills the view.
    public func framing(_ framing: SceneFraming) -> SceneView {
        var framed = self
        framed.sceneFraming = framing
        return framed
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let renderer = box.renderer, scene = scene, shading = shading, framing = sceneFraming
        return Canvas { context, size in
            renderer.draw(scene, in: context, size: size, shading: shading, framing: framing)
        }
    }
}

/// A canvas you build a 3D scene in, given its size in cells — the scene's
/// counterpart of ``Canvas``.
///
/// What the builder reads from an `@Observable` model is tracked as a
/// canvas's renderer's reads are: change it and the scene is built and drawn
/// again.
///
/// ```swift
/// Canvas3D { scene, size in
///     scene.camera = .orbit(around: .zero, distance: 8, azimuth: model.heading, elevation: 0.5)
///     scene.add(terrain, materials: [Material(gradient: [theme.info, theme.success, theme.foreground])])
///     scene.add(Label3D("summit", at: model.summit))
/// }
/// ```
public struct Canvas3D: TerminalView {
    /// How the rendered scene becomes cells.
    public let shading: ShadingStyle
    /// Fills in the scene, given the canvas's size in cells.
    public let builder: (inout Scene3D, CanvasSize) -> Void
    /// How the scene is placed in the canvas.
    public private(set) var sceneFraming: SceneFraming = .camera
    @TerminalState private var box = SceneRendererBox()

    /// A canvas whose scene `builder` fills in, drawn in `shading`.
    public init(shading: ShadingStyle = .image(), builder: @escaping (inout Scene3D, CanvasSize) -> Void) {
        self.shading = shading
        self.builder = builder
    }

    /// This canvas, placing its scene by `framing`.
    public func framing(_ framing: SceneFraming) -> Canvas3D {
        var framed = self
        framed.sceneFraming = framing
        return framed
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let renderer = box.renderer, builder = builder, shading = shading, framing = sceneFraming
        return Canvas { context, size in
            var scene = Scene3D()
            builder(&scene, size)
            renderer.draw(scene, in: context, size: size, shading: shading, framing: framing)
        }
    }
}
