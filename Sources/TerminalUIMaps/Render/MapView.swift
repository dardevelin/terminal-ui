import TerminalUI

/// A map you can move — SwiftUI MapKit's `Map`, drawn as text.
///
/// The basemap comes from a ``MapTileStore``; markers and polylines go in
/// the content closure. The map fills what its container offers, as a
/// ``Canvas`` does, and takes the pointer and, when focused, the keyboard:
///
/// - drag to pan, the map following the pointer;
/// - the wheel zooms in and out about the pointer, so what is under it
///   stays there, a level a notch; with Shift, a quarter of a level;
/// - arrows or `h` `j` `k` `l` pan by an eighth of the view, `+` and `-`
///   zoom by a level about its middle, and `]` and `[` by half a level.
///
/// The credit the source's licence requires is drawn in the bottom-right
/// corner.
///
/// ```swift
/// MapView(camera: $model.camera, store: store) {
///     Marker("The Copper Kettle", coordinate: cafe)
///     if let route = model.route {
///         MapPolyline(route)
///     }
/// }
/// ```
public struct MapView: TerminalView {
    let camera: Binding<MapCamera>
    let store: MapTileStore
    let content: MapContentGroup
    /// What a click on a point of interest does; see
    /// ``onPointOfInterestTap(perform:)``.
    var pointOfInterestAction: ((MapPointOfInterest) -> Void)?
    /// Imagery, terrain and how much of the basemap shows: set with
    /// ``mapLayers(_:)``.
    private(set) var layers = MapLayers.explore

    /// A map of `store`'s tiles seen through `camera`, which every pan and
    /// zoom writes back.
    public init(camera: Binding<MapCamera>, store: MapTileStore,
                @MapContentBuilder content: () -> MapContentGroup = { MapContentGroup() }) {
        self.camera = camera
        self.store = store
        self.content = content()
    }

    /// Run `action` with the point of interest a click lands on — its glyph
    /// or its name, as the last frame drew them. A click elsewhere on the
    /// map does nothing more than focus it.
    public func onPointOfInterestTap(perform action: @escaping (MapPointOfInterest) -> Void) -> MapView {
        var view = self
        view.pointOfInterestAction = action
        return view
    }

    /// Where a drag began and where it last moved the map from.
    struct DragTrack: Equatable {
        var start: Point
        var last: Point
    }

    /// The map drawn with `layers` — a map type's imagery, terrain and
    /// basemap detail (``MapTypeModel/layers``) — as SwiftUI's
    /// `.mapStyle(_:)` sets a `Map`'s.
    public func mapLayers(_ layers: MapLayers) -> MapView {
        var map = self
        map.layers = layers
        return map
    }

    @TerminalState private var drag: DragTrack? = nil
    /// Kept with the view's node, so the names it measured are measured
    /// once for the life of the map.
    @TerminalState private var renderer = MapRenderer()

    /// What the keys and the wheel move the map by.
    enum Steps {
        /// One key press pans this share of the view.
        static let panShare = 1.0 / 8
        /// One key press zooms a whole level.
        static let keyZoom = 1.0
        /// `]` and `[` zoom half as far, for a view between two levels.
        static let fineKeyZoom = 0.5
        /// A wheel notch arrives as three steps, as terminals scroll three
        /// lines a notch; three steps zoom one level.
        static let wheelZoom = 1.0 / 3
        /// Turned with Shift held — which a terminal reports as a
        /// horizontal wheel — a notch zooms a quarter of a level.
        static let fineWheelZoom = 1.0 / 12
        /// The wheel zooms about the middle of the pointer's cell.
        static let cellMiddle = 0.5
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Projected here, in `body`: inside the handlers they would capture
        // whichever node was being built.
        let drag = $drag
        let camera = camera, store = store, elements = content.mapElements, renderer = renderer, layers = layers
        let pointOfInterestAction = pointOfInterestAction
        Canvas { context, size in
            MapView.drawFrame(store: store, renderer: renderer, in: context, camera: camera.wrappedValue,
                              size: size, content: elements, layers: layers)
        }
        .gesture(DragGesture()
            .onChanged { value in
                var from = value.startLocation
                if let track = drag.wrappedValue, track.start == value.startLocation { from = track.last }
                camera.wrappedValue = camera.wrappedValue.panned(
                    byDotsX: Double((value.location.x - from.x) * BrailleCell.dotColumns),
                    y: Double((value.location.y - from.y) * BrailleCell.dotRows))
                drag.wrappedValue = DragTrack(start: value.startLocation, last: value.location)
            }
            .onEnded { _ in drag.wrappedValue = nil })
        .onClick { column, row in
            guard let pointOfInterestAction, var point = renderer.pointOfInterest(atColumn: column, row: row) else {
                return
            }
            point.featureIdentifiers = MainActor.assumeIsolated { store.info?.featureIdentifiers } ?? .opaque
            pointOfInterestAction(point)
        }
        .onScrollWheel { event in
            let delta: Double
            switch event.direction {
            case .up: delta = Steps.wheelZoom
            case .down: delta = -Steps.wheelZoom
            case .left: delta = Steps.fineWheelZoom
            case .right: delta = -Steps.fineWheelZoom
            }
            let viewport = MainActor.assumeIsolated { MapRenderer.viewport(for: store.viewSize) }
            let anchor = DotPoint(x: (Double(event.location.x) + Steps.cellMiddle) * Double(BrailleCell.dotColumns),
                                  y: (Double(event.location.y) + Steps.cellMiddle) * Double(BrailleCell.dotRows))
            let before = camera.wrappedValue
            let after = before.zoomed(by: delta, about: anchor, in: viewport)
            guard after != before else { return false }
            camera.wrappedValue = after
            return true
        }
        .focusable()
        .onKeyPress { event in
            let viewport = MainActor.assumeIsolated { MapRenderer.viewport(for: store.viewSize) }
            guard let moved = MapView.camera(camera.wrappedValue, movedBy: event, in: viewport) else {
                return .ignored
            }
            camera.wrappedValue = moved
            return .handled
        }
        // A map fills its pane edge to edge; a bar down its first column
        // would be drawn over the map. Its focus shows in what the keys do.
        .focusIndicator(.none)
    }

    /// The camera a key moves to, or nil for a key the map does not take.
    static func camera(_ camera: MapCamera, movedBy event: KeyEvent, in viewport: DotSize) -> MapCamera? {
        guard event.modifiers.isEmpty || event.modifiers == [.shift] else { return nil }
        let across = viewport.width * Steps.panShare, down = viewport.height * Steps.panShare
        switch event.key {
        case .left, .character("h"): return camera.panned(byDotsX: across, y: 0)
        case .right, .character("l"): return camera.panned(byDotsX: -across, y: 0)
        case .up, .character("k"): return camera.panned(byDotsX: 0, y: down)
        case .down, .character("j"): return camera.panned(byDotsX: 0, y: -down)
        case .character("+"), .character("="): return camera.zoomed(by: Steps.keyZoom)
        case .character("-"), .character("_"): return camera.zoomed(by: -Steps.keyZoom)
        case .character("]"): return camera.zoomed(by: Steps.fineKeyZoom)
        case .character("["): return camera.zoomed(by: -Steps.fineKeyZoom)
        default: return nil
        }
    }

    /// One frame: the store readied for it on the main actor, where the
    /// runtime draws, and only its values — the zooms, the tiles — carried
    /// out to the renderer.
    static func drawFrame(store: MapTileStore, renderer: MapRenderer, in context: GraphicsContext,
                          camera: MapCamera, size: CanvasSize, content: [MapElement],
                          layers: MapLayers = .explore) {
        let showsBasemap = layers.basemap != .hidden
        // A hidden basemap is not loaded: its tiles would be fetched and
        // never drawn.
        let zoomRange = MainActor.assumeIsolated {
            guard showsBasemap else {
                store.noteSize(size)
                return store.info?.zoomRange
            }
            return store.prepareFrame(camera: camera, size: size)
        }
        let frameLayers = MapFrameLayers(basemap: layers.basemap,
                                         imagery: layerTiles(layers.imagery, camera: camera, size: size),
                                         terrain: layerTiles(layers.terrain, camera: camera, size: size),
                                         terrainStyle: layers.terrainStyle)
        let drawsLayer = frameLayers.imagery != nil || frameLayers.terrain != nil
        if zoomRange != nil || drawsLayer {
            renderer.draw(in: context, camera: camera, size: size, zoomRange: zoomRange ?? 0...0, content: content,
                          layers: frameLayers) { id in
                showsBasemap ? MainActor.assumeIsolated { store.tile(id) } : nil
            }
        }
        let credits = [showsBasemap ? store : nil, layers.imagery, layers.terrain].compactMap { $0 }
        drawAttribution(MainActor.assumeIsolated { credits.compactMap { $0.info?.attribution } },
                        in: context, size: size)
    }

    /// A layer's tiles for a frame, its store readied for it, or nil until
    /// the store's source has said what it has.
    private static func layerTiles(_ store: MapTileStore?, camera: MapCamera, size: CanvasSize) -> MapLayerTiles? {
        guard let store,
              let zoomRange = MainActor.assumeIsolated({ store.prepareFrame(camera: camera, size: size) }) else {
            return nil
        }
        return MapLayerTiles(zoomRange: zoomRange) { id in MainActor.assumeIsolated { store.tile(id) } }
    }

    /// Each source's credit, a line apiece up from the bottom-right corner
    /// on a band of its own, so no map colour beneath it can drown it.
    static func drawAttribution(_ attributions: [String], in context: GraphicsContext, size: CanvasSize) {
        let theme = context.environment.theme
        let lines = attributionLines(attributions, width: Int(size.width) - Self.attributionPadding)
        for (index, attribution) in lines.reversed().enumerated() {
            context.draw(Text(TextSpan(" \(attribution) ", foreground: theme.foregroundMuted,
                                       background: theme.backgroundRaised)),
                         at: CanvasPoint(x: size.width, y: size.height - Double(index)), anchor: .bottomTrailing)
        }
    }

    /// The space each credit line is padded with, one either side.
    private static let attributionPadding = 2

    /// Credits as lines of at most `width` columns, each credit whole: a
    /// licence's required wording is never cut off. A credit too long is
    /// broken at its " · " parts, then at spaces; a credit given twice — two
    /// layers of one source — is shown once.
    static func attributionLines(_ attributions: [String], width: Int) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        let separator = " · "
        for attribution in attributions where !attribution.isEmpty && seen.insert(attribution).inserted {
            var line = ""
            for part in attribution.components(separatedBy: separator) {
                // A part that does not fit after what the line holds starts
                // a line of its own, wrapped at its words if it must be.
                if !line.isEmpty, line.count + separator.count + part.count > width {
                    lines.append(line)
                    line = ""
                }
                for (index, word) in part.split(separator: " ").enumerated() {
                    let joiner = line.isEmpty ? "" : (index == 0 ? separator : " ")
                    if !line.isEmpty, line.count + joiner.count + word.count > width {
                        lines.append(line)
                        line = String(word)
                    } else {
                        line += joiner + word
                    }
                }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
