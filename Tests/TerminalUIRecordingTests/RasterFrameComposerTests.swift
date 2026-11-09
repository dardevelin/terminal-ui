import Foundation
import Testing
import TerminalUI
import TerminalUIConfig
import TerminalUIRaster
@testable import TerminalUIRecording

// Recorded screens as PNG stills and GIF animations, byte for byte: the
// hand-written logs in Fixtures/ and the files they render to, the same on
// macOS and Linux. tools/tests/test_raster_encoders.py decodes the files by
// means of its own.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// JetBrains Mono's four files, from `tools/fonts/JetBrainsMono/` in the
/// checkout: in no target, so found from this file's own path.
private enum BundledFont {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/fonts/JetBrainsMono")

    static func font(_ name: String) throws -> TrueTypeFont {
        try TrueTypeFont(bytes: [UInt8](Data(contentsOf: directory.appendingPathComponent("JetBrainsMono-\(name).ttf"))))
    }

    static func fontSet() throws -> FontSet {
        FontSet(regular: try font("Regular"), bold: try font("Bold"), italic: try font("Italic"),
                boldItalic: try font("BoldItalic"))
    }
}

private func metrics(scale: Int) -> CellMetrics {
    CellMetrics(fontSize: 15, advance: CellMetrics.jetBrainsMonoAdvance, scale: scale)
}

/// A composer at the docs' metrics: text in the bundled font, or none.
private func composer(scale: Int = 1, text: Bool = true) throws -> RasterFrameComposer {
    let glyphs: [any GlyphSource] = text
        ? [BuiltinGlyphSource(fonts: try BundledFont.fontSet(), size: GlyphSize(pixelsPerEm: 15, scale: scale))] : []
    return RasterFrameComposer(metrics: metrics(scale: scale), palette: .catppuccinMocha, glyphs: glyphs)
}

private func log(_ name: String) throws -> RecordingReader {
    try RecordingReader(bytes: try Data(contentsOf: fixtures.appendingPathComponent("\(name).tuirec")))
}

private func log(lines: [String]) throws -> RecordingReader {
    try RecordingReader(bytes: Array(lines.joined(separator: "\n").utf8))
}

/// The screen at the log's first mark.
private func screen(_ log: RecordingReader) throws -> RecordingReader.Screen {
    let frame = try PresentationClock(mode: .script).timeline(of: log, range: .at(log.marks[0].label)).frames[0].frame
    return try #require(log.screens.first { $0.index == frame })
}

/// Compares `bytes` with the committed golden `name`; with
/// `TERMINALUI_UPDATE_GOLDENS=1` it writes the golden instead, for a change
/// meant to alter the picture — look at it before committing.
private func expectGolden(_ bytes: [UInt8], named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = fixtures.appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["TERMINALUI_UPDATE_GOLDENS"] == "1" {
        try Data(bytes).write(to: url)
        return
    }
    let golden = try [UInt8](Data(contentsOf: url))
    #expect(bytes == golden, "\(name): \(bytes.count) bytes against a golden of \(golden.count)",
            sourceLocation: sourceLocation)
}

private let ground = RecordingPalette.catppuccinMocha.background.rgba
private let cyan = RecordingPalette.catppuccinMocha.ansi[6].rgba

@Suite("The raster composer")
struct RasterFrameComposerTests {

    // MARK: - Shapes

    @Test(arguments: [1, 2])
    func shapesRenderToTheirGolden(scale: Int) throws {
        let still = try composer(scale: scale, text: false).still(try screen(log("shapes")), frameNumber: 1)
        try expectGolden(still.bytes, named: scale == 1 ? "shapes.png" : "shapes@2x.png")
        #expect(still.missing.isEmpty)
    }

    @Test(arguments: [1, 2])
    func aStretchedRunOfLinesCoversThePixelsTheSVGsUseDoes(scale: Int) throws {
        let screen = try screen(log("shapes"))
        let frame = try composer(scale: scale, text: false).compose(screen.buffer, windowBackground: nil)
        let cell = (width: 9 * scale, height: 18 * scale, padding: 12 * scale)
        let line = try #require(GlyphGeometry.shape(for: Unicode.Scalar("─")))
        let glyph = DeviceGlyph(line, cellWidth: cell.width, cellHeight: cell.height)
        guard case .rect(let x, let y, let width, let height) = try #require(glyph.marks.first).figure else {
            Issue.record("─ is a rectangle")
            return
        }
        #expect(glyph.marks.count == 1 && x == 0 && width == cell.width && glyph.spansWidth)
        // The SVG draws ── (columns 1 and 2 of the top row, cyan) as one
        // `<use>` two cells wide of a symbol stretched on x alone: its rect
        // then covers rows y..<y + height across both cells' whole width.
        let left = cell.padding + cell.width, top = cell.padding
        let svg = SVGFrameRenderer(metrics: metrics(scale: scale), palette: .catppuccinMocha)
            .render(screen.buffer, windowBackground: nil, title: "shapes")
        #expect(svg.contains("<symbol id=\"u2500\" viewBox=\"0 0 \(cell.width) \(cell.height)\" preserveAspectRatio=\"none\">"
            + "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(width)\" height=\"\(height)\"/></symbol>"))
        #expect(svg.contains("<use href=\"#u2500\" x=\"\(left)\" y=\"\(top)\" width=\"\(2 * cell.width)\""
            + " height=\"\(cell.height)\" fill=\"#94e2d5\"/>"))
        // The raster draws the glyph in each cell: the same pixels.
        for row in y..<(y + height) {
            for column in 0..<(2 * cell.width) {
                #expect(frame.canvas[left + column, top + row].colour == cyan)
            }
        }
        for column in 0..<(2 * cell.width) {
            #expect(frame.canvas[left + column, top + y - 1].colour == ground)
            #expect(frame.canvas[left + column, top + y + height].colour == ground)
        }
    }

    @Test(arguments: [1, 2])
    func aStretchedRunOfBlocksCoversThePixelsTheSVGsUseDoes(scale: Int) throws {
        // A run of one block glyph is one `<use>` across it in the SVG; its
        // stretched rect covers exactly the pixels each cell's own does.
        var buffer = CellBuffer(width: 4, height: 1)
        let style = Style(foreground: .cyan, background: nil, bold: false, italic: false, underline: false)
        for column in 0..<3 { buffer[column, 0] = Cell(character: "▀", style: style) }
        let frame = try composer(scale: scale, text: false).compose(buffer, windowBackground: nil)
        let svg = SVGFrameRenderer(metrics: metrics(scale: scale), palette: .catppuccinMocha)
            .render(buffer, windowBackground: nil, title: "blocks")
        let cell = (width: 9 * scale, height: 18 * scale, padding: 12 * scale)
        #expect(svg.contains("<use href=\"#u2580\" x=\"\(cell.padding)\" y=\"\(cell.padding)\" width=\"\(3 * cell.width)\""))
        for row in 0..<cell.height {
            for column in 0..<(4 * cell.width) {
                let inked = column < 3 * cell.width && row < cell.height / 2
                #expect((frame.canvas[cell.padding + column, cell.padding + row].colour == cyan) == inked,
                        "(\(column), \(row))")
            }
        }
    }

    @Test(arguments: [1, 2])
    func bordersJoinAcrossCells(scale: Int) throws {
        let frame = try composer(scale: scale, text: false).compose(try screen(log("shapes")).buffer, windowBackground: nil)
        let (cellWidth, cellHeight, padding) = (9 * scale, 18 * scale, 12 * scale)
        // Down the left edge, │ in row 1 meets ╭ above and ├ below without a
        // gap: the column through its stroke is cyan from row 0's middle to
        // row 2's.
        let line = try #require(GlyphGeometry.shape(for: Unicode.Scalar("│")))
        let stroke = try #require(DeviceGlyph(line, cellWidth: cellWidth, cellHeight: cellHeight).marks.first)
        guard case .rect(let strokeX, _, _, _) = stroke.figure else { return }
        for y in (padding + cellHeight)..<(padding + 2 * cellHeight) {
            #expect(frame.canvas[padding + strokeX, y].colour == cyan, "row \(y)")
        }
        #expect(frame.canvas[padding + strokeX, padding + cellHeight - 1].colour == cyan)
        #expect(frame.canvas[padding + strokeX, padding + 2 * cellHeight].colour == cyan)
    }

    @Test(arguments: [1, 2])
    func aBrailleDotIsDrawnWhereItsDeviceGlyphPutsIt(scale: Int) throws {
        let frame = try composer(scale: scale, text: false).compose(try screen(log("shapes")).buffer, windowBackground: nil)
        let (cellWidth, cellHeight, padding) = (9 * scale, 18 * scale, 12 * scale)
        // ⣿ is row 1, column 1: all eight dots.
        let glyph = DeviceGlyph(try #require(GlyphGeometry.shape(for: Unicode.Scalar("⣿"))), cellWidth: cellWidth, cellHeight: cellHeight)
        #expect(glyph.marks.count == 8)
        let (left, top) = (padding + cellWidth, padding + cellHeight)
        for mark in glyph.marks {
            guard case .circle(let centre, _) = mark.figure else {
                Issue.record("a braille dot is a circle")
                continue
            }
            let pixel = frame.canvas[left + centre.x / SubpixelPoint.perPixel, top + centre.y / SubpixelPoint.perPixel]
            #expect(pixel.foreground == cyan && pixel.coverage > 128, "the dot at \(centre)")
        }
        // Between the two columns of dots, on the cell's centre line, is
        // the ground.
        #expect(frame.canvas[left + cellWidth / 2, top + cellHeight / 8].colour == ground)
    }

    @Test func aShadeIsTheForegroundOverTheBackgroundAtItsOpacity() throws {
        let frame = try composer(text: false).compose(try screen(log("shapes")).buffer, windowBackground: nil)
        // ░ (row 0, column 9) is a quarter of the pink over idx:236.
        let pink = RGBA(0xF3, 0x8B, 0xA8), grey = RGBA(0x30, 0x30, 0x30)
        let pixel = frame.canvas[12 + 9 * 9 + 4, 12 + 9]
        #expect(pixel == BlendedPixel(pink, over: grey, coverage: 64))
        #expect(pixel.colour == BlendedPixel.blend(pink, over: grey, coverage: 64))
    }

    // MARK: - Text

    @Test(arguments: [1, 2])
    func styledTextRendersToItsGolden(scale: Int) throws {
        let still = try composer(scale: scale).still(try screen(log("styles")), frameNumber: 1)
        try expectGolden(still.bytes, named: scale == 1 ? "styles.png" : "styles@2x.png")
        #expect(still.missing.isEmpty)
        // 16 × 9 + 2 × 12 by 2 × 18 + 2 × 12, at the scale.
        #expect((still.width, still.height) == (168 * scale, 60 * scale))
    }

    @Test func textIsAntiAliasedBetweenTheCellsColours() throws {
        let frame = try composer().compose(try screen(log("styles")).buffer, windowBackground: Color.rgb(0x10, 0x10, 0x20))
        let mauve = RGBA(0xCB, 0xA6, 0xF7), window = RGBA(0x10, 0x10, 0x20)
        // "Bold" is the first four cells of row 0: its pixels are the
        // mauve over the window, from not at all to fully.
        var levels: Set<UInt8> = []
        for y in 12..<30 {
            for x in 12..<(12 + 4 * 9) {
                let pixel = frame.canvas[x, y]
                #expect(pixel.colour == window || pixel.foreground == mauve, "(\(x), \(y))")
                if pixel.foreground == mauve { levels.insert(pixel.coverage) }
            }
        }
        #expect(levels.contains(.max) && levels.count > 8, "the ink's edge is shaded: \(levels.sorted())")
    }

    @Test func anUnderlineIsARowOfPixelsTwoBelowTheBaseline() throws {
        let frame = try composer().compose(try screen(log("styles")).buffer, windowBackground: nil)
        // "under" is columns 8–12 of row 0, red, underlined: the baseline
        // is 14 below the row's top, the underline 2 below that.
        let red = RecordingPalette.catppuccinMocha.ansi[1].rgba
        for x in (12 + 8 * 9)..<(12 + 13 * 9) {
            #expect(frame.canvas[x, 12 + 14 + 2].colour == red, "column \(x)")
        }
        #expect(frame.canvas[12 + 13 * 9, 12 + 14 + 2].colour != red)
    }

    @Test func aWideGlyphNoFontHasIsABoxOverItsTwoCellsAndReported() throws {
        let still = try composer().still(try screen(log("wide")), frameNumber: 1)
        #expect(still.missing.lines == ["U+754C 界 in frame 1", "U+9762 面 in frame 1"])
        let frame = try composer().compose(try screen(log("wide")).buffer, windowBackground: nil)
        #expect(frame.missing == ["界", "面"])
        // The box's left side is in the first cell and its right side in
        // the second: the continuation draws nothing of its own.
        let yellow = RecordingPalette.catppuccinMocha.ansi[3].rgba
        let row = 12 + 9
        let inked = (12..<(12 + 18)).filter { frame.canvas[$0, row].foreground == yellow }
        #expect(inked.first.map { $0 < 12 + 9 } == true && inked.last.map { $0 >= 12 + 9 } == true, "\(inked)")
    }

    // MARK: - Missing glyphs

    @Test func failRefusesNamingEachCharacterAndItsFrames() throws {
        var missing = MissingGlyphs()
        missing.add("界", frame: 3)
        missing.add("界", frame: 3)
        missing.add("界", frame: 7)
        missing.add("🦊", frame: 7)
        #expect(missing.lines == ["U+754C 界 in frames 3, 7", "U+1F98A 🦊 in frame 7"])
        #expect(throws: MissingGlyphError.self) { try MissingGlyphPolicy.fail.outcome(of: missing) }
        do {
            _ = try MissingGlyphPolicy.fail.outcome(of: missing)
        } catch {
            #expect(error.message.contains("U+754C 界 in frames 3, 7") && error.message.contains("U+1F98A"))
        }
    }

    @Test func boxWarnsAndSystemSaysItHasNoCascadeYet() throws {
        var missing = MissingGlyphs()
        missing.add("界", frame: 1)
        let box = try MissingGlyphPolicy.box.outcome(of: missing)
        #expect(box.count == 1 && box[0].contains("drawn as boxes") && box[0].contains("U+754C"))
        let system = try MissingGlyphPolicy.system.outcome(of: missing)
        #expect(system.count == 1 && system[0].contains("system font cascade is not available"))
        for policy in MissingGlyphPolicy.allCases {
            #expect(try policy.outcome(of: MissingGlyphs()).isEmpty)
        }
    }

    @Test func aFallbackFontDrawsWhatTheFirstLacks() throws {
        struct OnlyX: GlyphSource {
            func glyph(_ character: Character, style: FontStyle) -> GlyphBitmap? {
                character == "界" ? GlyphBitmap(width: 1, height: 1, left: 0, top: -1, advance: 9, pixels: .coverage([255]))
                    : nil
            }
        }
        let fonts = try BundledFont.fontSet()
        let composer = RasterFrameComposer(
            metrics: metrics(scale: 1), palette: .catppuccinMocha,
            glyphs: [BuiltinGlyphSource(fonts: fonts, size: GlyphSize(pixelsPerEm: 15)), OnlyX()])
        let frame = composer.compose(try screen(log("wide")).buffer, windowBackground: nil)
        #expect(frame.missing == ["面"])
    }

    @Test func aGlyphWiderThanItsCellsIsShrunkToFit() throws {
        struct Wide: GlyphSource {
            func glyph(_ character: Character, style: FontStyle) -> GlyphBitmap? {
                GlyphBitmap(width: 18, height: 2, left: 0, top: -2, advance: 18,
                            pixels: .coverage([UInt8](repeating: 255, count: 36)))
            }
        }
        let composer = RasterFrameComposer(metrics: metrics(scale: 1), palette: .catppuccinMocha, glyphs: [Wide()])
        var buffer = CellBuffer(width: 3, height: 1)
        buffer[1, 0] = Cell(character: "W", style: .plain)
        let frame = composer.compose(buffer, windowBackground: nil)
        let baseline = 12 + 14
        let inked = (0..<frame.canvas.width).filter { frame.canvas[$0, baseline - 1].colour != ground }
        #expect(inked == Array((12 + 9)..<(12 + 18)), "\(inked)")
    }

    // MARK: - Animation

    @Test func threeFramesAnimateToTheirGolden() throws {
        let reader = try log("typing")
        let timeline = try PresentationClock(mode: .script).timeline(of: reader)
        let gif = try RasterAnimator(composer: try composer()).animate(reader, timeline: timeline)
        try expectGolden(gif.bytes, named: "typing.gif")
        #expect(gif.frames == 3 && gif.missing.isEmpty && gif.warnings.isEmpty)
        #expect((gif.width, gif.height) == (20 * 9 + 24, 3 * 18 + 24))
        #expect(Array(gif.bytes.prefix(6)) == Array("GIF89a".utf8))
        #expect(gif.bytes.firstRange(of: Array("NETSCAPE2.0".utf8)) != nil)
        // Its last screen as a still, for the oracle to compare the GIF with.
        let last = try #require(reader.screens.first { $0.index == 2 })
        try expectGolden(try composer().still(last, frameNumber: 3).bytes, named: "typing-ready.png")
    }

    @Test func theLastFrameHoldsForTheLoopPause() throws {
        let reader = try log("typing")
        let timeline = try PresentationClock(mode: .script).timeline(of: reader)
        let delays = timeline.gifDelays().map(\.centiseconds)
        let gif = try RasterAnimator(composer: try composer(), loopPause: 2_000).animate(reader, timeline: timeline)
        #expect(graphicControlDelays(gif.bytes) == Array(delays.dropLast()) + [delays.last! + 200])
    }

    @Test func aFrameThatChangesNoPixelAddsItsTimeToTheOneBefore() throws {
        // Frame 2 names the palette's own foreground for the default one:
        // another style, the same pixels.
        let reader = try log(lines: [
            #"{"tuirec":1,"cols":2,"rows":1,"cursor":"hidden","app":"same","env":{}}"#,
            #"{"style":0,"fg":null,"bg":null}"#,
            #"{"t":0,"frame":1,"rows":[[0,[[0,"ab"]]]]}"#,
            #"{"t":0,"mark":"one","hold":300}"#,
            #"{"style":1,"fg":"rgb:cdd6f4","bg":null}"#,
            #"{"t":10,"frame":2,"rows":[[0,[[1,"ab"]]]]}"#,
            #"{"t":20,"mark":"two","hold":200}"#,
            #"{"t":30,"end":true,"frames":2,"marks":2}"#,
        ])
        let gif = try RasterAnimator(composer: try composer(), loopPause: 0)
            .animate(reader, timeline: try PresentationClock(mode: .script).timeline(of: reader))
        #expect(gif.frames == 1)
        #expect(graphicControlDelays(gif.bytes) == [50])
    }

    // MARK: - Colour tables

    @Test func moreExactColoursThanOneTableHoldsGoToLocalTables() throws {
        // Two frames of 200 background colours each: 400 in all, which no
        // global table holds, and 200 a frame, which a local one does.
        let reader = try log(lines: colourfulSession(columns: 20, rows: 10, frames: 2))
        let gif = try RasterAnimator(composer: try composer(text: false))
            .animate(reader, timeline: try PresentationClock(mode: .script).timeline(of: reader))
        #expect(gif.frames == 2 && gif.warnings.isEmpty)
        let globalTableFlag: UInt8 = 0x80
        #expect(gif.bytes[10] & globalTableFlag == 0, "the GIF has a global table")
        #expect(imageDescriptorFlags(gif.bytes).allSatisfy { $0 & globalTableFlag != 0 }, "a frame has no local table")
    }

    @Test func aFrameOfMoreColoursThanATableHoldsIsWarnedAbout() throws {
        // A 300-colour gradient: the 45 least-used colours are drawn as
        // their nearest in Oklab, and the warning names the frame.
        let reader = try log(lines: colourfulSession(columns: 30, rows: 10, frames: 1))
        let gif = try RasterAnimator(composer: try composer(text: false))
            .animate(reader, timeline: try PresentationClock(mode: .script).timeline(of: reader))
        #expect(gif.warnings.count == 1)
        #expect(gif.warnings.first?.contains("frame 1 drew 46 colours") == true, "\(gif.warnings)")
    }

    @Test func oklabCoordinatesAreTheFrameworksOwn() {
        let white = RasterAnimator.oklab(RGBA(255, 255, 255))
        #expect(abs(white.0 - 1_000_000) <= 1 && abs(white.1) <= 1 && abs(white.2) <= 1)
        let black = RasterAnimator.oklab(RGBA(0, 0, 0))
        #expect(black == (0, 0, 0))
    }
}

// MARK: - Logs and GIF fields

/// A session of `frames` frames, each giving every cell a background of its
/// own: a gradient through red and green, different in each frame.
private func colourfulSession(columns: Int, rows: Int, frames: Int) -> [String] {
    var lines = [#"{"tuirec":1,"cols":\#(columns),"rows":\#(rows),"cursor":"hidden","app":"colours","env":{}}"#]
    let cells = columns * rows
    for frame in 0..<frames {
        var rowsJSON: [String] = []
        for y in 0..<rows {
            var runs: [String] = []
            for x in 0..<columns {
                let index = frame * cells + y * columns + x
                lines.append(#"{"style":\#(index),"fg":null,"bg":"rgb:\#(hex(index * 251 % 256))\#(hex(index / 3 % 256))40"}"#)
                runs.append(#"[\#(index)," "]"#)
            }
            rowsJSON.append("[\(y),[\(runs.joined(separator: ","))]]")
        }
        lines.append(#"{"t":\#(frame * 1000),"frame":\#(frame + 1),"rows":[\#(rowsJSON.joined(separator: ","))]}"#)
        lines.append(#"{"t":\#(frame * 1000 + 1),"mark":"m\#(frame)","hold":500}"#)
    }
    lines.append(#"{"t":\#(frames * 1000),"end":true,"frames":\#(frames),"marks":\#(frames)}"#)
    return lines
}

private func hex(_ value: Int) -> String {
    let digits = String(value, radix: 16)
    return digits.count == 1 ? "0" + digits : digits
}

/// The blocks after a GIF's header and tables, walked as GIF89a lays them
/// out, calling `body` with each block's introducer, label and offset.
private func walkBlocks(_ gif: [UInt8], _ body: (UInt8, Int) -> Void) {
    let packed = gif[10]
    var offset = 13 + (packed & 0x80 != 0 ? 3 * (2 << (packed & 7)) : 0)
    func skipSubBlocks() {
        while gif[offset] != 0 { offset += 1 + Int(gif[offset]) }
        offset += 1
    }
    while offset < gif.count, gif[offset] != 0x3B {
        body(gif[offset], offset)
        if gif[offset] == 0x21 {
            offset += 2
            skipSubBlocks()
        } else {
            let flags = gif[offset + 9]
            offset += 10 + (flags & 0x80 != 0 ? 3 * (2 << (flags & 7)) : 0) + 1
            skipSubBlocks()
        }
    }
}

private func graphicControlDelays(_ gif: [UInt8]) -> [Int] {
    var delays: [Int] = []
    walkBlocks(gif) { introducer, offset in
        if introducer == 0x21, gif[offset + 1] == 0xF9 { delays.append(Int(gif[offset + 4]) | Int(gif[offset + 5]) << 8) }
    }
    return delays
}

private func imageDescriptorFlags(_ gif: [UInt8]) -> [UInt8] {
    var flags: [UInt8] = []
    walkBlocks(gif) { introducer, offset in
        if introducer == 0x2C { flags.append(gif[offset + 9]) }
    }
    return flags
}
