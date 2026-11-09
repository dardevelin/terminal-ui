import TerminalUI
import TerminalUIRaster

/// One recorded screen drawn into pixels, for a PNG still or a GIF frame.
///
/// It lays the screen out as ``SVGFrameRenderer`` does — the same cells,
/// padding, baseline and underline — and draws in this order:
///
/// 1. the canvas in the window's background, and each cell with a
///    background of its own;
/// 2. box drawing, block elements, braille and the framework's marks as
///    ``GlyphGeometry`` shapes, resolved through ``DeviceGlyph`` exactly as
///    the SVG's symbols are, so strokes land on the same pixels — drawn a
///    cell at a time, which for a run the SVG stretches one symbol across
///    (``DeviceGlyph/spansWidth``: every mark a full-width rect) covers
///    the same pixels;
/// 3. every other glyph from the first of `glyphs` that has it, on the
///    baseline, centred in the cells it takes — two for a wide glyph, whose
///    continuation draws nothing — and shrunk to fit if wider;
/// 4. underlines, a pixel-snapped rectangle under the cell.
///
/// Each layer blends over the one beneath in sRGB, `(fg·a + bg·(255 − a) +
/// 127) / 255`, all in integers, so a screen is the same pixels on every
/// system when its glyphs are. A glyph no source has is drawn as a hollow
/// box and reported in ``RasterFrame/missing``: what to do about it is the
/// caller's policy (``MissingGlyphPolicy``).
package final class RasterFrameComposer {
    package let metrics: CellMetrics
    package let palette: RecordingPalette
    /// Pixels at scale 1 between the cells and the picture's edge.
    package let padding: Int
    /// Where text comes from, best first: the configured font, then each
    /// fallback.
    package let glyphs: [any GlyphSource]
    /// A shape's coverage over its cell, built once per glyph.
    private var shapeMasks: [UInt32: [UInt8]] = [:]
    /// The hollow box a missing glyph is drawn as, by the cells it spans.
    private var missingMasks: [Int: [UInt8]] = [:]

    package init(metrics: CellMetrics, palette: RecordingPalette, padding: Int = SVGFrameRenderer.defaultPadding,
                 glyphs: [any GlyphSource]) {
        precondition(padding >= 0, "padding is not negative")
        self.metrics = metrics
        self.palette = palette
        self.padding = padding
        self.glyphs = glyphs
    }

    /// The SVG renderer's layout, kept for the last canvas size: an
    /// animation asks for the same one every frame.
    private var cachedLayout: (columns: Int, rows: Int, layout: SVGLayout)?

    private func layout(_ columns: Int, _ rows: Int) -> SVGLayout {
        if let cached = cachedLayout, cached.columns == columns, cached.rows == rows { return cached.layout }
        let layout = SVGLayout(metrics: metrics, padding: padding * metrics.scale, columns: columns, rows: rows)
        cachedLayout = (columns, rows, layout)
        return layout
    }

    /// The picture's size for a screen of `columns` × `rows` cells.
    package func size(columns: Int, rows: Int) -> (width: Int, height: Int) {
        let layout = layout(columns, rows)
        return (layout.width, layout.height)
    }

    /// `buffer` over `windowBackground`, on a canvas for at least
    /// `columns` × `rows` cells — the largest screen of an animation — the
    /// cells past the buffer's in the window's background.
    package func compose(_ buffer: CellBuffer, windowBackground: Color?, columns: Int = 0, rows: Int = 0) -> RasterFrame {
        let layout = layout(max(columns, buffer.width), max(rows, buffer.height))
        let ground = palette.defaultBackground(windowBackground: windowBackground).rgba
        var canvas = BlendCanvas(width: layout.width, height: layout.height, fill: ground)
        var missing: [Character] = []

        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                guard let colour = buffer[x, y].style.background.flatMap(palette.rgb)?.rgba, colour != ground else { continue }
                canvas.fill(x: layout.left(column: x), y: layout.top(row: y), width: layout.cellWidth,
                            height: layout.cellHeight, with: colour)
            }
        }
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let cell = buffer[x, y]
                guard !cell.isContinuation, let scalar = GlyphGeometry.shapeScalar(cell.character) else { continue }
                canvas.blend(palette.foreground(cell.style.foreground).rgba, mask: shapeMask(scalar, layout: layout),
                             maskWidth: layout.cellWidth, x: layout.left(column: x), y: layout.top(row: y))
            }
        }
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let cell = buffer[x, y]
                guard !cell.isContinuation, cell.character != " ",
                      GlyphGeometry.shapeScalar(cell.character) == nil else { continue }
                let cells = buffer[x + 1, y].isContinuation ? 2 : 1
                let colour = palette.foreground(cell.style.foreground).rgba
                if !drawText(cell, cells: cells, colour: colour, column: x, row: y, layout: layout, on: &canvas) {
                    if !missing.contains(cell.character) { missing.append(cell.character) }
                    canvas.blend(colour, mask: missingMask(cells: cells, layout: layout),
                                 maskWidth: cells * layout.cellWidth, x: layout.left(column: x), y: layout.top(row: y))
                }
            }
        }
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where buffer[x, y].style.underline {
                canvas.fill(x: layout.left(column: x), y: layout.underline(top: layout.top(row: y)), width: layout.cellWidth,
                            height: layout.underlineThickness,
                            with: palette.foreground(buffer[x, y].style.foreground).rgba)
            }
        }
        return RasterFrame(canvas: canvas, missing: missing)
    }

    // MARK: - Text

    /// The cell's glyph from the first source that has it; false if none.
    private func drawText(_ cell: Cell, cells: Int, colour: RGBA, column: Int, row: Int, layout: SVGLayout,
                          on canvas: inout BlendCanvas) -> Bool {
        let style: FontStyle = switch (cell.style.bold, cell.style.italic) {
        case (true, true): .boldItalic
        case (true, false): .bold
        case (false, true): .italic
        case (false, false): .regular
        }
        guard var glyph = glyphs.lazy.compactMap({ $0.glyph(cell.character, style: style) }).first else { return false }
        let span = cells * layout.cellWidth
        if glyph.advance > span { glyph = glyph.scaled(by: span, over: glyph.advance) }
        let left = layout.left(column: column) + max(span - glyph.advance, 0) / 2 + glyph.left
        let top = layout.baseline(top: layout.top(row: row)) + glyph.top
        switch glyph.pixels {
        case .coverage(let coverage):
            canvas.blend(colour, mask: coverage, maskWidth: glyph.width, x: left, y: top)
        case .premultipliedRGBA(let colours):
            for y in 0..<glyph.height {
                for x in 0..<glyph.width {
                    let offset = (y * glyph.width + x) * PixelCanvas.bytesPerPixel
                    canvas.composite(premultiplied: RGBA(colours[offset], colours[offset + 1], colours[offset + 2],
                                                         colours[offset + 3]), x: left + x, y: top + y)
                }
            }
        }
        return true
    }

    // MARK: - Shapes

    private func shapeMask(_ scalar: Unicode.Scalar, layout: SVGLayout) -> [UInt8] {
        if let mask = shapeMasks[scalar.value] { return mask }
        let mask = GlyphGeometry.shape(for: scalar).map {
            Self.mask(DeviceGlyph($0, cellWidth: layout.cellWidth, cellHeight: layout.cellHeight))
        } ?? [UInt8](repeating: 0, count: layout.cellWidth * layout.cellHeight)
        shapeMasks[scalar.value] = mask
        return mask
    }

    private func missingMask(cells: Int, layout: SVGLayout) -> [UInt8] {
        if let mask = missingMasks[cells] { return mask }
        let mask = Self.mask(DeviceGlyph(MissingGlyph.shape, cellWidth: cells * layout.cellWidth,
                                         cellHeight: layout.cellHeight))
        missingMasks[cells] = mask
        return mask
    }

    /// A shape's marks as one coverage mask the size of its cell, each
    /// mark's coverage at its opacity, marks over one another combined as
    /// the same colour drawn twice: `a + b·(255 − a) / 255`.
    static func mask(_ glyph: DeviceGlyph) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: glyph.width * glyph.height)
        func add(_ coverage: Int, x: Int, y: Int) {
            guard coverage > 0, x >= 0, x < glyph.width, y >= 0, y < glyph.height else { return }
            let index = y * glyph.width + x
            let beneath = Int(mask[index])
            mask[index] = UInt8(beneath + (coverage * (Coverage.full - beneath) + Coverage.full / 2) / Coverage.full)
        }
        for mark in glyph.marks {
            let opacity = mark.opacity.scaled(Coverage.full)
            if case .rect(let left, let top, let width, let height) = mark.figure {
                for y in top..<(top + height) {
                    for x in left..<(left + width) { add(opacity, x: x, y: y) }
                }
                continue
            }
            let bitmap = CoverageRasterizer.rasterize(FigureOutline.outline(mark.figure))
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    add((Int(bitmap[x, y]) * opacity + Coverage.full / 2) / Coverage.full,
                        x: bitmap.left + x, y: bitmap.top + y)
                }
            }
        }
        return mask
    }
}

/// A raster picture's file and what drawing it found.
package struct RasterPicture: Sendable {
    package var bytes: [UInt8]
    package var width: Int
    package var height: Int
    /// GIF frames written; 1 for a still.
    package var frames: Int
    package var missing: MissingGlyphs
    /// Things to tell whoever asked for the picture.
    package var warnings: [String]
}

extension RasterFrameComposer {
    /// One screen as a PNG: indexed when it shows at most 256 colours,
    /// which changes none of them, else RGB.
    package func still(_ screen: RecordingReader.Screen, frameNumber: Int) -> RasterPicture {
        let frame = compose(screen.buffer, windowBackground: screen.windowBackground)
        let canvas = frame.canvas.pixelCanvas
        let bytes = IndexedImage(exactly: canvas).map(PNGWriter.encode) ?? PNGWriter.encode(canvas, colourType: .rgb)
        var missing = MissingGlyphs()
        for character in frame.missing { missing.add(character, frame: frameNumber) }
        return RasterPicture(bytes: bytes, width: canvas.width, height: canvas.height, frames: 1,
                             missing: missing, warnings: [])
    }
}

/// A screen in pixels, and the characters no glyph source could draw.
package struct RasterFrame: Sendable {
    package var canvas: BlendCanvas
    /// In the order the screen first shows them.
    package var missing: [Character]
}

private enum Coverage {
    static let full = Int(UInt8.max)
}

/// What a glyph no font has is drawn as: a hollow box of light lines
/// inside its cells, as terminals draw "tofu".
private enum MissingGlyph {
    static let inset = 8
    static let shape: GlyphShape = {
        let near = CellCoordinate(cell: inset), far = CellCoordinate(cell: CellCoordinate.unitsPerCell - inset)
        let corners = [CellPoint(near, near), CellPoint(far, near), CellPoint(far, far), CellPoint(near, far)]
        return GlyphShape(corners.indices.map {
            GlyphPrimitive(.line(corners[$0], corners[($0 + 1) % corners.count], .light))
        })
    }()
}

/// ``DeviceGlyph``'s curved and slanted figures as outlines for
/// ``CoverageRasterizer``, in its 24.8 fixed point.
enum FigureOutline {
    /// 24.8 per sixteenth of a pixel.
    static let fixedPerSubpixel = CoverageRasterizer.one / SubpixelPoint.perPixel
    /// 16.16 fractions for a circle drawn as eight quadratic Béziers, each
    /// an eighth of the turn: the control point of the arc from 0° to 45°
    /// is (r, r·tan 22.5°), and its far end (r·cos 45°, r·sin 45°). The
    /// curve strays from the circle by under 0.03% of its radius.
    static let fractionOne = 1 << 16
    static let tangentOfAnEighthHalf = 27_146    // tan 22.5° = 0.414214
    static let cosineOfAnEighth = 46_341         // cos 45° = 0.707107

    static func outline(_ figure: DeviceGlyph.Figure) -> GlyphOutline {
        switch figure {
        case .rect(let x, let y, let width, let height):
            let (left, top) = (x * CoverageRasterizer.one, y * CoverageRasterizer.one)
            let (right, bottom) = ((x + width) * CoverageRasterizer.one, (y + height) * CoverageRasterizer.one)
            return GlyphOutline(contours: [[OutlinePoint(left, top), OutlinePoint(right, top),
                                            OutlinePoint(right, bottom), OutlinePoint(left, bottom)]])
        case .polygon(let points):
            return GlyphOutline(contours: [points.map { OutlinePoint($0.x * fixedPerSubpixel, $0.y * fixedPerSubpixel) }])
        case .circle(let centre, let radius):
            let quarters = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
            return GlyphOutline(contours: [quarters.flatMap { quarter in
                arc(centre: centre, radius: radius, horizontal: quarter.0, vertical: quarter.1,
                    fromHorizontal: quarter.0 == quarter.1)
                    .dropLast()
            }])
        case .quarterRing(let centre, let inner, let outer, let quarter):
            let outerArc = arc(centre: centre, radius: outer, horizontal: quarter.horizontal,
                               vertical: quarter.vertical, fromHorizontal: true)
            let innerArc = arc(centre: centre, radius: inner, horizontal: quarter.horizontal,
                               vertical: quarter.vertical, fromHorizontal: true).reversed()
            return GlyphOutline(contours: [outerArc + innerArc])
        }
    }

    /// The quarter of a circle in the quadrant whose offsets from `centre`
    /// have the signs of `horizontal` and `vertical`, as two quadratic
    /// Béziers: from the horizontal radius to the vertical one when
    /// `fromHorizontal`, else the other way, both ends on the curve.
    private static func arc(centre: SubpixelPoint, radius: Int, horizontal: Int, vertical: Int,
                            fromHorizontal: Bool) -> [OutlinePoint] {
        let r = radius * fixedPerSubpixel
        let (cx, cy) = (centre.x * fixedPerSubpixel, centre.y * fixedPerSubpixel)
        let tangent = roundedDivision(r * tangentOfAnEighthHalf, fractionOne)
        let diagonal = roundedDivision(r * cosineOfAnEighth, fractionOne)
        let points = [
            OutlinePoint(cx + horizontal * r, cy),
            OutlinePoint(cx + horizontal * r, cy + vertical * tangent, onCurve: false),
            OutlinePoint(cx + horizontal * diagonal, cy + vertical * diagonal),
            OutlinePoint(cx + horizontal * tangent, cy + vertical * r, onCurve: false),
            OutlinePoint(cx, cy + vertical * r),
        ]
        return fromHorizontal ? points : points.reversed()
    }
}

extension RGB {
    /// The colour, opaque, as the raster encoders hold it.
    package var rgba: RGBA { RGBA(red, green, blue) }
}
