import Testing
@testable import TerminalUIRaster

// The colour table a GIF of terminal screens is drawn with: exact colours
// kept exact, anti-aliased edges shaded on ramps that lose steps from the
// least-used pairs first, and only past 255 exact colours a stand-in.

/// sRGB as the space to measure in: the builder takes any, and the
/// recording renderer gives it Oklab.
private func srgb(_ colour: RGBA) -> (Int, Int, Int) {
    (Int(colour.red), Int(colour.green), Int(colour.blue))
}

private func grey(_ level: Int) -> RGBA { RGBA(UInt8(level), UInt8(level), UInt8(level)) }

/// Coverage at the middle of level `level` of 16.
private func coverage(level: Int) -> UInt8 { UInt8(level * 17) }

@Suite("The indexed palette builder")
struct IndexedPaletteBuilderTests {

    @Test func blendingIsInSRGBRoundedToNearest() {
        let white = RGBA(255, 255, 255), black = RGBA(0, 0, 0)
        #expect(BlendedPixel.blend(white, over: black, coverage: 128) == RGBA(128, 128, 128))
        #expect(BlendedPixel.blend(white, over: black, coverage: 1) == RGBA(1, 1, 1))
        #expect(BlendedPixel.blend(RGBA(200, 100, 0), over: RGBA(0, 50, 255), coverage: 64)
                == RGBA(50, 63, 191))
    }

    @Test func aPixelOfOneColourIsHeldAsThatColour() {
        let red = RGBA(255, 0, 0), blue = RGBA(0, 0, 255)
        #expect(BlendedPixel(red, over: blue, coverage: 0) == .solid(blue))
        #expect(BlendedPixel(red, over: blue, coverage: 255) == .solid(red))
        #expect(BlendedPixel(red, over: red, coverage: 90) == .solid(red))
        #expect(!BlendedPixel(red, over: blue, coverage: 90).isSolid)
    }

    @Test func exactColoursAreNeverApproximatedWhenTheyFit() {
        // 200 solid colours and 10 edges with every level between: 200 + 20
        // ends + 140 steps is far past 255, so ramps lose steps, and no
        // solid colour or end changes.
        var builder = IndexedPaletteBuilder()
        let solids = (0..<200).map { RGBA(UInt8($0), 7, 200) }
        for colour in solids { builder.add(.solid(colour)) }
        let pairs = (0..<10).map { (RGBA(250, UInt8($0 * 20), 0), RGBA(0, UInt8($0 * 20), 250)) }
        for (foreground, background) in pairs {
            for level in 1..<15 { builder.add(BlendedPixel(foreground, over: background, coverage: coverage(level: level))) }
        }
        let palette = builder.build(capacity: 255, reservingTransparency: true, coordinates: srgb)
        #expect(palette.approximations.isEmpty)
        #expect(palette.colours.count <= 256 && palette.transparentIndex == 0 && palette.colours[0] == .transparent)
        for colour in solids + pairs.flatMap({ [$0.0, $0.1] }) {
            #expect(palette.colours[Int(palette.index(of: .solid(colour)))] == colour)
        }
    }

    @Test func theLeastUsedPairLosesStepsFirst() {
        // Four exact colours and two full ramps of 14 steps: 32 colours. A
        // table of 20 cuts the rarely drawn ramp to every fifth level (4 +
        // 14 + 2) and leaves the common one whole.
        var builder = IndexedPaletteBuilder()
        let common = (RGBA(255, 255, 255), RGBA(0, 0, 0))
        let rare = (RGBA(255, 0, 0), RGBA(0, 0, 255))
        for level in 1..<15 {
            builder.add(BlendedPixel(common.0, over: common.1, coverage: coverage(level: level)), count: 100)
            builder.add(BlendedPixel(rare.0, over: rare.1, coverage: coverage(level: level)))
        }
        let roomy = builder.build(capacity: 20, reservingTransparency: false, coordinates: srgb)
        #expect(roomy.colours.count == 20)
        #expect(roomy.shown(BlendedPixel(common.0, over: common.1, coverage: coverage(level: 7))) == grey(7 * 17))
        // Level 7 of the rare ramp is shown at level 5, the nearest of 0, 5, 10, 15.
        #expect(roomy.shown(BlendedPixel(rare.0, over: rare.1, coverage: coverage(level: 7)))
                == BlendedPixel.blend(rare.0, over: rare.1, coverage: 5 * 17))

        // A table of 10: the rare ramp is down to its ends (4 + 14), then
        // the common one to every third level (4 + 4).
        let tight = builder.build(capacity: 10, reservingTransparency: false, coordinates: srgb)
        #expect(tight.colours.count == 8 && tight.approximations.isEmpty)
        #expect(tight.shown(BlendedPixel(rare.0, over: rare.1, coverage: coverage(level: 7))) == rare.1)
        #expect(tight.shown(BlendedPixel(rare.0, over: rare.1, coverage: coverage(level: 8))) == rare.0)
        #expect(tight.shown(BlendedPixel(common.0, over: common.1, coverage: coverage(level: 7))) == grey(6 * 17))
    }

    @Test func pastTheTableTheLeastUsedColoursAreShownAsTheirNearest() {
        // A 300-colour gradient, each drawn once more than the one before:
        // the 45 least used have stand-ins, each its nearest kept colour.
        var builder = IndexedPaletteBuilder()
        let gradient = (0..<300).map { (index: Int) -> RGBA in
            let step = index * 255 / 299
            return RGBA(UInt8(step), UInt8(255 - step), UInt8(index % 2))
        }
        for (index, colour) in gradient.enumerated() { builder.add(.solid(colour), count: index + 1) }
        let palette = builder.build(capacity: 255, reservingTransparency: true, coordinates: srgb)
        #expect(palette.colours.count == 256)
        #expect(palette.approximations.count == 45)
        #expect(Set(palette.approximations.map(\.colour)) == Set(gradient.prefix(45)))
        for approximation in palette.approximations {
            #expect(gradient.dropFirst(45).contains(approximation.standIn))
            #expect(palette.shown(.solid(approximation.colour)) == approximation.standIn)
        }
        // The kept colour nearest the most-used stand-in-needing one is the
        // gradient's next step.
        let last = palette.approximations.first { $0.colour == gradient[44] }
        #expect(last?.standIn == gradient[45] || last?.standIn == gradient[46])
        #expect(palette.approximations.map(\.pixels).reduce(0, +) == (1...45).reduce(0, +))
    }

    @Test func anEdgeIsShadedInSixteenLevels() {
        #expect(IndexedPaletteBuilder.level(0) == 0)
        #expect(IndexedPaletteBuilder.level(8) == 0 && IndexedPaletteBuilder.level(9) == 1)
        #expect(IndexedPaletteBuilder.level(246) == 14 && IndexedPaletteBuilder.level(247) == 15)
        #expect(IndexedPaletteBuilder.quantised(7, stride: 3) == 6 && IndexedPaletteBuilder.quantised(8, stride: 15) == 15)
    }
}

@Suite("Exact indexed images and shrunk glyphs")
struct BlendCanvasTests {

    @Test func aCanvasOfAtMost256ColoursIsIndexedUnchanged() throws {
        var canvas = PixelCanvas(width: 16, height: 16)
        for y in 0..<16 {
            for x in 0..<16 { canvas[x, y] = RGBA(UInt8(x * 16), UInt8(y * 16), 9) }
        }
        let image = try #require(IndexedImage(exactly: canvas))
        #expect(image.palette.count == 256)
        for y in 0..<16 {
            for x in 0..<16 { #expect(image.palette[Int(image.indices[y * 16 + x])] == canvas[x, y]) }
        }
        var more = PixelCanvas(width: 257, height: 1)
        for x in 0..<257 { more[x, 0] = RGBA(UInt8(x % 256), UInt8(x / 256), 0) }
        #expect(IndexedImage(exactly: more) == nil)
    }

    @Test func blendingOverABlendedPixelBlendsOverWhatItShows() {
        var canvas = BlendCanvas(width: 1, height: 1, fill: RGBA(0, 0, 0))
        canvas.blend(RGBA(255, 255, 255), coverage: 128, x: 0, y: 0)
        canvas.blend(RGBA(255, 0, 0), coverage: 128, x: 0, y: 0)
        #expect(canvas[0, 0] == BlendedPixel(RGBA(255, 0, 0), over: RGBA(128, 128, 128), coverage: 128))
        canvas.composite(premultiplied: RGBA(0, 0, 128, 128), x: 0, y: 0)
        #expect(canvas[0, 0].isSolid)
        // Off the canvas, nothing happens.
        canvas.blend(RGBA(1, 2, 3), coverage: 255, x: 5, y: 0)
        canvas.fill(x: -3, y: -3, width: 2, height: 2, with: RGBA(1, 2, 3))
        #expect(canvas.pixelCanvas[0, 0] == canvas[0, 0].colour)
    }

    @Test func aShrunkGlyphAveragesTheAreaEachPixelCovers() {
        let solid = GlyphBitmap(width: 4, height: 2, left: 0, top: -2, advance: 4,
                                pixels: .coverage([UInt8](repeating: 255, count: 8)))
        let half = solid.scaled(by: 1, over: 2)
        #expect((half.width, half.height, half.left, half.top, half.advance) == (2, 1, 0, -1, 2))
        #expect(half.pixels == .coverage([255, 255]))
        // One pixel at x 1 of a glyph halved covers a quarter of pixel 0.
        let dot = GlyphBitmap(width: 1, height: 1, left: 1, top: 1, advance: 2, pixels: .coverage([255]))
        let small = dot.scaled(by: 1, over: 2)
        #expect((small.width, small.height, small.left, small.top) == (1, 1, 0, 0))
        #expect(small.pixels == .coverage([64]))
        #expect(dot.scaled(by: 3, over: 3) == dot)
    }
}
