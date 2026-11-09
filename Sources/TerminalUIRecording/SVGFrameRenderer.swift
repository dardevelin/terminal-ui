import TerminalUI

/// One recorded screen as an SVG document (SVG 1.1 with SVG 2's `href`).
///
/// The picture holds to the terminal's grid whatever font draws it:
///
/// - the canvas, padding included, is the window's background — the one
///   the app set, else the palette's — and each run of cells with another
///   background is a rectangle drawn with `shape-rendering="crispEdges"`, so
///   neighbouring runs meet without an anti-aliased seam;
/// - a run of cells in one style whose characters are printable ASCII or
///   Latin-1 is one `<text>`, its `textLength` the run's cells, so a font
///   whose advance is not quite the cell's is spaced back onto the grid;
/// - every other character the font draws is a `<text>` of its own at its
///   cell, as long as its display width in cells — a double-width glyph
///   across two, its continuation skipped — so a fallback font, with
///   another advance, cannot shift what follows;
/// - box drawing, block elements, braille and the framework's marks are
///   ``GlyphGeometry`` shapes: a `<symbol>` per glyph used, placed with
///   `<use>` in the cell's foreground.
///
/// The same screen gives the same bytes on every system: attributes in a
/// fixed order, every coordinate outside a symbol a whole pixel, and the
/// fractions inside symbols written from integer sixteenths by hand.
package struct SVGFrameRenderer: Sendable {
    package var metrics: CellMetrics
    package var palette: RecordingPalette
    /// Pixels at scale 1 between the cells and the picture's edge.
    package var padding: Int

    package static let defaultPadding = 12
    /// Monospaced faces in the order a reader's system is likely to have
    /// them: the one the docs are drawn in, then macOS's, Windows', and
    /// Linux distributions'.
    package static let fontFamily = #""JetBrains Mono","SF Mono",Menlo,Consolas,"DejaVu Sans Mono","Liberation Mono",monospace"#

    package init(metrics: CellMetrics, palette: RecordingPalette, padding: Int = defaultPadding) {
        precondition(padding >= 0, "padding is not negative")
        self.metrics = metrics
        self.palette = palette
        self.padding = padding
    }

    /// The document for one screen: `buffer`'s cells over `windowBackground`,
    /// with `title` as its accessible name.
    package func render(_ buffer: CellBuffer, windowBackground: Color?, title: String) -> String {
        let layout = Layout(metrics: metrics, padding: padding * metrics.scale,
                            columns: buffer.width, rows: buffer.height)
        let ground = palette.defaultBackground(windowBackground: windowBackground)
        let painted = paint(buffer, ground: ground, layout: layout)

        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(layout.width)\" height=\"\(layout.height)\""
            + " viewBox=\"0 0 \(layout.width) \(layout.height)\">\n"
        svg += "<title>\(SVGText.escaped(title))</title>\n"
        svg += "<desc>\(SVGText.escaped(Self.description))</desc>\n"
        if !painted.symbols.isEmpty {
            svg += "<defs>\n"
            for scalar in painted.symbols.sorted() {
                svg += symbol(scalar, layout: layout)
            }
            svg += "</defs>\n"
        }
        svg += "<rect width=\"\(layout.width)\" height=\"\(layout.height)\" fill=\"\(ground.hexString)\"/>\n"
        if !painted.backgrounds.isEmpty {
            svg += "<g shape-rendering=\"crispEdges\">\n" + painted.backgrounds + "</g>\n"
        }
        if !painted.text.isEmpty {
            svg += "<g font-family='\(Self.fontFamily)' font-size=\"\(metrics.pixelFontSize)\" xml:space=\"preserve\">\n"
                + painted.text + "</g>\n"
        }
        if !painted.shapes.isEmpty {
            svg += "<g>\n" + painted.shapes + "</g>\n"
        }
        if !painted.underlines.isEmpty {
            svg += "<g shape-rendering=\"crispEdges\">\n" + painted.underlines + "</g>\n"
        }
        return svg + "</svg>\n"
    }

    /// What `<desc>` says: how the picture was made, and that bold is a
    /// weight here, where many terminals also brighten it.
    static let description = "A terminal screen recorded by TerminalUI. Bold text is drawn in a heavier weight,"
        + " not a brighter colour. Box drawing, block elements, braille and the framework's marks are"
        + " drawn as shapes, not from a font."

    // MARK: - Cells

    private struct Painted {
        var backgrounds = ""
        var text = ""
        var shapes = ""
        var underlines = ""
        var symbols: Set<UInt32> = []
    }

    private func paint(_ buffer: CellBuffer, ground: RGB, layout: Layout) -> Painted {
        var painted = Painted()
        for y in 0..<buffer.height {
            let top = layout.top(row: y)
            // A cell on the terminal's own background shows the canvas.
            for run in runs(in: buffer, row: y, key: { $0.style.background.flatMap(palette.rgb) }) {
                guard let colour = run.key, colour != ground else { continue }
                painted.backgrounds += "<rect x=\"\(layout.left(column: run.start))\" y=\"\(top)\""
                    + " width=\"\(run.count * layout.cellWidth)\" height=\"\(layout.cellHeight)\" fill=\"\(colour.hexString)\"/>\n"
            }
            for run in runs(in: buffer, row: y, key: { $0.style.underline ? palette.foreground($0.style.foreground) : nil }) {
                guard let colour = run.key else { continue }
                painted.underlines += "<rect x=\"\(layout.left(column: run.start))\" y=\"\(layout.underline(row: y))\""
                    + " width=\"\(run.count * layout.cellWidth)\" height=\"\(layout.underlineThickness)\" fill=\"\(colour.hexString)\"/>\n"
            }
            paintGlyphs(buffer, row: y, layout: layout, into: &painted)
        }
        return painted
    }

    private func paintGlyphs(_ buffer: CellBuffer, row y: Int, layout: Layout, into painted: inout Painted) {
        let baseline = layout.baseline(row: y)
        var pending: (start: Int, style: TextStyle, characters: [Character])?

        func flush() {
            guard let run = pending else { return }
            pending = nil
            // Spaces at a run's ends draw nothing: the run starts at its
            // first glyph and ends at its last.
            let leading = run.characters.prefix { $0 == " " }.count
            let trailing = run.characters.reversed().prefix { $0 == " " }.count
            guard leading < run.characters.count else { return }
            let shown = run.characters[leading..<(run.characters.count - trailing)]
            painted.text += textElement(String(shown), x: layout.left(column: run.start + leading), y: baseline,
                                        length: shown.count * layout.cellWidth, style: run.style)
        }

        for x in 0..<buffer.width {
            let cell = buffer[x, y]
            guard !cell.isContinuation else { continue }
            let style = TextStyle(colour: palette.foreground(cell.style.foreground),
                                  bold: cell.style.bold, italic: cell.style.italic)
            if let scalar = GlyphGeometry.shapeScalar(cell.character) {
                flush()
                painted.symbols.insert(scalar.value)
                painted.shapes += "<use href=\"#\(Self.symbolID(scalar.value))\" x=\"\(layout.left(column: x))\""
                    + " y=\"\(layout.top(row: y))\" width=\"\(layout.cellWidth)\" height=\"\(layout.cellHeight)\""
                    + " fill=\"\(style.colour.hexString)\"/>\n"
            } else if Self.isGridSafe(cell.character) {
                // Every other cell ends a run, so a pending run reaches this one.
                if let run = pending, run.style == style {
                    pending?.characters.append(cell.character)
                } else {
                    flush()
                    pending = (x, style, [cell.character])
                }
            } else {
                flush()
                let cells = buffer[x + 1, y].isContinuation ? 2 : 1
                painted.text += textElement(String(cell.character), x: layout.left(column: x), y: baseline,
                                            length: cells * layout.cellWidth, style: style)
            }
        }
        flush()
    }

    private struct TextStyle: Equatable {
        var colour: RGB
        var bold: Bool
        var italic: Bool
    }

    private func textElement(_ text: String, x: Int, y: Int, length: Int, style: TextStyle) -> String {
        var element = "<text x=\"\(x)\" y=\"\(y)\" textLength=\"\(length)\" lengthAdjust=\"spacing\""
            + " fill=\"\(style.colour.hexString)\""
        if style.bold { element += " font-weight=\"\(Self.boldWeight)\"" }
        if style.italic { element += " font-style=\"italic\"" }
        return element + ">\(SVGText.escaped(text))</text>\n"
    }

    /// CSS's `bold` (CSS Fonts §2.2), written as the number it means.
    static let boldWeight = 700

    /// Maximal runs of the cells in a row that `key` gives one value, a
    /// double-width glyph's continuation counted with its glyph.
    private func runs<Key: Equatable>(in buffer: CellBuffer, row y: Int,
                                      key: (Cell) -> Key) -> [(start: Int, count: Int, key: Key)] {
        var runs: [(start: Int, count: Int, key: Key)] = []
        for x in 0..<buffer.width {
            let value = key(buffer[x, y])
            if let last = runs.last, last.key == value {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((x, 1, value))
            }
        }
        return runs
    }

    // MARK: - Glyph classes

    /// Printable ASCII and Latin-1, the characters every monospaced font
    /// on the stack has, at its own advance: safe to set as a run. The soft
    /// hyphen (U+00AD) is not, as a font may draw it as nothing.
    static func isGridSafe(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let value = scalars.first?.value else { return false }
        return GridSafe.ascii.contains(value) || (GridSafe.latin1.contains(value) && value != GridSafe.softHyphen)
    }

    private enum GridSafe {
        static let ascii: ClosedRange<UInt32> = 0x20...0x7E
        static let latin1: ClosedRange<UInt32> = 0xA0...0xFF
        static let softHyphen: UInt32 = 0xAD
    }

    /// `u` and the code point in upper-case hex, at least four digits, as
    /// Unicode writes it: `u2500`, `u28FF`.
    static func symbolID(_ value: UInt32) -> String {
        let hex = String(value, radix: 16, uppercase: true)
        return "u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    // MARK: - Symbols

    private func symbol(_ value: UInt32, layout: Layout) -> String {
        guard let scalar = Unicode.Scalar(value), let shape = GlyphGeometry.shape(for: scalar) else { return "" }
        let glyph = DeviceGlyph(shape, cellWidth: layout.cellWidth, cellHeight: layout.cellHeight)
        var element = "<symbol id=\"\(Self.symbolID(value))\" viewBox=\"0 0 \(glyph.width) \(glyph.height)\">"
        for mark in glyph.marks {
            element += Self.element(mark.figure, opacity: mark.opacity)
        }
        return element + "</symbol>\n"
    }

    private static func element(_ figure: DeviceGlyph.Figure, opacity: Proportion) -> String {
        let opacityAttribute = opacity == GlyphPrimitive.opaque ? "" : " fill-opacity=\"\(SVGNumber.decimal(opacity))\""
        switch figure {
        case .rect(let x, let y, let width, let height):
            return "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(width)\" height=\"\(height)\"\(opacityAttribute)/>"
        case .polygon(let points):
            let list = points.map { "\(SVGNumber.subpixels($0.x)),\(SVGNumber.subpixels($0.y))" }.joined(separator: " ")
            return "<polygon points=\"\(list)\"\(opacityAttribute)/>"
        case .circle(let centre, let radius):
            return "<circle cx=\"\(SVGNumber.subpixels(centre.x))\" cy=\"\(SVGNumber.subpixels(centre.y))\""
                + " r=\"\(SVGNumber.subpixels(radius))\"\(opacityAttribute)/>"
        case .quarterRing(let centre, let inner, let outer, let quarter):
            return "<path d=\"\(ringPath(centre: centre, inner: inner, outer: outer, quarter: quarter))\"\(opacityAttribute)/>"
        }
    }

    /// The ring's quarter as a closed path (SVG 1.1 §8.3.8, the elliptical
    /// arc): along the outer circle from its horizontal radius to its
    /// vertical one, in to the inner circle, and back. On a y-down canvas a
    /// positive cross product of the two radii is clockwise, SVG's sweep 1.
    private static func ringPath(centre: SubpixelPoint, inner: Int, outer: Int, quarter: CornerOpening) -> String {
        let sweep = quarter.horizontal * quarter.vertical > 0 ? 1 : 0
        func point(_ dx: Int, _ dy: Int) -> String {
            "\(SVGNumber.subpixels(centre.x + dx)) \(SVGNumber.subpixels(centre.y + dy))"
        }
        let (outerRadius, innerRadius) = (SVGNumber.subpixels(outer), SVGNumber.subpixels(inner))
        return "M\(point(quarter.horizontal * outer, 0))"
            + " A\(outerRadius) \(outerRadius) 0 0 \(sweep) \(point(0, quarter.vertical * outer))"
            + " L\(point(0, quarter.vertical * inner))"
            + " A\(innerRadius) \(innerRadius) 0 0 \(1 - sweep) \(point(quarter.horizontal * inner, 0))Z"
    }
}

/// Where cells, baselines and underlines fall on the canvas, in device
/// pixels.
private struct Layout {
    let cellWidth: Int
    let cellHeight: Int
    let padding: Int
    let width: Int
    let height: Int
    /// From a row's top to its text's baseline.
    let baselineOffset: Int
    let underlineThickness: Int
    let underlineOffset: Int

    /// The share of the font's size its ascent exceeds its descent by,
    /// near 0.7 em in the faces of the font stack (JetBrains Mono
    /// 1020 − 300 of 1000 units, Menlo 0.928 − 0.236): a baseline that far
    /// below half the cell centres the text in its row.
    static let ascentOverDescent = Proportion(7, 10)
    /// An underline is a pixel thick, two below the baseline, at scale 1.
    static let underlineGap = 2

    init(metrics: CellMetrics, padding: Int, columns: Int, rows: Int) {
        cellWidth = metrics.cellWidth
        cellHeight = metrics.cellHeight
        self.padding = padding
        width = columns * cellWidth + 2 * padding
        height = rows * cellHeight + 2 * padding
        // (cellHeight + ascentOverDescent · fontSize) / 2, rounded once.
        let share = Self.ascentOverDescent
        baselineOffset = roundedDivision(cellHeight * share.denominator + share.numerator * metrics.pixelFontSize,
                                         2 * share.denominator)
        underlineThickness = metrics.scale
        underlineOffset = Self.underlineGap * metrics.scale
    }

    func left(column: Int) -> Int { padding + column * cellWidth }
    func top(row: Int) -> Int { padding + row * cellHeight }
    func baseline(row: Int) -> Int { top(row: row) + baselineOffset }
    func underline(row: Int) -> Int { baseline(row: row) + underlineOffset }
}

/// Numbers as SVG writes them, from integers, so no platform's float
/// formatting decides a digit.
enum SVGNumber {
    /// Sixteenths of a pixel as an exact decimal: `72` is `4.5`, `1` is
    /// `0.0625`.
    static func subpixels(_ value: Int) -> String {
        let perPixel = SubpixelPoint.perPixel
        let magnitude = abs(value)
        // 1/16 = 0.0625: four decimal places hold every sixteenth exactly.
        let fraction = magnitude % perPixel * fractionScale / perPixel
        return (value < 0 ? "-" : "") + "\(magnitude / perPixel)" + decimals(fraction, places: fractionPlaces)
    }

    /// A proportion to two decimal places: `1/4` is `0.25`.
    static func decimal(_ proportion: Proportion) -> String {
        let hundredths = proportion.scaled(hundred)
        return "\(hundredths / hundred)" + decimals(hundredths % hundred, places: 2)
    }

    private static let fractionPlaces = 4
    private static let fractionScale = 10_000
    private static let hundred = 100

    /// `.` and `fraction`'s digits, `places` of them, without trailing
    /// zeros; nothing for zero.
    private static func decimals(_ fraction: Int, places: Int) -> String {
        guard fraction > 0 else { return "" }
        var digits = String(fraction)
        digits = String(repeating: "0", count: places - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }
}

/// Text as XML 1.0 holds it (https://www.w3.org/TR/xml/#charsets).
enum SVGText {
    /// `text` with markup characters escaped, and every character XML 1.0
    /// cannot hold, or that would not draw in a cell — a control, which
    /// the framework refuses to write but a hand-made log could hold — as
    /// U+FFFD, so the document always parses.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                escaped.unicodeScalars.append(isDrawable(scalar) ? scalar : replacement)
            }
        }
        return escaped
    }

    private static let replacement: Unicode.Scalar = "\u{FFFD}"

    /// XML 1.0's `Char` production less the controls it admits — tab, line
    /// feed, carriage return — and the C1 controls, which draw nothing.
    private static func isDrawable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return false }
        switch scalar.value {
        case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }
}
