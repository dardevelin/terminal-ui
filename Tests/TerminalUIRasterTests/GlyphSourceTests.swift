import Testing
@testable import TerminalUIRaster

@Suite("Builtin glyph source")
struct BuiltinGlyphSourceTests {
    private static let goldenCharacters: [(Character, String)] = [("A", "A"), ("g", "g"), ("@", "at"), ("é", "e-acute")]

    // The docs render at 15 px, 1× and 2×. Each golden is a PGM whose
    // comment holds the placement; open one in any viewer, or read the
    // ASCII art a mismatch prints.
    @Test("JetBrains Mono glyphs match their goldens at 15 px, 1× and 2×", arguments: [1, 2])
    func goldens(scale: Int) throws {
        let source = BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15, scale: scale))
        for (character, name) in Self.goldenCharacters {
            let glyph = try #require(source.glyph(character, style: .regular))
            #expect(glyph.advance == 9 * scale)
            try expectGolden(portableGraymap(glyph), named: "glyph-\(name)-15px@\(scale)x.pgm")
            if scale == 1 { print("\(character) left \(glyph.left) top \(glyph.top)\n\(asciiArt(glyph))") }
        }
    }

    @Test("glyphs sit on the baseline: A's foot on it, g's tail below")
    func placement() throws {
        let source = BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15))
        let capital = try #require(source.glyph("A", style: .regular))
        #expect(capital.top + capital.height == 0, "A ends on the baseline")
        #expect((-12 ... -10).contains(capital.top), "a cap height of 0.73 em is 11 px")
        let descender = try #require(source.glyph("g", style: .regular))
        #expect(descender.top + descender.height > 2, "g descends")
        #expect(capital.left >= 0 && capital.left + capital.width <= 9, "within its 9 px advance")
    }

    @Test("a space is an empty glyph with an advance; a missing character is nil")
    func spaceAndMissing() throws {
        let source = BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15))
        let space = try #require(source.glyph(" ", style: .regular))
        #expect(space.width == 0 && space.height == 0 && space.advance == 9)
        #expect(source.glyph("中", style: .regular) == nil)
        #expect(source.glyph("中", style: .bold) == nil)
    }

    // Swift's Character equality is canonical equivalence, so the two
    // spellings of é are one Character; drawn first or second, each is
    // still drawn from its own first scalar.
    @Test("a grapheme cluster draws its first scalar")
    func graphemeCluster() throws {
        let source = BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15))
        let precomposed = source.glyph("\u{E9}", style: .regular)
        let decomposed = source.glyph("e\u{301}", style: .regular)
        #expect(decomposed == source.glyph("e", style: .regular))
        #expect(decomposed != precomposed)
        #expect(source.glyph("\u{1F44D}\u{1F3FD}", style: .regular) == nil)
    }

    @Test("each style draws from its own file when the set has it")
    func stylesFromFiles() throws {
        let fonts = try BundledFont.fontSet()
        let source = BuiltinGlyphSource(fonts: fonts, size: GlyphSize(pixelsPerEm: 15))
        for style in FontStyle.allCases {
            let font = try BundledFont.font(style)
            let expected = try BuiltinGlyphSource.draw(glyph: #require(font.glyphID(for: "R")), of: font,
                                                       size: GlyphSize(pixelsPerEm: 15), synthesis: [])
            #expect(source.glyph("R", style: style) == expected, "\(style)")
        }
        let drawn = Set(FontStyle.allCases.map { coverage(of: source.glyph("R", style: $0)) })
        #expect(drawn.count == 4, "four different faces")
    }

    @Test("a style without its file is synthesized from regular")
    func synthesizedStyles() throws {
        let regularOnly = BuiltinGlyphSource(fonts: FontSet(regular: try BundledFont.font()), size: GlyphSize(pixelsPerEm: 15))
        let regular = try #require(regularOnly.glyph("l", style: .regular))
        let bold = try #require(regularOnly.glyph("l", style: .bold))
        let italic = try #require(regularOnly.glyph("l", style: .italic))
        let boldItalic = try #require(regularOnly.glyph("l", style: .boldItalic))
        func ink(_ glyph: GlyphBitmap) -> Int { coverage(of: glyph).reduce(0) { $0 + Int($1) } }
        #expect(ink(bold) > ink(regular) * 5 / 4, "bold carries more ink")
        #expect(bold.advance == regular.advance, "and keeps the cell's advance")
        // The shear moves a row right by 17/80 of its height: the top row's
        // ink by about 2.1 px more than the bottom row's, over 10 rows.
        func lean(_ glyph: GlyphBitmap) -> Double {
            let pixels = coverage(of: glyph)
            func centre(_ row: Int) -> Double {
                let weights = (0..<glyph.width).map { Double(pixels[row * glyph.width + $0]) }
                return zip(weights, 0...).reduce(0) { $0 + $1.0 * Double($1.1) } / weights.reduce(0, +)
            }
            return centre(0) - centre(glyph.height - 1)
        }
        let slant = lean(italic) - lean(regular)
        #expect((1.6...2.6).contains(slant), "italic leans: \(slant) px")
        #expect(abs(ink(italic) - ink(regular)) < ink(regular) / 20, "a shear keeps the area")
        #expect(ink(boldItalic) > ink(italic) * 5 / 4)
        #expect(abs(lean(boldItalic) - lean(bold) - slant) < 0.5)
    }

    @Test("bold italic falls back to the bold file, slanted, before regular")
    func partialFamily() throws {
        let fonts = FontSet(regular: try BundledFont.font(), bold: try BundledFont.font(.bold))
        let source = BuiltinGlyphSource(fonts: fonts, size: GlyphSize(pixelsPerEm: 15))
        let bold = try BundledFont.font(.bold)
        let expected = try BuiltinGlyphSource.draw(glyph: #require(bold.glyphID(for: "R")), of: bold,
                                                   size: GlyphSize(pixelsPerEm: 15), synthesis: .italic)
        #expect(source.glyph("R", style: .boldItalic) == expected)
    }

    @Test("a source draws a glyph once and keeps it")
    func cache() throws {
        let source = BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15))
        let first = source.glyph("Q", style: .italic)
        #expect(source.cachedGlyphCount == 1)
        #expect(source.glyph("Q", style: .italic) == first)
        _ = source.glyph("中", style: .italic)
        _ = source.glyph("中", style: .italic)
        #expect(source.cachedGlyphCount == 2, "a missing glyph is remembered too")
    }

    // The budget the plan states is well under a second for the printable
    // ASCII set in a debug build; this holds it to that, and prints the
    // time so a slowdown shows before it fails.
    @Test("drawing printable ASCII at 15 px takes well under a second")
    func speed() throws {
        let fonts = try BundledFont.fontSet()
        let clock = ContinuousClock()
        var drawn = 0
        let elapsed = clock.measure {
            for style in [FontStyle.regular, .bold] {
                let source = BuiltinGlyphSource(fonts: fonts, size: GlyphSize(pixelsPerEm: 15))
                for code in UInt8(0x20)...0x7E where source.glyph(Character(Unicode.Scalar(code)), style: style) != nil {
                    drawn += 1
                }
            }
        }
        print("drew \(drawn) glyphs (printable ASCII, regular and bold) at 15 px in \(elapsed)")
        #expect(drawn == 2 * 95)
        #expect(elapsed < .seconds(1))
    }
}
