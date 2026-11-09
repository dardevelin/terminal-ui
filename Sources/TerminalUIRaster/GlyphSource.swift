/// The four faces a terminal cell can ask for.
package enum FontStyle: CaseIterable, Hashable, Sendable {
    case regular
    case bold
    case italic
    case boldItalic

    package var isBold: Bool { self == .bold || self == .boldItalic }
    package var isItalic: Bool { self == .italic || self == .boldItalic }
}

/// A glyph's pixels: coverage for a font's outlines, which the composer
/// tints with the cell's colour, or colour of its own for an emoji a
/// system engine draws.
package enum GlyphPixels: Equatable, Sendable {
    /// One byte a pixel, 0 to 255.
    case coverage([UInt8])
    /// Four bytes a pixel, red, green, blue and alpha, the colours already
    /// multiplied by the alpha.
    case premultipliedRGBA([UInt8])
}

/// A drawn glyph, placed relative to the pen: the pen sits on the baseline
/// at the cell's left edge, and `left` and `top` are where the image's
/// first column and row go from there, in device pixels with y down (so
/// `top` is negative for ink above the baseline).
package struct GlyphBitmap: Equatable, Sendable {
    package var width: Int
    package var height: Int
    package var left: Int
    package var top: Int
    /// The font's advance, rounded to whole device pixels. A cell's width
    /// is the caller's, from its cell metrics; this is for checking a font
    /// against them.
    package var advance: Int
    package var pixels: GlyphPixels

    package init(width: Int, height: Int, left: Int, top: Int, advance: Int, pixels: GlyphPixels) {
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.advance = advance
        self.pixels = pixels
    }
}

/// Where a renderer gets its glyphs: the builtin TrueType engine, or a
/// system one. Nil means the source has no glyph for the character, so the
/// renderer falls back to the next source.
package protocol GlyphSource {
    func glyph(_ character: Character, style: FontStyle) -> GlyphBitmap?
}

/// The size glyphs are drawn at: the em in pixels at 1×, and the device
/// scale (2 for an `@2x` image).
package struct GlyphSize: Hashable, Sendable {
    package var pixelsPerEm: Int
    package var scale: Int

    package init(pixelsPerEm: Int, scale: Int = 1) {
        precondition(pixelsPerEm > 0 && scale > 0, "a glyph size of \(pixelsPerEm) px at \(scale)×")
        self.pixelsPerEm = pixelsPerEm
        self.scale = scale
    }

    /// Device pixels per em, in 24.8 fixed point.
    var fixedPixelsPerEm: Int { pixelsPerEm * scale * CoverageRasterizer.one }
}

/// The files a font family's styles come from. Only regular is required;
/// a style without its file is drawn from the nearest one there is, bold
/// and italic synthesized as needed.
package struct FontSet: Sendable {
    package var regular: TrueTypeFont
    package var bold: TrueTypeFont?
    package var italic: TrueTypeFont?
    package var boldItalic: TrueTypeFont?

    package init(regular: TrueTypeFont, bold: TrueTypeFont? = nil, italic: TrueTypeFont? = nil,
                 boldItalic: TrueTypeFont? = nil) {
        self.regular = regular
        self.bold = bold
        self.italic = italic
        self.boldItalic = boldItalic
    }

    /// A face for `style`, best first: its own file; then a file that has
    /// one of its two traits, synthesizing the other; then regular,
    /// synthesizing both. A face that lacks the character falls through to
    /// the next.
    func faces(for style: FontStyle) -> [(font: TrueTypeFont, synthesis: Synthesis)] {
        var faces: [(TrueTypeFont, Synthesis)] = []
        switch style {
        case .regular: break
        case .bold: if let bold { faces.append((bold, [])) }
        case .italic: if let italic { faces.append((italic, [])) }
        case .boldItalic:
            if let boldItalic { faces.append((boldItalic, [])) }
            if let bold { faces.append((bold, .italic)) }
            if let italic { faces.append((italic, .bold)) }
        }
        faces.append((regular, Synthesis(style)))
        return faces
    }
}

/// The traits a style needs that its face does not have.
struct Synthesis: OptionSet, Hashable {
    let rawValue: Int
    static let bold = Synthesis(rawValue: 1)
    static let italic = Synthesis(rawValue: 2)
}

extension Synthesis {
    init(_ style: FontStyle) {
        self = []
        if style.isBold { insert(.bold) }
        if style.isItalic { insert(.italic) }
    }
}

/// Glyphs from TrueType files, drawn by `CoverageRasterizer`: no
/// floating point anywhere, so a glyph is the same bytes on every system.
/// Each glyph is drawn once per style at this source's size and kept; a
/// source for another size (the `@2x` render) is another source.
///
/// A grapheme cluster is drawn as its first scalar's glyph: there is no
/// shaping, so combining marks and emoji sequences lose all but their base.
/// How many cells a character takes is the caller's to decide.
package final class BuiltinGlyphSource: GlyphSource {
    /// A glyph whose outline reaches further than this many ems from its
    /// origin is malformed, not drawn: it would ask for a bitmap of any size.
    static let maximumExtentInEms = 8

    package let fonts: FontSet
    package let size: GlyphSize
    /// Keyed by the scalar drawn, not the `Character`: a `Character`
    /// compares by canonical equivalence, so "é" and "e" + U+0301 are one
    /// key, but here the first is a glyph of its own and the second an e.
    private var cache: [GlyphKey: GlyphBitmap?] = [:]

    private struct GlyphKey: Hashable {
        let scalar: Unicode.Scalar
        let style: FontStyle
    }

    package init(fonts: FontSet, size: GlyphSize) {
        self.fonts = fonts
        self.size = size
    }

    /// How many scalars and styles have been asked for, drawn or not.
    var cachedGlyphCount: Int { cache.count }

    package func glyph(_ character: Character, style: FontStyle) -> GlyphBitmap? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        let key = GlyphKey(scalar: scalar, style: style)
        if let cached = cache[key] { return cached }
        let drawn = draw(scalar, style: style)
        cache[key] = drawn
        return drawn
    }

    private func draw(_ scalar: Unicode.Scalar, style: FontStyle) -> GlyphBitmap? {
        for (font, synthesis) in fonts.faces(for: style) {
            guard let glyph = font.glyphID(for: scalar) else { continue }
            // A glyph the font maps but cannot read is as good as missing.
            return try? Self.draw(glyph: glyph, of: font, size: size, synthesis: synthesis)
        }
        return nil
    }

    static func draw(glyph: Int, of font: TrueTypeFont, size: GlyphSize,
                     synthesis: Synthesis) throws(FontError) -> GlyphBitmap? {
        let outline = try font.outline(ofGlyph: glyph)
        let limit = maximumExtentInEms * font.unitsPerEm
        guard outline.points.allSatisfy({ abs($0.x) <= limit && abs($0.y) <= limit }) else { return nil }
        let advance = IntegerMath.roundedDivide(try font.advanceWidth(ofGlyph: glyph) * size.pixelsPerEm * size.scale,
                                                font.unitsPerEm)
        var device = outline.map { point in
            OutlinePoint(IntegerMath.roundedDivide(point.x * size.fixedPixelsPerEm, font.unitsPerEm),
                         IntegerMath.roundedDivide(point.y * size.fixedPixelsPerEm, font.unitsPerEm),
                         onCurve: point.isOnCurve)
        }
        if synthesis.contains(.bold) { device = SyntheticStyle.embolden(device, size: size) }
        if synthesis.contains(.italic) { device = SyntheticStyle.oblique(device) }
        // Font units are y up; the device is y down.
        let bitmap = CoverageRasterizer.rasterize(device.map { OutlinePoint($0.x, -$0.y, onCurve: $0.isOnCurve) })
        return GlyphBitmap(width: bitmap.width, height: bitmap.height, left: bitmap.left, top: bitmap.top,
                           advance: advance, pixels: .coverage(bitmap.coverage))
    }
}
