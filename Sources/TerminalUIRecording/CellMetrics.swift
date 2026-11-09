/// A ratio of two integers, so a cell's size is the same number of pixels
/// on every CPU and system: no floating point rounds it.
package struct Proportion: Hashable, Sendable {
    package var numerator: Int
    package var denominator: Int

    package init(_ numerator: Int, _ denominator: Int) {
        precondition(denominator > 0, "a proportion's denominator is positive")
        self.numerator = numerator
        self.denominator = denominator
    }

    /// `self × value`, rounded to the nearest integer, half up.
    package func scaled(_ value: Int) -> Int {
        (2 * numerator * value + denominator) / (2 * denominator)
    }
}

/// The size of a terminal cell in pixels, which SVG and raster pictures of
/// a recording share so the two line up.
///
/// `cellWidth = round(advance · fontSize · scale)` and `cellHeight =
/// round(lineHeight · fontSize · scale)`, each rounded once, from the
/// exact product: a cell rounded at scale 1 and then doubled could differ
/// by a pixel from the cell drawn at scale 2.
package struct CellMetrics: Hashable, Sendable {
    /// The font's size in pixels at scale 1 (its em).
    package var fontSize: Int
    /// A row's height as a multiple of the font's size.
    package var lineHeight: Proportion
    /// A glyph's advance as a multiple of the font's size: a monospaced
    /// font's `hmtx` advance over its `head.unitsPerEm` (OpenType spec).
    package var advance: Proportion
    /// Device pixels per pixel: 2 for an `@2x` picture.
    package var scale: Int

    /// Rows a little taller than the em, as terminals space them.
    package static let defaultLineHeight = Proportion(6, 5)
    /// JetBrains Mono's every glyph advances 600 of its 1000 units per em.
    package static let jetBrainsMonoAdvance = Proportion(600, 1000)

    package init(fontSize: Int, lineHeight: Proportion = defaultLineHeight,
                 advance: Proportion, scale: Int = 1) {
        precondition(fontSize > 0 && scale > 0, "a cell has a size")
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.advance = advance
        self.scale = scale
    }

    /// The font's size in device pixels.
    package var pixelFontSize: Int { fontSize * scale }
    package var cellWidth: Int { advance.scaled(pixelFontSize) }
    package var cellHeight: Int { lineHeight.scaled(pixelFontSize) }
}

extension Proportion {
    /// A decimal as a command line or a settings file writes it — `1.2`,
    /// `0.6`, `2` — as the exact ratio it names, `12/10`; nil for anything
    /// else, a sign or an exponent included.
    package init?(decimal text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let isDigits = { (part: Substring) in !part.isEmpty && part.allSatisfy(\.isASCIIDigit) }
        guard (1...2).contains(parts.count), parts.allSatisfy(isDigits),
              parts.count == 1 || parts[1].count <= DecimalLimits.fractionDigits,
              let whole = Int(parts[0]), whole <= DecimalLimits.largestWhole else { return nil }
        var denominator = 1
        var numerator = whole
        if parts.count == 2, let fraction = Int(parts[1]) {
            for _ in parts[1] { denominator *= DecimalLimits.radix }
            numerator = whole * denominator + fraction
        }
        self.init(numerator, denominator)
    }
}

private enum DecimalLimits {
    static let radix = 10
    /// Six places and a whole part under a million keep every product
    /// ``Proportion/scaled(_:)`` forms far inside an `Int`.
    static let fractionDigits = 6
    static let largestWhole = 999_999
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
