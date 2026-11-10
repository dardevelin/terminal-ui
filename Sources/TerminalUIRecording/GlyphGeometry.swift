/// A position along one axis of a cell, as the sum of three lengths, so a
/// shape keeps its look whatever the cell's proportions and size:
///
/// - ``cell``: forty-eighths of the cell's own extent on this axis — where
///   a line runs, which must be the same fraction of every cell so it meets
///   the next cell's line;
/// - ``width``: forty-eighths of the cell's *width*, on either axis — what
///   must be as long across as down, a dot's radius or a triangle's sides,
///   which the cell's height would stretch;
/// - ``strokes``: whole light strokes — the gap between the two lines of a
///   double line, which follows the stroke and not the cell.
///
/// Forty-eight divides into the halves, thirds, quarters and eighths the
/// Unicode charts draw on, so every coordinate is an integer.
package struct CellCoordinate: Hashable, Sendable {
    /// The grid ``cell`` and ``width`` count on.
    package static let unitsPerCell = 48

    package var cell: Int
    package var width: Int
    package var strokes: Int

    package init(cell: Int = 0, width: Int = 0, strokes: Int = 0) {
        self.cell = cell
        self.width = width
        self.strokes = strokes
    }

    /// The cell's near edge: its left, or its top.
    package static let start = CellCoordinate(cell: 0)
    /// The middle of the cell, where its box-drawing lines run.
    package static let middle = CellCoordinate(cell: unitsPerCell / 2)
    /// The cell's far edge: its right, or its bottom.
    package static let end = CellCoordinate(cell: unitsPerCell)

    /// Whether this is the cell's edge itself, where a line is cut flat so
    /// it meets the next cell's.
    package var isEdge: Bool {
        width == 0 && strokes == 0 && (cell == 0 || cell == Self.unitsPerCell)
    }

    package func offset(strokes count: Int) -> CellCoordinate {
        CellCoordinate(cell: cell, width: width, strokes: strokes + count)
    }

    package func offset(width count: Int) -> CellCoordinate {
        CellCoordinate(cell: cell, width: width + count, strokes: strokes)
    }
}

package struct CellPoint: Hashable, Sendable {
    package var x: CellCoordinate
    package var y: CellCoordinate

    package init(_ x: CellCoordinate, _ y: CellCoordinate) {
        self.x = x
        self.y = y
    }

    /// A point `dx`, `dy` forty-eighths of the cell's width from its
    /// centre: a shape drawn with these is the same shape in a cell of any
    /// proportions.
    package static func fromCentre(_ dx: Int, _ dy: Int) -> CellPoint {
        CellPoint(CellCoordinate.middle.offset(width: dx), CellCoordinate.middle.offset(width: dy))
    }
}

/// How heavy a line is drawn. A double line is two light ones, laid out by
/// the glyph's geometry, since where each ends depends on the lines it meets.
package enum StrokeWeight: Hashable, Sendable {
    case light
    case heavy
}

/// The quarter of the cell a rounded corner's arms reach into.
package struct CornerOpening: Hashable, Sendable {
    /// +1 when the horizontal arm runs to the right edge, −1 to the left.
    package var horizontal: Int
    /// +1 when the vertical arm runs to the bottom edge, −1 to the top.
    package var vertical: Int

    package static let downRight = CornerOpening(horizontal: 1, vertical: 1)
    package static let downLeft = CornerOpening(horizontal: -1, vertical: 1)
    package static let upLeft = CornerOpening(horizontal: -1, vertical: -1)
    package static let upRight = CornerOpening(horizontal: 1, vertical: -1)
}

/// One mark a glyph is made of, in cell coordinates, and how opaque it is.
package struct GlyphPrimitive: Hashable, Sendable {
    package enum Figure: Hashable, Sendable {
        /// A filled rectangle between two opposite corners.
        case rect(CellPoint, CellPoint)
        /// A straight stroke along its centre line. An end inside the cell
        /// is capped square, half the stroke past the point, so arms that
        /// meet there join without a notch; an end on the cell's edge is
        /// cut flat there, so it meets the next cell's line exactly.
        case line(CellPoint, CellPoint, StrokeWeight)
        /// One dash of a dashed line (U+2504–250B, U+254C–254F): a stroke
        /// cut flat at both ends, so the gaps between dashes stay open.
        case dash(CellPoint, CellPoint, StrokeWeight)
        /// A rounded corner (U+256D–2570): a quarter circle tangent to the
        /// vertical line through `centre.x` and the horizontal one through
        /// `centre.y`, its radius the distance from that vertical line to
        /// the side edge the corner opens toward, so the arc meets that
        /// edge level with the next cell's line; then the vertical line on
        /// from the arc to the top or bottom edge.
        case roundedCorner(centre: CellPoint, opening: CornerOpening, StrokeWeight)
        /// A filled disc; its radius counts ``CellCoordinate/width``.
        case circle(centre: CellPoint, radius: CellCoordinate)
        /// A filled polygon, its vertices in order.
        case polygon([CellPoint])
    }

    package var figure: Figure
    package var opacity: Proportion

    package static let opaque = Proportion(1, 1)

    package init(_ figure: Figure, opacity: Proportion = opaque) {
        self.figure = figure
        self.opacity = opacity
    }
}

/// A glyph as primitives: what a picture draws in place of a font's glyph.
package struct GlyphShape: Hashable, Sendable {
    package var primitives: [GlyphPrimitive]

    package init(_ primitives: [GlyphPrimitive]) {
        self.primitives = primitives
    }
}

/// The glyphs a picture of a recording draws as shapes rather than text, on
/// every engine and in every format: box drawing (U+2500–257F), block
/// elements (U+2580–259F), braille (U+2800–28FF) and the chrome the
/// framework draws — its disclosure and scroll triangles, radio dot, prompt
/// chevron and check boxes — and the glyphs a map marks its points of
/// interest with.
///
/// A font draws these at its own size and weight, and where it lacks them a
/// fallback font does, at another: borders gap between rows, block art
/// shows seams, braille dots wander. Drawn from geometry, a border's lines
/// reach the cell's edges and join the next cell's, whatever font the text
/// is in.
///
/// The geometry knows nothing of pixels or formats: the SVG renderer and
/// the raster one resolve it through ``DeviceGlyph``.
package enum GlyphGeometry {
    package static let boxDrawing: ClosedRange<UInt32> = 0x2500...0x257F
    package static let blockElements: ClosedRange<UInt32> = 0x2580...0x259F
    package static let braille: ClosedRange<UInt32> = 0x2800...0x28FF

    /// The shape drawn for a cell holding `character`, or nil for a glyph
    /// left to the font.
    package static func shape(for character: Character) -> GlyphShape? {
        shapeScalar(character).flatMap(shape(for:))
    }

    /// The scalar a cell holding `character` is drawn as a shape for, or
    /// nil for a glyph left to the font, without building the shape. A
    /// cluster of several scalars is the font's: a combining mark changes
    /// what its base looks like.
    package static func shapeScalar(_ character: Character) -> Unicode.Scalar? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        let value = scalar.value
        let drawn = boxDrawing.contains(value) || blockElements.contains(value) || braille.contains(value)
            || Chrome.shapes[value] != nil
        return drawn ? scalar : nil
    }

    package static func shape(for scalar: Unicode.Scalar) -> GlyphShape? {
        let value = scalar.value
        if boxDrawing.contains(value) { return BoxDrawing.shape(value) }
        if blockElements.contains(value) { return BlockElements.shape(value) }
        if braille.contains(value) { return Braille.shape(UInt8(value - braille.lowerBound)) }
        return Chrome.shape(value)
    }

    /// Every code point drawn as a shape outside the three blocks.
    package static var chrome: [UInt32] { Chrome.codePoints }
}

// MARK: - Box drawing

/// The Unicode Box Drawing block, U+2500–257F
/// (https://www.unicode.org/charts/PDF/U2500.pdf). Most of it is lines from
/// the cell's centre to the middle of its edges — its arms — each light,
/// heavy or double; the rest is dashed lines, rounded corners and
/// diagonals.
private enum BoxDrawing {
    enum Weight: Character {
        case none = "."
        case light = "l"
        case heavy = "h"
        case double = "d"

        var stroke: StrokeWeight? {
            switch self {
            case .light: return .light
            case .heavy: return .heavy
            case .none, .double: return nil
            }
        }
    }

    /// Up, right, down, left.
    struct Arms {
        var up: Weight, right: Weight, down: Weight, left: Weight

        init(_ spelling: String) {
            let weights = spelling.map { Weight(rawValue: $0) ?? .none }
            (up, right, down, left) = (weights[0], weights[1], weights[2], weights[3])
        }
    }

    /// Each code point's arms, up right down left, as the chart's names
    /// give them ("DOWN LIGHT AND RIGHT HEAVY" is `.hl.`); nil for the
    /// dashes, arcs and diagonals, drawn below. `GlyphGeometryTests` checks
    /// the lines each glyph draws at its edges against its name.
    static let arms: [String?] = [
        ".l.l", ".h.h", "l.l.", "h.h.", nil, nil, nil, nil,          // ─ ━ │ ┃ ┄ ┅ ┆ ┇
        nil, nil, nil, nil, ".ll.", ".hl.", ".lh.", ".hh.",          // ┈ ┉ ┊ ┋ ┌ ┍ ┎ ┏
        "..ll", "..lh", "..hl", "..hh", "ll..", "lh..", "hl..", "hh..", // ┐ ┑ ┒ ┓ └ ┕ ┖ ┗
        "l..l", "l..h", "h..l", "h..h", "lll.", "lhl.", "hll.", "llh.", // ┘ ┙ ┚ ┛ ├ ┝ ┞ ┟
        "hlh.", "hhl.", "lhh.", "hhh.", "l.ll", "l.lh", "h.ll", "l.hl", // ┠ ┡ ┢ ┣ ┤ ┥ ┦ ┧
        "h.hl", "h.lh", "l.hh", "h.hh", ".lll", ".llh", ".hll", ".hlh", // ┨ ┩ ┪ ┫ ┬ ┭ ┮ ┯
        ".lhl", ".lhh", ".hhl", ".hhh", "ll.l", "ll.h", "lh.l", "lh.h", // ┰ ┱ ┲ ┳ ┴ ┵ ┶ ┷
        "hl.l", "hl.h", "hh.l", "hh.h", "llll", "lllh", "lhll", "lhlh", // ┸ ┹ ┺ ┻ ┼ ┽ ┾ ┿
        "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh", // ╀ ╁ ╂ ╃ ╄ ╅ ╆ ╇
        "lhhh", "hlhh", "hhhl", "hhhh", nil, nil, nil, nil,          // ╈ ╉ ╊ ╋ ╌ ╍ ╎ ╏
        ".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd", // ═ ║ ╒ ╓ ╔ ╕ ╖ ╗
        "ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.", // ╘ ╙ ╚ ╛ ╜ ╝ ╞ ╟
        "ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d", // ╠ ╡ ╢ ╣ ╤ ╥ ╦ ╧
        "dl.l", "dd.d", "ldld", "dldl", "dddd", nil, nil, nil,       // ╨ ╩ ╪ ╫ ╬ ╭ ╮ ╯
        nil, nil, nil, nil, "...l", "l...", ".l..", "..l.",          // ╰ ╱ ╲ ╳ ╴ ╵ ╶ ╷
        "...h", "h...", ".h..", "..h.", ".h.l", "l.h.", ".l.h", "h.l.", // ╸ ╹ ╺ ╻ ╼ ╽ ╾ ╿
    ]

    /// A dashed line: its weight, whether it runs down the cell, and how
    /// many dashes it breaks into.
    struct Dash {
        var weight: StrokeWeight
        var vertical: Bool
        var count: Int
    }

    static let dashes: [UInt32: Dash] = [
        0x2504: Dash(weight: .light, vertical: false, count: 3), 0x2505: Dash(weight: .heavy, vertical: false, count: 3),
        0x2506: Dash(weight: .light, vertical: true, count: 3), 0x2507: Dash(weight: .heavy, vertical: true, count: 3),
        0x2508: Dash(weight: .light, vertical: false, count: 4), 0x2509: Dash(weight: .heavy, vertical: false, count: 4),
        0x250A: Dash(weight: .light, vertical: true, count: 4), 0x250B: Dash(weight: .heavy, vertical: true, count: 4),
        0x254C: Dash(weight: .light, vertical: false, count: 2), 0x254D: Dash(weight: .heavy, vertical: false, count: 2),
        0x254E: Dash(weight: .light, vertical: true, count: 2), 0x254F: Dash(weight: .heavy, vertical: true, count: 2),
    ]

    static let corners: [UInt32: CornerOpening] = [
        0x256D: .downRight, 0x256E: .downLeft, 0x256F: .upLeft, 0x2570: .upRight,
    ]

    enum Diagonal {
        static let upperRightToLowerLeft: UInt32 = 0x2571
        static let upperLeftToLowerRight: UInt32 = 0x2572
        static let cross: UInt32 = 0x2573
    }

    /// The share of each dash's period left as a gap, half of it on each
    /// side, so the gap where two cells meet is the gap inside one: a
    /// period of 48/n units, the dash `period − gap` of them.
    static let dashGapPerPeriod = Proportion(3, 8)

    static func shape(_ value: UInt32) -> GlyphShape {
        if let dash = dashes[value] { return GlyphShape(dashed(dash)) }
        if let opening = corners[value] {
            let centre = CellPoint(.middle, .middle)
            return GlyphShape([GlyphPrimitive(.roundedCorner(centre: centre, opening: opening, .light))])
        }
        let topLeft = CellPoint(.start, .start), topRight = CellPoint(.end, .start)
        let bottomLeft = CellPoint(.start, .end), bottomRight = CellPoint(.end, .end)
        switch value {
        case Diagonal.upperRightToLowerLeft:
            return GlyphShape([GlyphPrimitive(.line(topRight, bottomLeft, .light))])
        case Diagonal.upperLeftToLowerRight:
            return GlyphShape([GlyphPrimitive(.line(topLeft, bottomRight, .light))])
        case Diagonal.cross:
            return GlyphShape([GlyphPrimitive(.line(topRight, bottomLeft, .light)),
                               GlyphPrimitive(.line(topLeft, bottomRight, .light))])
        default:
            let spelling = arms[Int(value - GlyphGeometry.boxDrawing.lowerBound)] ?? "...."
            return GlyphShape(lines(Arms(spelling)).map { GlyphPrimitive($0) })
        }
    }

    static func dashed(_ dash: Dash) -> [GlyphPrimitive] {
        let period = CellCoordinate.unitsPerCell / dash.count
        let gap = dashGapPerPeriod.scaled(period)
        return (0..<dash.count).map { index in
            let from = CellCoordinate(cell: index * period + gap / 2)
            let to = CellCoordinate(cell: (index + 1) * period - (gap - gap / 2))
            let line: GlyphPrimitive.Figure = dash.vertical
                ? .dash(CellPoint(.middle, from), CellPoint(.middle, to), dash.weight)
                : .dash(CellPoint(from, .middle), CellPoint(to, .middle), dash.weight)
            return GlyphPrimitive(line)
        }
    }

    /// Lines for a glyph's arms. Light and heavy arms run from the centre
    /// to their edge, an arm and its opposite of one weight as one line. A
    /// double arm is two light lines a stroke either side of the centre
    /// line, each running in to where the lines across it begin.
    static func lines(_ arms: Arms) -> [GlyphPrimitive.Figure] {
        var figures: [GlyphPrimitive.Figure] = []
        figures += axis(arms.left, arms.right, across: (arms.up, arms.down), horizontal: true)
        figures += axis(arms.up, arms.down, across: (arms.left, arms.right), horizontal: false)
        return figures
    }

    /// One axis's arms: `near` toward the start edge (left or top), `far`
    /// toward the end; `across` the arms perpendicular to it, start side
    /// first.
    static func axis(_ near: Weight, _ far: Weight, across: (Weight, Weight),
                     horizontal: Bool) -> [GlyphPrimitive.Figure] {
        func line(_ from: CellCoordinate, _ to: CellCoordinate, at position: CellCoordinate,
                  _ weight: StrokeWeight) -> GlyphPrimitive.Figure {
            horizontal ? .line(CellPoint(from, position), CellPoint(to, position), weight)
                       : .line(CellPoint(position, from), CellPoint(position, to), weight)
        }
        let acrossIsDouble = across.0 == .double || across.1 == .double
        var figures: [GlyphPrimitive.Figure] = []
        if near.stroke != nil || far.stroke != nil {
            if near == far, let weight = near.stroke {
                figures.append(line(.start, .end, at: .middle, weight))
            } else {
                // A single arm stops at the near line of a double one
                // across it (╟, ╤) rather than crossing into its gap.
                let stop = acrossIsDouble ? 1 : 0
                if let weight = near.stroke {
                    figures.append(line(.start, CellCoordinate.middle.offset(strokes: -stop), at: .middle, weight))
                }
                if let weight = far.stroke {
                    figures.append(line(CellCoordinate.middle.offset(strokes: stop), .end, at: .middle, weight))
                }
            }
        }
        // Each double arm's two lines, the one on the start side of the
        // centre line first. A line ends at the near line of an arm across
        // it on its side — that arm's double line, or its single one — or,
        // with no arm there, runs on to the far line, closing the corner.
        for (arm, edge, sign) in [(near, CellCoordinate.start, -1), (far, CellCoordinate.end, 1)] where arm == .double {
            for (side, crossing) in [(-1, across.0), (1, across.1)] {
                let inner: CellCoordinate
                switch crossing {
                case .double: inner = CellCoordinate.middle.offset(strokes: sign)
                case .light, .heavy: inner = .middle
                case .none: inner = CellCoordinate.middle.offset(strokes: -sign)
                }
                figures.append(line(edge, inner, at: CellCoordinate.middle.offset(strokes: side), .light))
            }
        }
        return figures
    }
}

// MARK: - Block elements

/// The Unicode Block Elements block, U+2580–259F
/// (https://www.unicode.org/charts/PDF/U2580.pdf): eighths of the cell
/// filled from an edge, quadrants, and three shades.
private enum BlockElements {
    static let eighths = CellCoordinate.unitsPerCell / 8
    static let half = CellCoordinate.unitsPerCell / 2

    static func rect(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int,
                     opacity: Proportion = GlyphPrimitive.opaque) -> GlyphPrimitive {
        GlyphPrimitive(.rect(CellPoint(CellCoordinate(cell: left), CellCoordinate(cell: top)),
                             CellPoint(CellCoordinate(cell: right), CellCoordinate(cell: bottom))),
                       opacity: opacity)
    }

    /// The quadrants' bits, top-left, top-right, bottom-left, bottom-right
    /// from the low bit up (the framework's `QuadrantMask`), for U+2596–259F
    /// in chart order.
    static let quadrants: [UInt8] = [0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110]

    /// ░ ▒ ▓: a quarter, half and three quarters of the foreground over
    /// the background, as a terminal's shade glyphs approximate.
    static let shades: [UInt32: Proportion] = [0x2591: Proportion(1, 4), 0x2592: Proportion(1, 2), 0x2593: Proportion(3, 4)]

    static let upperHalf: UInt32 = 0x2580
    static let lowerEighths: ClosedRange<UInt32> = 0x2581...0x2588
    static let leftEighths: ClosedRange<UInt32> = 0x2589...0x258F
    static let rightHalf: UInt32 = 0x2590
    static let upperEighth: UInt32 = 0x2594
    static let rightEighth: UInt32 = 0x2595
    static let quadrantRange: ClosedRange<UInt32> = 0x2596...0x259F

    static func shape(_ value: UInt32) -> GlyphShape {
        let full = CellCoordinate.unitsPerCell
        switch value {
        case upperHalf:
            return GlyphShape([rect(0, 0, full, half)])
        case lowerEighths:
            // U+2581 is one eighth from the bottom, U+2588 the full block.
            let filled = Int(value - lowerEighths.lowerBound + 1) * eighths
            return GlyphShape([rect(0, full - filled, full, full)])
        case leftEighths:
            // U+2589 is seven eighths from the left, U+258F one.
            let filled = Int(leftEighths.upperBound - value + 1) * eighths
            return GlyphShape([rect(0, 0, filled, full)])
        case rightHalf:
            return GlyphShape([rect(half, 0, full, full)])
        case upperEighth:
            return GlyphShape([rect(0, 0, full, eighths)])
        case rightEighth:
            return GlyphShape([rect(full - eighths, 0, full, full)])
        case quadrantRange:
            return quadrantShape(quadrants[Int(value - quadrantRange.lowerBound)])
        default:
            return GlyphShape([rect(0, 0, full, full, opacity: shades[value] ?? GlyphPrimitive.opaque)])
        }
    }

    static func quadrantShape(_ bits: UInt8) -> GlyphShape {
        let corners = [(0, 0), (half, 0), (0, half), (half, half)]
        return GlyphShape(corners.enumerated().compactMap { bit, corner in
            bits & (1 << bit) == 0 ? nil : rect(corner.0, corner.1, corner.0 + half, corner.1 + half)
        })
    }
}

// MARK: - Braille

/// The Unicode Braille Patterns block, U+2800–28FF
/// (https://www.unicode.org/charts/PDF/U2800.pdf): a pattern's offset from
/// U+2800 is its dots as bits, dot 1 the lowest. Dots 1–3 run down the left
/// column and 4–6 down the right, and the 8-dot extension adds 7 and 8
/// beneath them, left then right.
private enum Braille {
    /// Each bit's column and row, dot 1 first.
    static let dots: [(column: Int, row: Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
    static let columns = 2
    static let rows = 4
    /// A dot's radius: a third of the gap between dot centres in a cell of
    /// a monospaced font's proportions, so neighbours never touch.
    static let radius = CellCoordinate(width: 8)

    static func shape(_ pattern: UInt8) -> GlyphShape {
        let unit = CellCoordinate.unitsPerCell
        return GlyphShape(dots.enumerated().compactMap { bit, dot in
            guard pattern & (1 << bit) != 0 else { return nil }
            // Each dot centred in its share of the cell: its column's half,
            // its row's quarter.
            let centre = CellPoint(CellCoordinate(cell: (2 * dot.column + 1) * unit / (2 * columns)),
                                   CellCoordinate(cell: (2 * dot.row + 1) * unit / (2 * rows)))
            return GlyphPrimitive(.circle(centre: centre, radius: radius))
        })
    }
}

// MARK: - Chrome

/// The framework's own marks outside those blocks: Geometric Shapes
/// (U+25A0–25FF), Miscellaneous Technical's house (U+2302), Miscellaneous
/// Symbols' star and ballot boxes (U+2605, U+2610–2611) and Dingbats'
/// heavy cross and heavy angle (U+271A, U+276F). Drawn about the cell's centre in
/// ``CellCoordinate/width`` units, so each keeps its proportions.
private enum Chrome {
    static func polygon(_ points: [(Int, Int)]) -> GlyphShape {
        GlyphShape([GlyphPrimitive(.polygon(points.map { CellPoint.fromCentre($0.0, $0.1) }))])
    }

    static func square(halfSide: Int) -> GlyphPrimitive {
        GlyphPrimitive(.rect(.fromCentre(-halfSide, -halfSide), .fromCentre(halfSide, halfSide)))
    }

    /// A box's outline, its corners joined by the lines' square caps.
    static func box(halfSide: Int) -> [GlyphPrimitive] {
        let corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { CellPoint.fromCentre($0.0 * halfSide, $0.1 * halfSide) }
        return corners.indices.map { GlyphPrimitive(.line(corners[$0], corners[($0 + 1) % corners.count], .light)) }
    }

    static let ballotHalfSide = 18

    /// A house's outline: walls, floor and a pitched roof, in light lines.
    static let house: [GlyphPrimitive] = {
        let corners = [(-16, 18), (16, 18), (16, -2), (0, -18), (-16, -2)].map { CellPoint.fromCentre($0.0, $0.1) }
        return corners.indices.map { GlyphPrimitive(.line(corners[$0], corners[($0 + 1) % corners.count], .light)) }
    }()

    static let shapes: [UInt32: GlyphShape] = [
        0x2302: GlyphShape(house),                                        // ⌂
        0x25A0: GlyphShape([square(halfSide: 18)]),                       // ■
        0x25AA: GlyphShape([square(halfSide: 11)]),                       // ▪
        0x25B2: polygon([(-21, 18), (0, -20), (21, 18)]),                 // ▲
        0x25B6: polygon([(-18, -21), (20, 0), (-18, 21)]),                // ▶
        0x25B8: polygon([(-12, -14), (14, 0), (-12, 14)]),                // ▸
        0x25BC: polygon([(-21, -18), (21, -18), (0, 20)]),                // ▼
        0x25BE: polygon([(-14, -12), (14, -12), (0, 14)]),                // ▾
        0x25C0: polygon([(18, -21), (-20, 0), (18, 21)]),                 // ◀
        0x25C2: polygon([(12, -14), (-14, 0), (12, 14)]),                 // ◂
        0x25C6: polygon([(0, -20), (18, 0), (0, 20), (-18, 0)]),          // ◆
        0x25CF: GlyphShape([GlyphPrimitive(.circle(centre: .fromCentre(0, 0), radius: CellCoordinate(width: 18)))]), // ●
        0x2605: polygon([(0, -20), (5, -6), (19, -6), (8, 2), (12, 16), (0, 8), (-12, 16), (-8, 2), (-19, -6),
                         (-5, -6)]),                                      // ★
        0x2610: GlyphShape(box(halfSide: ballotHalfSide)),                // ☐
        0x2611: GlyphShape(box(halfSide: ballotHalfSide) + polygon(       // ☑
            [(-11, -3), (-4, 4), (11, -11), (11, -4), (-4, 11), (-11, 4)]).primitives),
        0x271A: polygon([(-6, -20), (6, -20), (6, -6), (20, -6), (20, 6), (6, 6), (6, 20), (-6, 20), (-6, 6),
                         (-20, 6), (-20, -6), (-6, -6)]),                 // ✚
        0x276F: polygon([(-14, -20), (-3, -20), (15, 0), (-3, 20), (-14, 20), (4, 0)]), // ❯
    ]

    static var codePoints: [UInt32] { shapes.keys.sorted() }

    static func shape(_ value: UInt32) -> GlyphShape? { shapes[value] }
}
