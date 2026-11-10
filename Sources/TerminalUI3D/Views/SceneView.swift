import TerminalUI

/// Keeps a view's renderer for as long as the view is on screen, built the
/// first time it draws: a view value is made afresh every frame, and only
/// this small box with it.
final class SceneRendererBox {
    private(set) lazy var renderer = SceneRenderer()
}

/// A view that draws a ``Scene3D``, as SceneKit's `SceneView` does.
///
/// Give it a scene, or build one in a closure, as RealityKit's
/// `RealityView` does:
///
/// ```swift
/// SceneView(scene)
///
/// SceneView(shading: .hybrid()) { scene in
///     scene.add(.torus(), materials: [Material(theme.accent)])
///     scene.add(Label3D("north", at: Vector3(0, 0, -2)))
/// }
/// .framing(.fit())
/// ```
///
/// Like a `Canvas` it is greedy, filling what it is offered: give it a
/// flexible slot or a `.frame`. The scene is drawn when the view is built
/// again, and when the closure's reads of an `@Observable` model change —
/// tracked as a body's reads are. To animate it, build it in a
/// `TimelineView`, from the timeline's date:
///
/// ```swift
/// TimelineView(.animation) { context in
///     let seconds = context.date.timeIntervalSinceReferenceDate
///     SceneView { scene in
///         scene.add(.torus(), transform: Turntable().rotation(at: seconds).matrix,
///                   materials: [Material(theme.accent)])
///     }
///     .framing(.fit())
/// }
/// ```
public struct SceneView: TerminalView {
    private let content: (inout Scene3D) -> Void
    private let shading: ShadingStyle
    private var sceneFraming: SceneFraming = .camera
    @TerminalState private var box = SceneRendererBox()

    /// A view of `scene`, drawn in `shading`.
    public init(_ scene: Scene3D, shading: ShadingStyle = .image()) {
        self.init(shading: shading) { $0 = scene }
    }

    /// A view of the scene `content` fills in, starting from an empty one
    /// with the standard lights and camera, drawn in `shading`.
    public init(shading: ShadingStyle = .image(), content: @escaping (inout Scene3D) -> Void) {
        self.shading = shading
        self.content = content
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
        let renderer = box.renderer, content = content, shading = shading, framing = sceneFraming
        return Canvas { context, size in
            var scene = Scene3D()
            content(&scene)
            renderer.draw(scene, in: context, size: size, shading: shading, framing: framing)
        }
    }
}
