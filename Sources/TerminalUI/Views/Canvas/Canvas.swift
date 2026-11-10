import Observation

/// A view you draw into, as SwiftUI's `Canvas`: paths stroked and filled,
/// and text placed, at sub-cell resolution.
///
/// The renderer runs when the canvas is drawn, with the size it was given in
/// cells, and draws through a ``GraphicsContext`` — no views are built, so a
/// canvas redrawing thousands of segments costs only the drawing. It runs
/// again when the canvas has something new to show: the view holding it
/// builds it again, what the renderer read from an `@Observable` model
/// changes (tracked as a body's reads are), the environment around it may
/// have changed, or its size or background does. A frame drawn for anything
/// else — a spinner beside it, the cursor — shows what it last drew, so draw
/// from state, not from the clock: to animate, put the canvas in a
/// ``TimelineView``.
///
/// Like ``GeometryReader`` a canvas is greedy: it fills what its container
/// offers, and claims nothing from a container that sizes itself to its
/// content — give it a flexible slot or a `.frame`. Gestures, `.onClick` and
/// the rest attach to it as to any view, with locations in its own cells.
///
/// Where the renderer draws nothing the canvas is transparent, and what lies
/// beneath it shows — in a `ZStack`, the layers under it. A `.background`
/// around the canvas lies beneath everything it draws instead, as it does
/// for any view, and `opaque` blanks those cells in the canvas's style.
///
/// ```swift
/// Canvas { context, size in
///     let ground = CanvasRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
///     context.fill(Path(ground), with: .color(theme.successSubtle))
///     var route = Path()
///     route.addLines([CanvasPoint(x: 2, y: 1), CanvasPoint(x: 18, y: 7), CanvasPoint(x: 34, y: 2)])
///     context.stroke(route, with: .color(theme.accent))
///     context.draw(Text("summit"), at: CanvasPoint(x: 34, y: 2), anchor: .bottomLeading)
/// }
/// .frame(height: 8)
/// ```
public struct Canvas: TerminalView {
    /// Whether the cells the renderer leaves alone are blanked rather than
    /// showing what lies beneath the canvas.
    public let opaque: Bool
    /// Draws the canvas's content, given its context and its size in cells.
    public let renderer: (inout GraphicsContext, CanvasSize) -> Void

    /// A canvas drawn by `renderer`.
    ///
    /// - Parameters:
    ///   - opaque: Blank every cell the renderer does not draw in.
    ///   - renderer: Draws into the context, given the canvas's size in
    ///     cells. It runs each time the canvas is drawn.
    public init(opaque: Bool = false,
                renderer: @escaping (inout GraphicsContext, CanvasSize) -> Void) {
        self.opaque = opaque
        self.renderer = renderer
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError("Canvas is drawn by the renderer; body is never called") }
}

extension TerminalView {
    /// Stroke at `resolution` in every ``Canvas`` in this view: braille dots,
    /// half cells or whole cells. Fills and text are not affected.
    ///
    /// ```swift
    /// RouteMap().canvasResolution(.halfBlock)
    /// ```
    public func canvasResolution(_ resolution: CanvasResolution)
        -> ModifiedView<Self, EnvironmentModifier<CanvasResolution>> {
        environment(\.canvasResolution, resolution)
    }
}

extension GraphRenderer {
    /// Run a canvas's renderer into the planes its node keeps, and composite
    /// them into the cells of `context.rect`.
    static func renderCanvas(_ canvas: Canvas, node: AttributeNode,
                             into buffer: inout CellBuffer, context: RenderContext) {
        let rect = context.rect
        guard rect.width > 0, rect.height > 0 else { return }
        let raster: CanvasRaster
        if let existing = node.canvasRaster {
            raster = existing
        } else {
            raster = CanvasRaster()
            node.canvasRaster = raster
        }
        let ground = context.style.background
        if raster.needsRender || raster.width != rect.width || raster.height != rect.height
            || raster.inheritedGround != ground {
            raster.begin(width: rect.width, height: rect.height, inheritedGround: ground)
            var graphics = GraphicsContext(
                raster: raster, environment: GraphContext.currentEnvironment ?? EnvironmentValues())
            let size = CanvasSize(width: Double(rect.width), height: Double(rect.height))
            // Tracked only when the renderer runs: a tracking stays armed
            // until what it read changes, so one taken every frame would pile
            // up for as long as the model held still.
            if let inbox = raster.inbox {
                weak let weakNode: AttributeNode? = node
                weak let weakInbox: InvalidationInbox? = inbox
                withObservationTracking {
                    canvas.renderer(&graphics, size)
                } onChange: {
                    if let node = weakNode { weakInbox?.post(node) }
                }
            } else {
                canvas.renderer(&graphics, size)
            }
            raster.needsRender = false
        }
        raster.composite(into: &buffer, at: rect, style: context.style, opaque: canvas.opaque)
    }
}
