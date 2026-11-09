import Testing
@testable import TerminalUIRaster

@Suite("TrueType font: the bundled JetBrains Mono")
struct BundledFontTests {

    @Test("all four files parse, with the family's metrics", arguments: FontStyle.allCases)
    func parses(_ style: FontStyle) throws {
        let font = try BundledFont.font(style)
        #expect(font.unitsPerEm == 1000)
        #expect(font.glyphCount > 1700)
        #expect(font.horizontalHeaderMetrics == FontMetrics(ascender: 1020, descender: -300, lineGap: 0))
        #expect(font.typographicMetrics == FontMetrics(ascender: 1020, descender: -300, lineGap: 0))
        #expect(font.usesTypographicMetrics, "fsSelection bit 7")
        #expect(font.metrics == font.typographicMetrics)
        #expect(try TrueTypeFont.faceCount(in: BundledFont.bytes(style)) == 1)
    }

    @Test("every printable ASCII character advances 600/1000 em", arguments: FontStyle.allCases)
    func advances(_ style: FontStyle) throws {
        let font = try BundledFont.font(style)
        for code in 0x20...0x7E {
            let glyph = try #require(font.glyphID(for: Unicode.Scalar(UInt8(code))), "U+\(code)")
            #expect(try font.advanceWidth(ofGlyph: glyph) == 600)
        }
    }

    // The ids are the Regular file's own; what a lookup must get right is
    // which subtable it reads and how (format 12 is preferred, and is the
    // only one that reaches the supplementary plane).
    @Test("cmap maps ASCII, box drawing and the supplementary plane, and not CJK")
    func characterMap() throws {
        let font = try BundledFont.font()
        #expect(font.glyphID(for: "A") == 1)
        #expect(font.glyphID(for: "\u{2500}") == 1326, "─ BOX DRAWINGS LIGHT HORIZONTAL")
        #expect(font.glyphID(for: "\u{256D}") == 1314, "╭ BOX DRAWINGS LIGHT ARC DOWN AND RIGHT")
        #expect(font.glyphID(for: "\u{1D538}") == 672, "𝔸 MATHEMATICAL DOUBLE-STRUCK CAPITAL A")
        #expect(font.glyphID(for: "\u{4E2D}") == nil, "中 is not in the font")
        #expect(font.glyphID(for: "\u{10FFFF}") == nil)
    }

    @Test("a simple glyph has its contours and points")
    func simpleGlyph() throws {
        let font = try BundledFont.font()
        let outline = try font.outline(ofGlyph: #require(font.glyphID(for: "A")))
        #expect(outline.contourEnds == [7, 16])
        #expect(outline.points.allSatisfy { (0...600).contains($0.x) && (0...730).contains($0.y) })
        #expect(try font.outline(ofGlyph: #require(font.glyphID(for: " "))).isEmpty)
    }

    // é is a composite in JetBrains Mono: e (two contours, 33 points),
    // then the acute (one contour, 4 points), offset by ARGS_ARE_XY_VALUES
    // words. Its points are e's unmoved and the acute's all moved alike.
    @Test("a composite glyph resolves to its components' points")
    func compositeGlyph() throws {
        let font = try BundledFont.font()
        let accented = try font.outline(ofGlyph: #require(font.glyphID(for: "é")))
        let base = try font.outline(ofGlyph: #require(font.glyphID(for: "e")))
        #expect(accented.points.count == 37)
        #expect(accented.contourEnds == [23, 32, 36])
        #expect(Array(accented.points.prefix(33)) == base.points)
        let acute = try font.outline(ofGlyph: 1643)
        #expect(acute.points.count == 4)
        let offsets = Set(zip(accented.points.suffix(4), acute.points).map { [$0.x - $1.x, $0.y - $1.y] })
        #expect(offsets.count == 1, "\(offsets)")
    }
}

@Suite("TrueType font: built to order")
struct BuiltFontTests {
    private let square = [OutlinePoint(0, 0), OutlinePoint(0, 100), OutlinePoint(100, 100), OutlinePoint(100, 0)]

    private func font(_ builder: FontBuilder) throws -> TrueTypeFont {
        try TrueTypeFont(bytes: builder.build())
    }

    @Test("hhea's metrics are used unless OS/2 asks for its own")
    func metricsChoice() throws {
        var builder = FontBuilder()
        #expect(try font(builder).metrics == builder.horizontalHeaderMetrics)
        builder.usesTypographicMetrics = true
        #expect(try font(builder).metrics == builder.typographicMetrics)
    }

    @Test("format 12 reaches past the BMP, format 4 within it")
    func characterMaps() throws {
        var builder = FontBuilder()
        let a = builder.add(.simple([square]), for: "a")
        let emoji = builder.add(.simple([square]), for: "😀")
        let built = try font(builder)
        #expect(built.glyphID(for: "a") == a)
        #expect(built.glyphID(for: "😀") == emoji)
        #expect(built.glyphID(for: "b") == nil)

        var bmpOnly = FontBuilder()
        _ = bmpOnly.add(.simple([square]), for: "a")
        #expect(try font(bmpOnly).glyphID(for: "a") == 1)
    }

    @Test("a uniform scale, an x and y scale and a two-by-two all transform their component")
    func scaledComponents() throws {
        var builder = FontBuilder()
        let base = builder.add(.simple([square]))
        // F2Dot14: 0x2000 is 0.5, 0x4000 is 1, 0xC000 is −1.
        let half = builder.add(.composite([.init(glyph: base, arguments: (10, 20), transform: [0x2000])]))
        let stretched = builder.add(.composite([.init(glyph: base, arguments: (0, 0), transform: [0x4000, 0x2000])]))
        let rotated = builder.add(.composite([.init(glyph: base, arguments: (0, 0), transform: [0, 0x4000, 0xC000, 0])]))
        let built = try font(builder)
        #expect(try built.outline(ofGlyph: half).points.map { [$0.x, $0.y] } == [[10, 20], [10, 70], [60, 70], [60, 20]])
        #expect(try built.outline(ofGlyph: stretched).points.map { [$0.x, $0.y] } == [[0, 0], [0, 50], [100, 50], [100, 0]])
        // x′ = a·x + c·y = −y, y′ = b·x + d·y = x: a quarter turn anticlockwise.
        #expect(try built.outline(ofGlyph: rotated).points.map { [$0.x, $0.y] } == [[0, 0], [-100, 0], [-100, 100], [0, 100]])
    }

    @Test("an offset is scaled only when SCALED_COMPONENT_OFFSET says so")
    func scaledOffset() throws {
        var builder = FontBuilder()
        let base = builder.add(.simple([square]))
        let scaled = builder.add(.composite([.init(glyph: base, arguments: (100, 40),
                                                   flags: FontBuilder.ComponentFlags.argumentsAreXYValues
                                                       | FontBuilder.ComponentFlags.scaledComponentOffset,
                                                   transform: [0x2000])]))
        #expect(try font(builder).outline(ofGlyph: scaled).points.first == OutlinePoint(50, 20))
    }

    @Test("point matching places a component by a point of its own and one of the glyph so far")
    func pointMatching() throws {
        var builder = FontBuilder()
        let base = builder.add(.simple([square]))
        // Point 2 of the first square is (100, 100); point 0 of the second
        // is put on it.
        let matched = builder.add(.composite([.init(glyph: base, arguments: (0, 0)),
                                              .init(glyph: base, arguments: (2, 0), flags: 0)]))
        let outline = try font(builder).outline(ofGlyph: matched)
        #expect(outline.contourEnds == [3, 7])
        #expect(outline.points[4] == OutlinePoint(100, 100))
        let badMatch = builder.add(.composite([.init(glyph: base, arguments: (9, 0), flags: 0)]))
        #expect(throws: FontError.self) { try font(builder).outline(ofGlyph: badMatch) }
    }

    @Test("composites nest, and one that contains itself is too deep")
    func nesting() throws {
        var builder = FontBuilder()
        let base = builder.add(.simple([square]))
        let inner = builder.add(.composite([.init(glyph: base, arguments: (5, 0))]))
        let outer = builder.add(.composite([.init(glyph: inner, arguments: (0, 7)), .init(glyph: base, arguments: (200, 0))]))
        let selfReferencing = builder.glyphs.count
        _ = builder.add(.composite([.init(glyph: selfReferencing, arguments: (0, 0))]))
        let built = try font(builder)
        let outline = try built.outline(ofGlyph: outer)
        #expect(outline.points.count == 8)
        #expect(outline.points[0] == OutlinePoint(5, 7) && outline.points[4] == OutlinePoint(200, 0))
        #expect(throws: FontError.compositeTooDeep(glyph: selfReferencing)) { try built.outline(ofGlyph: selfReferencing) }
    }

    @Test("a collection's faces are each its own font")
    func collection() throws {
        var first = FontBuilder()
        _ = first.add(.simple([square]), for: "a")
        var second = FontBuilder()
        second.unitsPerEm = 2048
        _ = second.add(.empty, for: "b")
        _ = second.add(.simple([square]), for: "c")
        let bytes = FontBuilder.collection([first, second])
        #expect(try TrueTypeFont.faceCount(in: bytes) == 2)
        #expect(try TrueTypeFont(bytes: bytes, faceIndex: 0).unitsPerEm == 1000)
        let face = try TrueTypeFont(bytes: bytes, faceIndex: 1)
        #expect(face.unitsPerEm == 2048 && face.glyphID(for: "c") == 2)
        #expect(throws: FontError.faceOutOfRange(index: 2, count: 2)) { try TrueTypeFont(bytes: bytes, faceIndex: 2) }
        #expect(throws: FontError.faceOutOfRange(index: 1, count: 1)) { try TrueTypeFont(bytes: first.build(), faceIndex: 1) }
    }

    @Test("CFF outlines are refused by name, as is a file that is no font")
    func signatures() throws {
        var bytes = FontBuilder().build()
        bytes.replaceSubrange(0..<4, with: Array("OTTO".utf8))
        #expect(throws: FontError.cffOutlines) { try TrueTypeFont(bytes: bytes) }
        #expect(FontError.cffOutlines.description.contains("OTTO"))
        bytes.replaceSubrange(0..<4, with: Array("wOFF".utf8))
        #expect(throws: FontError.unknownSignature(0x774F_4646)) { try TrueTypeFont(bytes: bytes) }
        #expect(throws: FontError.self) { try TrueTypeFont(bytes: []) }
    }
}

/// Damage of every kind throws, and never traps: the test is that the
/// process survives each case, and that every call either returns or
/// throws a `FontError`.
@Suite("TrueType font: malformed input")
struct MalformedFontTests {

    /// Everything a renderer would ask of a font.
    private func exercise(_ bytes: [UInt8]) {
        guard let font = try? TrueTypeFont(bytes: bytes) else { return }
        let source = BuiltinGlyphSource(fonts: FontSet(regular: font), size: GlyphSize(pixelsPerEm: 15))
        for glyph in 0..<min(font.glyphCount, 64) {
            _ = try? font.outline(ofGlyph: glyph)
            _ = try? font.advanceWidth(ofGlyph: glyph)
        }
        for character in "abc😀 é" {
            for style in FontStyle.allCases { _ = source.glyph(character, style: style) }
        }
    }

    private func sample() -> [UInt8] {
        var builder = FontBuilder()
        let square = [OutlinePoint(0, 0), OutlinePoint(0, 700, onCurve: false), OutlinePoint(500, 700), OutlinePoint(500, 0)]
        let base = builder.add(.simple([square]), for: "a")
        _ = builder.add(.composite([.init(glyph: base, arguments: (10, 0), transform: [0x3000]),
                                    .init(glyph: base, arguments: (1, 2), flags: 0)]), for: "b")
        _ = builder.add(.simple([square, square]), for: "😀")
        return builder.build()
    }

    @Test("every truncation of a font throws or reads, and never traps")
    func truncations() {
        let bytes = sample()
        for length in 0..<bytes.count { exercise(Array(bytes.prefix(length))) }
        #expect(throws: FontError.self) { try TrueTypeFont(bytes: Array(bytes.prefix(bytes.count / 2))) }
    }

    @Test("the bundled font cut short throws")
    func truncatedBundledFont() {
        let bytes = BundledFont.bytes(.regular)
        for length in [0, 3, 11, 100, 1000, bytes.count / 2, bytes.count - 1] {
            #expect(throws: FontError.self, "\(length) bytes") { try TrueTypeFont(bytes: Array(bytes.prefix(length))) }
        }
    }

    @Test("a table directory pointing past the file throws")
    func badTableOffset() throws {
        var bytes = sample()
        // The first record's offset field: 12 bytes of header, then tag
        // and checksum.
        bytes.replaceSubrange(20..<24, with: FontBuilder.uint32(0x7FFF_FFF0))
        #expect(throws: FontError.self) { try TrueTypeFont(bytes: bytes) }
    }

    @Test("a glyph whose location runs backwards or past glyf throws")
    func badLocations() throws {
        let bytes = sample()
        let font = try TrueTypeFont(bytes: bytes)
        // loca is the seventh table in the builder's directory; glyph 1
        // starts at its second long offset and ends at its third.
        let record = 12 + 6 * 16
        let locaOffset = (bytes[record + 8..<record + 12]).reduce(0) { $0 << 8 | Int($1) }
        var backwards = bytes
        backwards.replaceSubrange(locaOffset + 4..<locaOffset + 8, with: FontBuilder.uint32(0x00FF_FFF0))
        #expect(throws: FontError.self) { try TrueTypeFont(bytes: backwards).outline(ofGlyph: 1) }
        var pastEnd = bytes
        pastEnd.replaceSubrange(locaOffset + 8..<locaOffset + 12, with: FontBuilder.uint32(0x00FF_FFFF))
        #expect(throws: FontError.self) { try TrueTypeFont(bytes: pastEnd).outline(ofGlyph: 1) }
        #expect(throws: FontError.self) { try font.outline(ofGlyph: font.glyphCount) }
        #expect(throws: FontError.self) { try font.advanceWidth(ofGlyph: -1) }
    }

    // A deterministic fuzz: bytes overwritten at random, the same sequence
    // on every run and system (the encoders' generator, from Samples).
    @Test("random damage throws or reads, and never traps")
    func randomDamage() {
        let original = sample()
        var generator = SampleRandom(seed: 3141)
        for _ in 0..<1000 {
            var bytes = original
            for _ in 0...(Int(generator.nextByte()) % 4) {
                let position = (Int(generator.nextByte()) << 8 | Int(generator.nextByte())) % bytes.count
                bytes[position] = generator.nextByte()
            }
            exercise(bytes)
        }
    }
}
