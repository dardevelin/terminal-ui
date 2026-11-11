import TerminalUI
import TerminalUIIO

/// What the last frame a ``MapRenderer`` drew cost and showed.
struct MapRenderStatistics: Sendable, Equatable {
    /// Tiles drawn at the frame's tile zoom.
    var tilesDrawn = 0
    /// Tiles missing at that zoom and drawn from a cached ancestor instead.
    var fallbackTiles = 0
    /// Tiles missing at that zoom and drawn from cached descendants that
    /// cover them whole — what a zoom out draws until its tiles land.
    var descendantTiles = 0
    /// Tiles with neither, left blank.
    var missingTiles = 0
    /// Areas and lines drawn, and those passed over as off screen.
    var featuresDrawn = 0
    var featuresCulled = 0
    /// Points given to the canvas, and those dropped as within a dot of
    /// the point before.
    var verticesDrawn = 0
    var verticesDropped = 0
    /// Names offered to the label placer, and those it found room for.
    var labelsOffered = 0
    var labelsPlaced = 0
    /// Points of interest passed over by the zoom's rank cut
    /// (``PointOfInterestDensity``), and those placed, with their name or
    /// as a glyph alone.
    var pointsOfInterestCut = 0
    var pointsOfInterestPlaced = 0

    init() {}
}

/// Draws a map into a ``GraphicsContext``: the basemap of the tiles at
/// hand for a camera, and markers and polylines over it.
///
/// Geometry is drawn in braille dots — the context scaled so a unit is a
/// dot, two across and four down a cell, and a dot about square — so the
/// projection, a line's width and the one-dot simplification all share one
/// unit. Areas fill on half cells, lines stroke in braille, and names go
/// through a ``LabelPlacer`` the renderer keeps from frame to frame, so a
/// name is measured once however many frames show it.
///
/// Tiles are drawn at the camera's zoom rounded down, held to the zooms the
/// source has: deeper than its last, its last is drawn larger. A tile not
/// at hand is drawn from cached descendants when they cover it whole — the
/// tiles a zoom out leaves behind — else from the nearest ancestor that is
/// at hand, cut to the missing tile's square, else from what descendants
/// there are, and only then left blank: a zoom either way never blanks the
/// map while its tiles load.
///
/// Keep one renderer for a map and draw it every frame:
///
/// ```swift
/// let renderer = MapRenderer()
/// Canvas { context, size in
///     renderer.draw(in: context, camera: camera, size: size, zoomRange: 0...14) { id in cache[id] }
/// }
/// ```
final class MapRenderer {
    var labelPlacer = LabelPlacer()

    /// What the last frame drew.
    public internal(set) var statistics = MapRenderStatistics()
    /// The names the last frame placed.
    public internal(set) var placedLabels: [PlacedLabel] = []
    /// How many distinct names the renderer has measured: each once.
    var labelMeasurements: Int { labelPlacer.measurements }

    /// How many zooms out a missing tile looks for a cached ancestor: past
    /// eight, the ancestor's own cell would be a whole tile wide.
    static let fallbackDepth = 8

    /// How many zooms in a missing tile looks for cached descendants: two
    /// is the sixteen tiles a two-level zoom out leaves, and each level
    /// deeper quadruples the lookups.
    static let descendantDepth = 2

    /// How many points of interest a frame offers, by zoom.
    var pointOfInterestDensity = PointOfInterestDensity.standard

    /// The points of interest the last frame placed, glyph and name.
    public internal(set) var placedPointsOfInterest: [MapPointOfInterest] = []

    init() {}

    /// The viewport, in dots, of a canvas of `size` cells.
    static func viewport(for size: CanvasSize) -> DotSize {
        DotSize(width: max(0, size.width.rounded(.down)) * Double(BrailleCell.dotColumns),
                height: max(0, size.height.rounded(.down)) * Double(BrailleCell.dotRows))
    }

    /// The tiles a frame of `size` cells draws, nearest the centre first:
    /// the ones a tile store should have at hand.
    static func tiles(for camera: MapCamera, size: CanvasSize,
                             zoomRange: ClosedRange<Int>) -> [TileID] {
        let viewport = viewport(for: size)
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        return camera.coveringTiles(in: viewport, sourceZoomRange: zoomRange)
    }

    /// Draw a frame.
    ///
    /// - Parameters:
    ///   - context: The canvas's context; its environment's theme colours
    ///     the map.
    ///   - camera: Where the map looks.
    ///   - size: The canvas's size in cells.
    ///   - zoomRange: The zooms the tile source has.
    ///   - content: Markers and polylines to draw over the basemap.
    ///   - layers: Imagery beneath the basemap, terrain over its areas, and
    ///     how much of the basemap to draw.
    ///   - lookup: The tile at hand for an id, or nil.
    func draw(in context: GraphicsContext, camera: MapCamera, size: CanvasSize,
                     zoomRange: ClosedRange<Int>, content: [MapElement] = [],
                     layers: MapFrameLayers = MapFrameLayers(),
                     tiles lookup: (TileID) -> RenderTile?) {
        statistics = MapRenderStatistics()
        placedLabels = []
        let viewport = Self.viewport(for: size)
        guard viewport.width > 0, viewport.height > 0 else { return }
        let theme = context.environment.theme
        var dots = context
        dots.scaleBy(x: 1 / Double(BrailleCell.dotColumns), y: 1 / Double(BrailleCell.dotRows))
        let projection = Projection(camera: camera, viewport: viewport)

        let items = layers.basemap == .hidden ? [] : plan(camera: camera, viewport: viewport, zoomRange: zoomRange,
                                                          projection: projection, dots: dots, lookup: lookup)
        drawGround(layers, camera: camera, viewport: viewport, projection: projection, dots: dots, theme: theme)
        if layers.basemap == .full {
            drawShapes(items, geometry: .area, zoom: camera.zoom, projection: projection, theme: theme)
        }
        drawPictures(items, projection: projection)
        drawRelief(layers, camera: camera, viewport: viewport, projection: projection, dots: dots, theme: theme)
        drawShapes(items, geometry: .line, zoom: camera.zoom, projection: projection, theme: theme)
        drawPolylines(content, camera: camera, viewport: viewport, projection: projection, dots: dots, theme: theme)
        drawLabels(items, content: content, camera: camera, projection: projection, size: size,
                   context: context, theme: theme, background: layers.labelBackground(in: theme))
    }

    // MARK: - Planning

    /// A tile to draw and where: its square on screen, in dots, and the
    /// context it draws through — cut to the squares of the tiles it stands
    /// in for, when it is an ancestor.
    struct Item {
        var tile: RenderTile
        var originX: Double
        var originY: Double
        var side: Double
        var context: GraphicsContext
        /// The squares of the missing tiles an ancestor stands in for, in
        /// dots; nil for a tile drawn as itself.
        var standsIn: [CanvasRect]?

        func covers(x: Double, y: Double) -> Bool {
            guard let standsIn else { return true }
            return standsIn.contains { square in
                x >= square.x && x < square.x + square.width && y >= square.y && y < square.y + square.height
            }
        }
    }

    /// Where tiles land on screen. Tiles are laid out north up; the
    /// camera's ``GroundProjection`` then turns every point by the bearing
    /// and tips it by the pitch, once, in ``toScreen(x:y:)`` — the
    /// projection ``MapCamera`` applies to markers and to the pointer, so a
    /// click, a label and a road agree.
    struct Projection {
        let centre: WorldPoint
        let dotsPerWorld: Double
        let viewport: DotSize
        let ground: GroundProjection
        /// The camera's zoom: the scale at the middle of the view.
        let zoom: Double
        /// Pitched, the ground the view shows and a margin round it, north
        /// up: what a shape is cut to before it is projected, so nothing
        /// behind the eye is drawn. Nil flat, where the screen clips.
        let footprint: ConvexRegion?

        /// How far past each edge of the view a pitched footprint reaches,
        /// in dots: past the widest line's half width, so no line's end
        /// shows where it was cut.
        static let footprintMargin = 8.0

        init(camera: MapCamera, viewport: DotSize) {
            centre = WebMercator.project(camera.center)
            dotsPerWorld = camera.dotsPerWorld
            self.viewport = viewport
            ground = camera.groundProjection(in: viewport)
            zoom = camera.zoom
            footprint = ground.isFlat ? nil : ground.footprint(of: viewport, margin: Self.footprintMargin)
        }

        /// North up and flat: a point of the map is the point of the screen.
        var isAxisAligned: Bool { ground.isAxisAligned }

        /// A north-up point of the map where the camera puts it on screen,
        /// or nil behind a pitched camera's eye.
        func toScreen(x: Double, y: Double) -> (x: Double, y: Double)? {
            ground.toScreen(x: x, y: y)
        }

        /// The zoom a north-up point of the map is drawn at: the camera's
        /// flat, and pitched, less where the ground recedes and more where
        /// it nears — what decides which names it carries.
        func zoom(atX x: Double, y: Double) -> Double {
            ground.zoom(zoom, atX: x, y: y)
        }

        /// A screen point back where it lies on the north-up map.
        func toGround(x: Double, y: Double) -> (x: Double, y: Double) {
            ground.toGround(x: x, y: y)
        }

        /// The north-up box whose points can reach the screen: the
        /// viewport itself; turned, the square around the circle that
        /// holds it; pitched, the box round the ground it shows.
        var reach: (left: Double, top: Double, right: Double, bottom: Double) {
            if let footprint { return footprint.bounds }
            guard !isAxisAligned else { return (0, 0, viewport.width, viewport.height) }
            let radius = (viewport.width * viewport.width + viewport.height * viewport.height).squareRoot() / 2
            return (viewport.width / 2 - radius, viewport.height / 2 - radius,
                    viewport.width / 2 + radius, viewport.height / 2 + radius)
        }

        /// A square's outline as a path through its corners on screen,
        /// cut first, pitched, to the ground the view shows.
        func outline(_ square: CanvasRect) -> Path {
            var corners = [CanvasPoint(x: square.x, y: square.y), CanvasPoint(x: square.x + square.width, y: square.y),
                           CanvasPoint(x: square.x + square.width, y: square.y + square.height),
                           CanvasPoint(x: square.x, y: square.y + square.height)]
            if let footprint { corners = footprint.clipped(ring: corners) }
            return Path { path in
                path.addLines(corners.compactMap(screenPoint))
                path.closeSubpath()
            }
        }

        func screenPoint(_ point: CanvasPoint) -> CanvasPoint? {
            toScreen(x: point.x, y: point.y).map { CanvasPoint(x: $0.x, y: $0.y) }
        }

        /// A north-up line on screen: whole when flat, and pitched, the
        /// runs of it the view's ground holds.
        func screenRuns(of line: [CanvasPoint]) -> [[CanvasPoint]] {
            guard let footprint else { return [line.compactMap(screenPoint)] }
            return footprint.runs(of: line).map { $0.compactMap(screenPoint) }
        }

        /// A tile's square, in dots: its top-left corner and its side. A
        /// tile further east or west than half the world is taken the short
        /// way round, as the camera takes a coordinate.
        func square(of tile: TileID) -> (x: Double, y: Double, side: Double) {
            let count = Double(TileID.tilesPerSide(atZoom: tile.zoom))
            var middle = (Double(tile.x) + Self.tileMiddle) / count - centre.x
            if middle > Self.halfWorld { middle -= 1 } else if middle < -Self.halfWorld { middle += 1 }
            let side = dotsPerWorld / count
            return (viewport.width / 2 + middle * dotsPerWorld - side / 2,
                    viewport.height / 2 + (Double(tile.y) / count - centre.y) * dotsPerWorld,
                    side)
        }

        private static let tileMiddle = 0.5
        private static let halfWorld = 0.5
    }

    /// The tiles of a source to draw: those at hand at the frame's zoom,
    /// and an ancestor cut to the squares of each missing one. A layer's
    /// tiles are planned so too, `countsTiles` false keeping them out of
    /// the basemap's statistics.
    func plan(camera: MapCamera, viewport: DotSize, zoomRange: ClosedRange<Int>, projection: Projection,
              dots: GraphicsContext, countsTiles: Bool = true, lookup: (TileID) -> RenderTile?) -> [Item] {
        var items: [Item] = []
        var standIns: [TileID: (tile: RenderTile, missing: [TileID])] = [:]
        var standInOrder: [TileID] = []
        func clipped(to squares: [CanvasRect]) -> GraphicsContext {
            var context = dots
            if !projection.isAxisAligned {
                context.clip(to: Path { path in squares.forEach { path.addPath(projection.outline($0)) } })
            } else {
                context.clip(to: Path { path in squares.forEach { path.addRect($0) } })
            }
            return context
        }
        func ownSquare(_ id: TileID) -> CanvasRect {
            let square = projection.square(of: id)
            return CanvasRect(x: square.x, y: square.y, width: square.side, height: square.side)
        }
        func addDescendants(_ tiles: [RenderTile]) {
            for tile in tiles {
                let square = projection.square(of: tile.id), own = ownSquare(tile.id)
                items.append(Item(tile: tile, originX: square.x, originY: square.y, side: square.side,
                                  context: clipped(to: [own]), standsIn: [own]))
            }
        }
        for id in camera.coveringTiles(in: viewport, sourceZoomRange: zoomRange) {
            if let tile = lookup(id) {
                let square = projection.square(of: id)
                items.append(Item(tile: tile, originX: square.x, originY: square.y, side: square.side,
                                  context: dots, standsIn: nil))
                if countsTiles { statistics.tilesDrawn += 1 }
                continue
            }
            let descendants = Self.cachedDescendants(of: id, depth: Self.descendantDepth, lookup: lookup)
            if descendants.isComplete {
                addDescendants(descendants.tiles)
                if countsTiles { statistics.descendantTiles += 1 }
                continue
            }
            var ancestor = id.parent
            var depth = 1
            var found = false
            while let candidate = ancestor, depth <= Self.fallbackDepth {
                if standIns[candidate] != nil {
                    standIns[candidate]?.missing.append(id)
                    found = true
                    break
                }
                if let tile = lookup(candidate) {
                    standIns[candidate] = (tile, [id])
                    standInOrder.append(candidate)
                    found = true
                    break
                }
                ancestor = candidate.parent
                depth += 1
            }
            if !found, !descendants.tiles.isEmpty { addDescendants(descendants.tiles) }
            if countsTiles {
                if found {
                    statistics.fallbackTiles += 1
                } else if !descendants.tiles.isEmpty {
                    statistics.descendantTiles += 1
                } else {
                    statistics.missingTiles += 1
                }
            }
        }
        for ancestorID in standInOrder {
            guard let standIn = standIns[ancestorID] else { continue }
            let square = projection.square(of: ancestorID)
            let squares = standIn.missing.map(ownSquare)
            items.append(Item(tile: standIn.tile, originX: square.x, originY: square.y, side: square.side,
                              context: clipped(to: squares), standsIn: squares))
        }
        return items
    }

    /// The cached tiles below `id`, down to `depth` zooms: each child that
    /// is at hand, else its own descendants. Complete when they cover the
    /// whole of `id`'s square.
    private static func cachedDescendants(of id: TileID, depth: Int,
                                          lookup: (TileID) -> RenderTile?) -> (tiles: [RenderTile], isComplete: Bool) {
        guard depth > 0, id.zoom < TileID.maximumZoom else { return ([], false) }
        var tiles: [RenderTile] = []
        var isComplete = true
        for child in id.children {
            if let tile = lookup(child) {
                tiles.append(tile)
            } else {
                let deeper = cachedDescendants(of: child, depth: depth - 1, lookup: lookup)
                tiles += deeper.tiles
                isComplete = isComplete && deeper.isComplete
            }
        }
        return (tiles, isComplete)
    }

    // MARK: - Areas and lines

    /// Areas or lines, a role at a time across every tile, so a motorway
    /// in one tile crosses over a lane in its neighbour. Every area comes
    /// before every line in `MapRole.drawSequence`, so the two are drawn
    /// apart, and a layer — terrain — goes between.
    private func drawShapes(_ items: [Item], geometry: MapRole.Geometry, zoom: Double, projection: Projection,
                            theme: any Theme) {
        var cursors = Array(repeating: 0, count: items.count)
        for role in MapRole.drawSequence where role.geometry == geometry {
            let visible = role.isVisible(atZoom: zoom)
            let lineWidth = role.lineWidth(atZoom: zoom)
            let shading = GraphicsContext.Shading.color(role.colour(in: theme))
            for (index, item) in items.enumerated() {
                guard case .vector(let vector) = item.tile.content else { continue }
                while cursors[index] < vector.layers.count,
                      vector.layers[cursors[index]].role.drawOrder < role.drawOrder {
                    cursors[index] += 1
                }
                guard cursors[index] < vector.layers.count, vector.layers[cursors[index]].role == role else {
                    continue
                }
                let geometry = vector.layers[cursors[index]]
                guard visible else {
                    statistics.featuresCulled += geometry.features.count
                    continue
                }
                let path = self.path(of: geometry, in: item, projection: projection, margin: lineWidth + 1)
                guard !path.isEmpty else { continue }
                if role.geometry == .area {
                    item.context.fill(path, with: shading)
                } else {
                    item.context.stroke(path, with: shading, lineWidth: lineWidth)
                }
            }
        }
    }

    /// One path of every feature of `geometry` that reaches the viewport,
    /// in dots, each point within a dot of the one kept before it dropped.
    private func path(of geometry: RoleGeometry, in item: Item, projection: Projection, margin: Double) -> Path {
        var path = Path()
        let isArea = geometry.role.geometry == .area
        let minimumPoints = isArea ? Simplification.areaPoints : Simplification.linePoints
        let side = item.side, originX = item.originX, originY = item.originY
        let reach = projection.reach
        for feature in geometry.features {
            let left = originX + feature.minimumX * side, right = originX + feature.maximumX * side
            let top = originY + feature.minimumY * side, bottom = originY + feature.maximumY * side
            guard right >= reach.left - margin, left <= reach.right + margin,
                  bottom >= reach.top - margin, top <= reach.bottom + margin else {
                statistics.featuresCulled += 1
                continue
            }
            // An area smaller than a half cell either way covers no half
            // cell's centre, so the fill would draw nothing: not worth its
            // points.
            if isArea, right - left < Simplification.halfCell, bottom - top < Simplification.halfCell {
                statistics.featuresCulled += 1
                continue
            }
            statistics.featuresDrawn += 1
            // Rings are passed over north up, against the box the turn can
            // bring on screen; what is kept is cut, turned, to the screen —
            // or, pitched, cut to the ground the view shows, then projected.
            let viewport = projection.viewport
            let bounds = Clip(left: -margin, top: -margin, right: viewport.width + margin,
                              bottom: viewport.height + margin)
            let reachesOut = !projection.isAxisAligned
                || left < bounds.left || right > bounds.right || top < bounds.top || bottom > bounds.bottom
            for ring in feature.rings {
                let start = geometry.ringStart(ring), end = geometry.ringEnds[ring]
                guard end - start >= minimumPoints else { continue }
                if reachesOut {
                    let ringBounds = geometry.ringBounds[ring]
                    guard originX + ringBounds.maximumX * side >= reach.left - margin,
                          originX + ringBounds.minimumX * side <= reach.right + margin,
                          originY + ringBounds.maximumY * side >= reach.top - margin,
                          originY + ringBounds.minimumY * side <= reach.bottom + margin else { continue }
                }
                if let footprint = projection.footprint {
                    let northUp = (start..<end).map { index in
                        CanvasPoint(x: originX + geometry.xs[index] * side, y: originY + geometry.ys[index] * side)
                    }
                    if isArea {
                        let points = simplified(footprint.clipped(ring: northUp).compactMap(projection.screenPoint),
                                                keepingLast: false)
                        guard !points.isEmpty else { continue }
                        path.addLines(points)
                        path.closeSubpath()
                        statistics.verticesDrawn += points.count
                    } else {
                        for run in projection.screenRuns(of: northUp) {
                            let points = simplified(run, keepingLast: true)
                            guard points.count >= 2 else { continue }
                            path.addLines(points)
                            statistics.verticesDrawn += points.count
                        }
                    }
                    continue
                }
                var points: [CanvasPoint] = []
                points.reserveCapacity(end - start)
                var lastX = 0.0, lastY = 0.0
                for index in start..<end {
                    guard case let (x, y)? = projection.toScreen(x: originX + geometry.xs[index] * side,
                                                                 y: originY + geometry.ys[index] * side) else {
                        continue
                    }
                    let isLast = index == end - 1
                    if !points.isEmpty, abs(x - lastX) < Simplification.dot, abs(y - lastY) < Simplification.dot,
                       !(isLast && !isArea) {
                        statistics.verticesDropped += 1
                        continue
                    }
                    points.append(CanvasPoint(x: x, y: y))
                    lastX = x
                    lastY = y
                }
                if isArea {
                    // A ring simplified below three points has no area,
                    // and the scan passes it over.
                    if reachesOut { points = bounds.clipped(ring: points) }
                    guard let first = points.first else { continue }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                    statistics.verticesDrawn += points.count
                } else {
                    statistics.verticesDrawn += bounds.stroke(points, into: &path, clipping: reachesOut)
                }
            }
        }
        return path
    }

    /// Screen points with each one within a dot of the one kept before it
    /// dropped — the last of a line always kept, so it ends where it does.
    private func simplified(_ points: [CanvasPoint], keepingLast: Bool) -> [CanvasPoint] {
        var kept: [CanvasPoint] = []
        kept.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if let last = kept.last, abs(point.x - last.x) < Simplification.dot, abs(point.y - last.y) < Simplification.dot,
               !(keepingLast && index == points.count - 1) {
                statistics.verticesDropped += 1
                continue
            }
            kept.append(point)
        }
        return kept
    }

    /// The viewport and a margin around it, to which an area or a line is
    /// cut before the canvas sees it: close in, a z14 tile's blocks and
    /// streets run far past the screen, and every point off it would still
    /// be scanned.
    private struct Clip {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double

        /// Which sides of the rectangle a point lies beyond, a bit a side
        /// (Cohen and Sutherland's outcode).
        private func outcode(_ point: CanvasPoint) -> Int {
            (point.x < left ? 1 : 0) | (point.x > right ? 2 : 0) | (point.y < top ? 4 : 0) | (point.y > bottom ? 8 : 0)
        }

        private enum Edge: CaseIterable {
            case left, right, top, bottom
        }

        private func isInside(_ point: CanvasPoint, _ edge: Edge) -> Bool {
            switch edge {
            case .left: point.x >= left
            case .right: point.x <= right
            case .top: point.y >= top
            case .bottom: point.y <= bottom
            }
        }

        /// Where the segment from `start` to `end` crosses `edge`.
        private func crossing(_ start: CanvasPoint, _ end: CanvasPoint, _ edge: Edge) -> CanvasPoint {
            switch edge {
            case .left, .right:
                let x = edge == .left ? left : right
                return CanvasPoint(x: x, y: start.y + (end.y - start.y) * (x - start.x) / (end.x - start.x))
            case .top, .bottom:
                let y = edge == .top ? top : bottom
                return CanvasPoint(x: start.x + (end.x - start.x) * (y - start.y) / (end.y - start.y), y: y)
            }
        }

        /// A ring cut to the rectangle by Sutherland and Hodgman's
        /// re-entrant clipping ("Reentrant polygon clipping", CACM 17(1),
        /// 1974): one edge at a time, keeping what lies inside it. What it
        /// adds along the edges fills nothing beyond the rectangle.
        func clipped(ring: [CanvasPoint]) -> [CanvasPoint] {
            var points = ring
            for edge in Edge.allCases {
                guard var previous = points.last else { return [] }
                var kept: [CanvasPoint] = []
                kept.reserveCapacity(points.count + 1)
                for point in points {
                    let isIn = isInside(point, edge), wasIn = isInside(previous, edge)
                    if isIn {
                        if !wasIn { kept.append(crossing(previous, point, edge)) }
                        kept.append(point)
                    } else if wasIn {
                        kept.append(crossing(previous, point, edge))
                    }
                    previous = point
                }
                points = kept
            }
            return points
        }

        /// A line into `path`, the segments wholly beyond one side of the
        /// rectangle left out: the pen lifts over them. Returns the points
        /// drawn.
        func stroke(_ points: [CanvasPoint], into path: inout Path, clipping: Bool) -> Int {
            guard let first = points.first, points.count >= 2 else { return 0 }
            var drawn = 0
            var penDown = false
            var previous = first
            var previousCode = clipping ? outcode(first) : 0
            for point in points.dropFirst() {
                let code = clipping ? outcode(point) : 0
                if code & previousCode != 0 {
                    penDown = false
                } else {
                    if !penDown {
                        path.move(to: previous)
                        drawn += 1
                        penDown = true
                    }
                    path.addLine(to: point)
                    drawn += 1
                }
                previous = point
                previousCode = code
            }
            return drawn
        }
    }

    private enum Simplification {
        /// Points closer than this, in dots, draw the same dot.
        static let dot = 1.0
        static let areaPoints = 3
        static let linePoints = 2
        /// A half block's side, in dots: two across, two down.
        static let halfCell = Double(BrailleCell.dotColumns)
    }

    // MARK: - Pictures

    /// Raster tiles as half-block fills: a half cell is two dots by two, and
    /// takes the mean of the pixels it covers — a box filter, so a detailed
    /// photograph drawn at a few pixels a half cell reads as its colours
    /// rather than as the noise of whichever pixel lies under each centre —
    /// or, drawn larger than its pixels, the pixel under its centre.
    func drawRasters(_ items: [Item], viewport: DotSize) {
        let halfCell = Double(BrailleCell.dotColumns)
        let columns = Int(viewport.width / halfCell), rows = Int(viewport.height / halfCell)
        for item in items {
            guard case .raster(let raster) = item.tile.content else { continue }
            let image = raster.image
            guard image.width > 0, image.height > 0 else { continue }
            let centreOffset = halfCell / 2
            func range(origin: Double, limit: Int) -> Range<Int> {
                let first = max(0, Int(((origin - centreOffset) / halfCell).rounded(.up)))
                let last = min(limit, Int(((origin + item.side - centreOffset) / halfCell).rounded(.up)))
                return first..<max(first, last)
            }
            /// The pixels a half cell covers along one axis: those its span
            /// overlaps, or the one under its centre where it is smaller.
            func pixels(of index: Int, origin: Double, count: Int) -> Range<Int> {
                let scale = Double(count) / item.side
                let start = (Double(index) * halfCell - origin) * scale
                let end = start + halfCell * scale
                let centre = min(count - 1, max(0, Int((start + end) / 2)))
                let low = min(count - 1, max(0, Int(start.rounded()))), high = min(count, max(0, Int(end.rounded())))
                return low < high ? low..<high : centre..<(centre + 1)
            }
            let columnRange = range(origin: item.originX, limit: columns)
            let columnPixels = columnRange.map { pixels(of: $0, origin: item.originX, count: image.width) }
            for row in range(origin: item.originY, limit: rows) {
                let pixelRows = pixels(of: row, origin: item.originY, count: image.height)
                var runStart = columnRange.lowerBound
                var runColour: Color?
                func flush(until end: Int) {
                    if let runColour, end > runStart {
                        item.context.fill(CanvasRect(x: Double(runStart) * halfCell, y: Double(row) * halfCell,
                                                     width: Double(end - runStart) * halfCell, height: halfCell),
                                          with: .color(runColour))
                    }
                }
                for column in columnRange {
                    let colour = Self.quantised(Self.mean(of: image, columns: columnPixels[column - columnRange.lowerBound],
                                                          rows: pixelRows))
                    if colour != runColour {
                        flush(until: column)
                        runStart = column
                        runColour = colour
                    }
                }
                flush(until: columnRange.upperBound)
            }
        }
    }

    /// Picture tiles, north up or under a turned or pitched camera.
    func drawPictures(_ items: [Item], projection: Projection) {
        if !projection.isAxisAligned {
            drawTurnedRasters(items, projection: projection)
        } else {
            drawRasters(items, viewport: projection.viewport)
        }
    }

    /// The mean of a block of an image's pixels, channel by channel.
    private static func mean(of image: ImageBuffer, columns: Range<Int>,
                             rows: Range<Int>) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard columns.count > 1 || rows.count > 1 else { return image.pixel(at: columns.lowerBound, rows.lowerBound) }
        var red = 0, green = 0, blue = 0, alpha = 0
        for y in rows {
            for x in columns {
                let pixel = image.pixel(at: x, y)
                red += Int(pixel.r)
                green += Int(pixel.g)
                blue += Int(pixel.b)
                alpha += Int(pixel.a)
            }
        }
        let count = columns.count * rows.count
        return (UInt8(red / count), UInt8(green / count), UInt8(blue / count), UInt8(alpha / count))
    }

    /// Raster tiles under a turned or pitched camera: each half cell of
    /// the screen taken back to where it lies north up, and given the pixel of the
    /// tile there — a sample a half cell, as the north-up path takes.
    private func drawTurnedRasters(_ items: [Item], projection: Projection) {
        let halfCell = Double(BrailleCell.dotColumns)
        let columns = Int(projection.viewport.width / halfCell), rows = Int(projection.viewport.height / halfCell)
        for item in items {
            guard case .raster(let raster) = item.tile.content else { continue }
            let image = raster.image
            guard image.width > 0, image.height > 0 else { continue }
            for row in 0..<rows {
                var runStart = 0
                var runColour: Color?
                func flush(until end: Int) {
                    if let runColour, end > runStart {
                        item.context.fill(CanvasRect(x: Double(runStart) * halfCell, y: Double(row) * halfCell,
                                                     width: Double(end - runStart) * halfCell, height: halfCell),
                                          with: .color(runColour))
                    }
                }
                for column in 0..<columns {
                    let point = projection.toGround(x: (Double(column) + Self.halfCellMiddle) * halfCell,
                                                    y: (Double(row) + Self.halfCellMiddle) * halfCell)
                    let tileX = (point.x - item.originX) / item.side, tileY = (point.y - item.originY) / item.side
                    var colour: Color?
                    if (0..<1).contains(tileX), (0..<1).contains(tileY), item.covers(x: point.x, y: point.y) {
                        colour = Self.quantised(image.pixel(at: min(image.width - 1, Int(tileX * Double(image.width))),
                                                            min(image.height - 1, Int(tileY * Double(image.height)))))
                    }
                    if colour != runColour {
                        flush(until: column)
                        runStart = column
                        runColour = colour
                    }
                }
                flush(until: columns)
            }
        }
    }

    private static let halfCellMiddle = 0.5

    /// A pixel's colour with the low bits of each channel dropped, or nil
    /// where it is mostly transparent: neighbouring samples of a photo-like
    /// snapshot then share colours, so a row is a few long fills and the
    /// frame's palette stays small.
    private static func quantised(_ pixel: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Color? {
        guard pixel.a >= Quantisation.opaqueEnough else { return nil }
        func step(_ channel: UInt8) -> UInt8 { channel & Quantisation.keptBits | Quantisation.midpoint }
        return .rgb(step(pixel.r), step(pixel.g), step(pixel.b))
    }

    private enum Quantisation {
        /// The top five bits of a channel: 32 levels, past what a half
        /// block next to another can be told apart by.
        static let keptBits: UInt8 = 0xF8
        /// The middle of the eight values the dropped bits spanned.
        static let midpoint: UInt8 = 0x04
        /// Half of full alpha.
        static let opaqueEnough: UInt8 = 0x80
    }

    // MARK: - Content

    private func drawPolylines(_ content: [MapElement], camera: MapCamera, viewport: DotSize, projection: Projection,
                               dots: GraphicsContext, theme: any Theme) {
        for case .polyline(let polyline) in content.map(\.kind) where polyline.coordinates.count >= 2 {
            let runs = projection.screenRuns(of: polyline.coordinates.map { coordinate in
                let point = camera.northUpPoint(for: coordinate, in: viewport)
                return CanvasPoint(x: point.x, y: point.y)
            })
            if polyline.style == .connector {
                drawDashes(runs, dots: dots, theme: theme)
                continue
            }
            var path = Path()
            for run in runs {
                let points = simplified(run, keepingLast: true)
                if points.count >= 2 { path.addLines(points) }
            }
            let colour = switch polyline.style {
            case .route: theme.accent
            case .travelled: theme.accent.blended(with: theme.background, amount: Self.travelledFade)
            case .connector: theme.accent
            }
            dots.stroke(path, with: .color(colour), lineWidth: polyline.lineWidth)
        }
    }

    /// How far a travelled line's accent is mixed toward the ground: past
    /// half, so it reads as behind the route ahead, short of gone.
    private static let travelledFade = 0.6

    /// A connector's dashes and gaps, in dots: a cell's height each, so
    /// a gap is a whole blank cell whichever way the line runs — shorter,
    /// a line down the screen would put a dash in every cell and read as
    /// solid.
    private enum Dash {
        static let on = Double(BrailleCell.dotRows)
        static let off = Double(BrailleCell.dotRows)
    }

    /// A polyline as dashes along its screen path: `Dash.on` dots drawn,
    /// `Dash.off` left, the pattern carried across its bends.
    private func drawDashes(_ runs: [[CanvasPoint]], dots: GraphicsContext, theme: any Theme) {
        var path = Path()
        var drawing = true
        var left = Dash.on
        for (start, end) in runs.flatMap({ run in zip(run, run.dropFirst()) }) {
            let length = ((end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y)).squareRoot()
            guard length > 0 else { continue }
            var travelled = 0.0
            while travelled < length {
                let step = min(left, length - travelled)
                let from = travelled / length, to = (travelled + step) / length
                if drawing {
                    path.move(to: CanvasPoint(x: start.x + (end.x - start.x) * from, y: start.y + (end.y - start.y) * from))
                    path.addLine(to: CanvasPoint(x: start.x + (end.x - start.x) * to, y: start.y + (end.y - start.y) * to))
                }
                travelled += step
                left -= step
                if left <= 0 {
                    drawing.toggle()
                    left = drawing ? Dash.on : Dash.off
                }
            }
        }
        dots.stroke(path, with: .color(theme.accent), lineWidth: 0)
    }
}
