/// How a path's inside is decided when it is filled or clipped to —
/// SwiftUI's `FillStyle`.
public struct FillStyle: Equatable, Sendable {
    /// Whether the even-odd rule decides: a point is inside when a ray
    /// from it crosses the outline an odd number of times. Otherwise the
    /// non-zero rule does, which takes a point the outline winds around at
    /// all — so a hole must run the other way to stay empty.
    public var isEOFilled: Bool

    /// The non-zero rule, or the even-odd one with `eoFill`.
    public init(eoFill: Bool = false) {
        self.isEOFilled = eoFill
    }
}

/// What a ``Canvas`` draws with: SwiftUI's `GraphicsContext`, over the
/// canvas's cells.
///
/// Coordinates are in cells from the canvas's top-left corner. The context
/// keeps three planes and composites them into cells when the renderer
/// returns:
///
/// - **Fills** land on half cells, two to a cell. A cell whose halves differ
///   and that nothing else covers draws `▀` in its two colours.
/// - **Strokes** land on braille dots, 2 × 4 to a cell, in one colour per
///   cell: a later stroke of another colour clears what an earlier one left
///   in the cells it reaches. ``resolution`` coarsens them to half cells or
///   whole cells, drawn into the fill plane.
/// - **Text** lands on whole cells over both, keeping the fill beneath it
///   as its background.
///
/// A context is a value: a copy keeps its own transform, clip and opacity,
/// and draws into the same canvas — the way to set some state for a few
/// drawing calls and have it gone after.
///
/// ```swift
/// Canvas { context, size in
///     context.fill(Path(CanvasRect(x: 0, y: 0, width: size.width, height: size.height)),
///                  with: .color(theme.backgroundRaised))
///     var inner = context
///     inner.translateBy(x: size.width / 2, y: size.height / 2)
///     inner.stroke(Path(ellipseIn: CanvasRect(x: -6, y: -3, width: 12, height: 6)),
///                  with: .color(theme.accent))
///     context.draw(Text("centre"), at: CanvasPoint(x: size.width / 2, y: size.height / 2))
/// }
/// ```
public struct GraphicsContext {
    /// A colour to stroke, fill or draw text with — SwiftUI's
    /// `GraphicsContext.Shading`.
    public struct Shading: Equatable, Sendable {
        let colour: Color

        /// A solid colour.
        public static func color(_ color: Color) -> Shading {
            Shading(colour: color)
        }
    }

    let raster: CanvasRaster
    var transform = CanvasTransform()
    var clipMask: CanvasClipMask?

    /// How opaque what the context draws next is, from `0` (nothing) to `1`.
    /// A translucent colour is mixed, in Oklab, toward what lies beneath it
    /// in the canvas — the fill under a fill, the cell's ground under a
    /// stroke or text. Over the terminal's own background, which no program
    /// can know, a colour at least half opaque draws as it is and a fainter
    /// one not at all.
    public var opacity: Double = 1

    /// What strokes are drawn at: braille dots unless the canvas, or a view
    /// around it, set otherwise with ``TerminalView/canvasResolution(_:)``.
    public var resolution: CanvasResolution

    /// The environment the canvas is drawn in — its theme among it.
    public let environment: EnvironmentValues

    init(raster: CanvasRaster, environment: EnvironmentValues) {
        self.raster = raster
        self.environment = environment
        self.resolution = environment.canvasResolution
    }

    private var clampedOpacity: Double { min(1, max(0, opacity)) }

    // MARK: - Transform

    /// Move the origin of what is drawn next by (`x`, `y`) cells, in the
    /// context's current coordinates.
    public mutating func translateBy(x: Double, y: Double) {
        transform.translateX += x * transform.scaleX
        transform.translateY += y * transform.scaleY
    }

    /// Scale what is drawn next by `x` across and `y` down, about the
    /// current origin. Text is placed by the scaled coordinates but keeps
    /// one cell per character.
    public mutating func scaleBy(x: Double, y: Double) {
        transform.scaleX *= x
        transform.scaleY *= y
    }

    // MARK: - Clip

    /// Limit what is drawn next to the inside of `path`, as `style` decides
    /// it, within whatever the context was already limited to. A dot, a half
    /// cell or a cell is drawn only where its centre is inside.
    public mutating func clip(to path: Path, style: FillStyle = FillStyle()) {
        let previous = clipMask
        func rasterise(_ resolution: CanvasResolution) -> [Bool] {
            let columns = raster.width * resolution.columnsPerCell
            let rows = raster.height * resolution.rowsPerCell
            var mask = Array(repeating: false, count: columns * rows)
            raster.flattened.load(path, transform: transform,
                                  columnsPerCell: resolution.columnsPerCell, rowsPerCell: resolution.rowsPerCell)
            let outer = previous?.mask(for: resolution)
            raster.scanFill(gridWidth: columns, gridHeight: rows, evenOdd: style.isEOFilled) { row, start, end in
                let base = row * columns
                for column in start..<end where outer?[base + column] ?? true {
                    mask[base + column] = true
                }
            }
            return mask
        }
        clipMask = CanvasClipMask(braille: rasterise(.braille),
                                  halfBlock: rasterise(.halfBlock),
                                  cell: rasterise(.cell))
    }

    // MARK: - Fill

    /// Fill the inside of `path`, as `style` decides it, in the fill plane:
    /// half cells, two to a cell, each taken when its centre is inside.
    ///
    /// ```swift
    /// var land = Path()
    /// land.addRect(CanvasRect(x: 2, y: 1, width: 20, height: 8))
    /// land.addEllipse(in: CanvasRect(x: 8, y: 3, width: 8, height: 4))  // a lake
    /// context.fill(land, with: .color(theme.success), style: FillStyle(eoFill: true))
    /// ```
    public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
        let opacity = clampedOpacity
        guard opacity > 0, raster.width > 0, raster.height > 0 else { return }
        raster.flattened.load(path, transform: transform, columnsPerCell: 1, rowsPerCell: CanvasGrid.halfBlockRows)
        let ink = raster.inkIndex(CanvasInk(colour: shading.colour, opacity: 1))
        let mask = clipMask?.halfBlock
        let raster = raster
        raster.scanFill(gridWidth: raster.width, gridHeight: raster.height * CanvasGrid.halfBlockRows,
                        evenOdd: style.isEOFilled) { row, start, end in
            raster.paintGround(row: row, start: start, end: end, ink: ink, opacity: opacity, mask: mask)
        }
    }

    /// Fill the half cells whose centres lie inside `rect` — what filling
    /// `Path(rect)` takes, without building and scanning a path. The way to
    /// paint thousands of small areas a frame: a picture's half-block
    /// samples, a heat map's cells.
    ///
    /// ```swift
    /// for (row, colours) in picture.enumerated() {
    ///     for (column, colour) in colours.enumerated() {
    ///         context.fill(CanvasRect(x: Double(column), y: Double(row) / 2, width: 1, height: 0.5),
    ///                      with: .color(colour))
    ///     }
    /// }
    /// ```
    public func fill(_ rect: CanvasRect, with shading: Shading) {
        let opacity = clampedOpacity
        guard opacity > 0, raster.width > 0, raster.height > 0 else { return }
        let corner = transform.applied(to: CanvasPoint(x: rect.x, y: rect.y))
        let opposite = transform.applied(to: CanvasPoint(x: rect.x + rect.width, y: rect.y + rect.height))
        let halfRows = Double(CanvasGrid.halfBlockRows)
        // The samples a path of the rect would take: those whose centre is
        // inside, the top and left edges included and the others not, as
        // `CanvasRaster.scanFill` counts them.
        func samples(from low: Double, to high: Double, limit: Int) -> Range<Int>? {
            guard low.isFinite, high.isFinite else { return nil }
            let bound = Double(limit)
            let start = min(max((min(low, high) - 0.5).rounded(.up), 0), bound)
            let end = min(max((max(low, high) - 0.5).rounded(.up), 0), bound)
            return start < end ? Int(start)..<Int(end) : nil
        }
        guard let columns = samples(from: corner.x, to: opposite.x, limit: raster.width),
              let rows = samples(from: corner.y * halfRows, to: opposite.y * halfRows,
                                 limit: raster.height * CanvasGrid.halfBlockRows) else { return }
        let ink = raster.inkIndex(CanvasInk(colour: shading.colour, opacity: 1))
        let mask = clipMask?.halfBlock
        for row in rows {
            raster.paintGround(row: row, start: columns.lowerBound, end: columns.upperBound,
                               ink: ink, opacity: opacity, mask: mask)
        }
    }

    // MARK: - Stroke

    /// Draw `path`'s outline at ``resolution``, `lineWidth` cells thick and
    /// never thinner than one dot — so the default, `0`, draws the finest
    /// line the resolution has, as Core Graphics draws a hairline.
    ///
    /// In braille each cell holds one colour, and a stroke takes the cells
    /// it passes through: dots an earlier stroke of another colour left
    /// there are cleared.
    public func stroke(_ path: Path, with shading: Shading, lineWidth: Double = 0) {
        let opacity = clampedOpacity
        guard opacity > 0, raster.width > 0, raster.height > 0 else { return }
        let resolution = resolution
        let columnsPerCell = resolution.columnsPerCell, rowsPerCell = resolution.rowsPerCell
        let gridWidth = raster.width * columnsPerCell, gridHeight = raster.height * rowsPerCell
        let width = lineWidth.isFinite ? max(0, lineWidth) : 0
        let brushWidth = max(1, Int((width * abs(transform.scaleX) * Double(columnsPerCell)).rounded()))
        let brushHeight = max(1, Int((width * abs(transform.scaleY) * Double(rowsPerCell)).rounded()))
        let reachX = brushWidth / 2, reachY = brushHeight / 2
        raster.flattened.load(path, transform: transform, columnsPerCell: columnsPerCell, rowsPerCell: rowsPerCell)

        let raster = raster
        let mask = clipMask?.mask(for: resolution)
        let isBraille = resolution == .braille
        // In braille the ink keeps its opacity, mixed when the cell's ground
        // is known; in the fill plane it is mixed as it lands, like a fill.
        let ink = raster.inkIndex(CanvasInk(colour: shading.colour, opacity: isBraille ? opacity : 1))
        let groundRepeat = resolution == .cell ? CanvasGrid.halfBlockRows : 1

        let isHairline = brushWidth == 1 && brushHeight == 1

        // Every sample the brush covers at each point of the stroke, within
        // the grid and the clip, handed to `paint`.
        func walk(_ paint: (_ column: Int, _ row: Int) -> Void) {
            func plot(_ x: Int, _ y: Int) {
                if isHairline {
                    guard x >= 0, x < gridWidth, y >= 0, y < gridHeight else { return }
                    if let mask, !mask[y * gridWidth + x] { return }
                    return paint(x, y)
                }
                for row in (y - (brushHeight - 1 - reachY))...(y + reachY) where row >= 0 && row < gridHeight {
                    for column in (x - (brushWidth - 1 - reachX))...(x + reachX)
                    where column >= 0 && column < gridWidth {
                        if let mask, !mask[row * gridWidth + column] { continue }
                        paint(column, row)
                    }
                }
            }
            // Segments are cut to the grid first, with room for the brush,
            // so a line that runs far off the canvas costs only what it draws.
            let margin = Double(max(brushWidth, brushHeight))
            let bounds = (minX: -margin, minY: -margin,
                          maxX: Double(gridWidth) + margin, maxY: Double(gridHeight) + margin)
            let flattened = raster.flattened
            var begin = 0
            for (subpath, end) in flattened.ends.enumerated() {
                defer { begin = end }
                guard end - begin >= 2 else { continue }
                let segmentCount = flattened.closed[subpath] ? end - begin : end - begin - 1
                for offset in 0..<segmentCount {
                    let from = begin + offset
                    let to = from + 1 == end ? begin : from + 1
                    guard let segment = Self.clip(fromX: flattened.xs[from], fromY: flattened.ys[from],
                                                  toX: flattened.xs[to], toY: flattened.ys[to], to: bounds)
                    else { continue }
                    Self.bresenham(fromX: Int(segment.fromX.rounded(.down)),
                                   fromY: Int(segment.fromY.rounded(.down)),
                                   toX: Int(segment.toX.rounded(.down)),
                                   toY: Int(segment.toY.rounded(.down)),
                                   plot: plot)
                }
            }
        }

        if isBraille {
            raster.withDots(ink: ink) { setDot in walk(setDot) }
        } else {
            // An opaque stroke may paint a sample twice to the same end; a
            // translucent one would mix it twice, so it marks what it reached.
            let marksSamples = opacity < 1
            if marksSamples { raster.beginStrokeMarks(count: gridWidth * gridHeight) }
            walk { column, row in
                if marksSamples, !raster.marksStroke(row * gridWidth + column) { return }
                for half in 0..<groundRepeat {
                    raster.paintGround(row: row * groundRepeat + half, start: column, end: column + 1,
                                       ink: ink, opacity: opacity, mask: nil)
                }
            }
        }
    }

    /// The part of a segment inside `bounds` (Liang & Barsky, "A New
    /// Concept and Method for Line Clipping", ACM TOG 3(1), 1984), or nil
    /// when none of it is, or it is not a finite segment.
    static func clip(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     to bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double))
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        guard fromX.isFinite, fromY.isFinite, toX.isFinite, toY.isFinite else { return nil }
        let deltaX = toX - fromX, deltaY = toY - fromY
        var entry = 0.0, exit = 1.0
        // One edge of the bounds: false when the segment lies wholly outside it.
        func admit(_ direction: Double, _ distance: Double) -> Bool {
            if direction == 0 { return distance >= 0 }
            let ratio = distance / direction
            if direction < 0 {
                if ratio > exit { return false }
                entry = max(entry, ratio)
            } else {
                if ratio < entry { return false }
                exit = min(exit, ratio)
            }
            return true
        }
        guard admit(-deltaX, fromX - bounds.minX), admit(deltaX, bounds.maxX - fromX),
              admit(-deltaY, fromY - bounds.minY), admit(deltaY, bounds.maxY - fromY) else { return nil }
        return (fromX + entry * deltaX, fromY + entry * deltaY, fromX + exit * deltaX, fromY + exit * deltaY)
    }

    /// Every grid point of the line between two, ends included (Bresenham,
    /// "Algorithm for computer control of a digital plotter", IBM Systems
    /// Journal 4(1), 1965), in its all-octant integer form.
    @inline(__always)
    static func bresenham(fromX: Int, fromY: Int, toX: Int, toY: Int, plot: (Int, Int) -> Void) {
        var x = fromX, y = fromY
        let deltaX = abs(toX - fromX), deltaY = -abs(toY - fromY)
        let stepX = fromX < toX ? 1 : -1, stepY = fromY < toY ? 1 : -1
        var error = deltaX + deltaY
        while true {
            plot(x, y)
            if x == toX && y == toY { return }
            let doubled = 2 * error
            if doubled >= deltaY {
                error += deltaY
                x += stepX
            }
            if doubled <= deltaX {
                error += deltaX
                y += stepY
            }
        }
    }

    // MARK: - Text

    /// Draw `text` with its `anchor` at `point`, on whole cells over fills and
    /// strokes. Each run keeps its own style; what it leaves unstated it
    /// takes from the canvas, and a background it does not state is the fill
    /// beneath it. A newline starts the next row.
    ///
    /// The text's box snaps to the nearest cell corner, so a label centred
    /// on a point stays as near it as cells allow.
    ///
    /// ```swift
    /// context.draw(Text("Lisboa".fg(theme.foreground).bolded()),
    ///              at: CanvasPoint(x: 12.5, y: 6), anchor: .bottom)
    /// ```
    public func draw(_ text: Text, at point: CanvasPoint, anchor: UnitPoint = .center) {
        draw(spans: text.spans, at: point, anchor: anchor)
    }

    /// Draw `string` with its `anchor` at `point`, in `shading` or the
    /// canvas's own foreground, placed as a ``Text`` is.
    public func draw(_ string: String, at point: CanvasPoint, anchor: UnitPoint = .center,
                     with shading: Shading? = nil) {
        draw(spans: [TextSpan(string, foreground: shading?.colour)], at: point, anchor: anchor)
    }

    private func draw(spans: [TextSpan], at point: CanvasPoint, anchor: UnitPoint) {
        let opacity = clampedOpacity
        guard opacity > 0, raster.width > 0, raster.height > 0 else { return }
        let placed = transform.applied(to: point)
        guard placed.x.isFinite, placed.y.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return }

        var lineCount = 1, widest = 0, lineWidth = 0
        for span in spans {
            for character in span.text {
                if character == "\n" || character == "\r\n" {
                    lineCount += 1
                    widest = max(widest, lineWidth)
                    lineWidth = 0
                } else if !character.isTerminalControl {
                    lineWidth += character.displayWidth
                }
            }
        }
        widest = max(widest, lineWidth)

        let left = (placed.x - anchor.x * Double(widest) + 0.5).rounded(.down)
        let top = (placed.y - anchor.y * Double(lineCount) + 0.5).rounded(.down)
        let width = raster.width, height = raster.height
        guard left < Double(width), top < Double(height),
              left + Double(widest) > 0, top + Double(lineCount) > 0 else { return }
        let mask = clipMask?.cell
        func admits(_ column: Int, _ row: Int) -> Bool {
            column >= 0 && column < width && row >= 0 && row < height
                && (mask?[row * width + column] ?? true)
        }

        var column = Int(left), row = Int(top)
        for span in spans {
            for character in span.text {
                if character == "\n" || character == "\r\n" {
                    row += 1
                    column = Int(left)
                    continue
                }
                if character.isTerminalControl { continue }
                let columns = character.displayWidth
                guard columns > 0 else { continue }
                defer { column += columns }
                guard admits(column, row) else { continue }
                if columns == CanvasGrid.wideGlyphColumns, !admits(column + 1, row) { continue }
                raster.placeGlyph(CanvasGlyph(
                    character: character, foreground: span.foreground, background: span.background,
                    bold: span.bold, italic: span.italic, underline: span.underline,
                    opacity: opacity, isContinuation: false),
                    x: column, y: row, columns: columns)
            }
        }
    }
}
