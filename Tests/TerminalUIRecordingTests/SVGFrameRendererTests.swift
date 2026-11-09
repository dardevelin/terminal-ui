import Foundation
import Testing
import TerminalUI
import TerminalUIConfig
@testable import TerminalUIRecording

// A recorded screen as an SVG still, byte for byte: hand-written logs in
// Fixtures/ and the documents they render to, the same on macOS and Linux.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// The screen at the log's first mark, rendered at the docs' metrics.
private func render(_ name: String, scale: Int = 1, palette: RecordingPalette = .catppuccinMocha) throws -> String {
    let log = try RecordingReader(bytes: try Data(contentsOf: fixtures.appendingPathComponent("\(name).tuirec")))
    let frame = try PresentationClock(mode: .script).timeline(of: log, range: .at(log.marks[0].label)).frames[0].frame
    let screen = try #require(log.screens.first { $0.index == frame })
    let metrics = CellMetrics(fontSize: 15, advance: CellMetrics.jetBrainsMonoAdvance, scale: scale)
    return SVGFrameRenderer(metrics: metrics, palette: palette)
        .render(screen.buffer, windowBackground: screen.windowBackground, title: log.header.app)
}

/// Compares `svg` with the committed golden `name`; with
/// `TERMINALUI_UPDATE_GOLDENS=1` it writes the golden instead, for a change
/// meant to alter the picture — look at it before committing.
private func expectGolden(_ svg: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = fixtures.appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["TERMINALUI_UPDATE_GOLDENS"] == "1" {
        try Data(svg.utf8).write(to: url)
        return
    }
    let golden = try String(contentsOf: url, encoding: .utf8)
    #expect(svg == golden, "\(name) differs from its golden", sourceLocation: sourceLocation)
}

/// Every `<text>` element's content.
private func texts(_ svg: String) -> [String] {
    svg.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("<text "), let open = line.firstIndex(of: ">"),
              let close = line.range(of: "</text>") else { return nil }
        return String(line[line.index(after: open)..<close.lowerBound])
    }
}

@Suite("The SVG still renderer")
struct SVGFrameRendererTests {

    @Test(arguments: ["borders", "blocks", "braille", "wide", "styles", "chrome"])
    func aFixtureRendersToItsGolden(_ name: String) throws {
        try expectGolden(try render(name), named: "\(name).svg")
    }

    @Test func atScaleTwoEveryPixelIsTwo() throws {
        try expectGolden(try render("borders", scale: 2), named: "borders@2x.svg")
        #expect(try render("borders", scale: 2).hasPrefix(#"<svg xmlns="http://www.w3.org/2000/svg" width="246" height="192""#))
    }

    @Test func theCanvasIsTheCellsAndThePaddingInTheWindowsBackground() throws {
        let styles = try render("styles")
        // 16 × 9 + 2 × 12 by 2 × 18 + 2 × 12, in the background the app set.
        #expect(styles.hasPrefix(#"<svg xmlns="http://www.w3.org/2000/svg" width="168" height="60" viewBox="0 0 168 60">"#))
        #expect(styles.contains(##"<rect width="168" height="60" fill="#101020"/>"##))
        // A log that set none is on the palette's.
        #expect(try render("borders", palette: .xterm).contains(##"fill="#000000"/>"##))
    }

    @Test func aCellOnTheWindowsBackgroundDrawsNoRect() throws {
        // `styles` has one run on idx:24 and two cells on the window's own
        // colour, which the canvas already shows.
        let backgrounds = try render("styles").split(separator: "\n").filter {
            $0.hasPrefix("<rect x=") && $0.contains("height=\"18\"")
        }
        #expect(backgrounds == [##"<rect x="84" y="12" width="45" height="18" fill="#005f87"/>"##])
    }

    @Test func brailleAndBordersAreShapesNotText() throws {
        for name in ["braille", "borders", "blocks"] {
            let svg = try render(name)
            let drawnAsText = texts(svg).joined().unicodeScalars.filter {
                GlyphGeometry.shape(for: $0) != nil
            }
            #expect(drawnAsText.isEmpty, "\(name) sets \(String(String.UnicodeScalarView(drawnAsText))) as text")
        }
        let braille = try render("braille")
        #expect(braille.contains(##"<use href="#u28FF" x="39" y="12" width="9" height="18" fill="#a6e3a1"/>"##))
        // One symbol per glyph, however often it is used.
        #expect(try render("borders").components(separatedBy: #"<symbol id="u2500""#).count == 2)
    }

    @Test func aWideGlyphSpansTwoCellsAndItsContinuationNothing() throws {
        let wide = try render("wide")
        #expect(wide.contains(##"<text x="12" y="26" textLength="18" lengthAdjust="spacing" fill="#f9e2af">界</text>"##))
        #expect(wide.contains(##"<text x="30" y="26" textLength="18" lengthAdjust="spacing" fill="#f9e2af">面</text>"##))
        // A glyph outside Latin-1 is set alone at its cell; Latin-1 runs on.
        #expect(texts(wide) == ["界", "面", "é", "→", "ok"])
    }

    @Test func boldIsAWeightNotABrighterColour() throws {
        let styles = try render("styles")
        #expect(styles.contains(##"fill="#cba6f7" font-weight="700">Bold</text>"##))
        #expect(styles.contains("not a brighter colour"))
        #expect(styles.contains(#"font-style="italic">it</text>"#))
        // The underline: a pixel, two below the baseline, across its cells.
        #expect(styles.contains(##"<rect x="84" y="28" width="45" height="1" fill="#f38ba8"/>"##))
    }

    @Test func textIsEscapedForXML() throws {
        let styles = try render("styles")
        #expect(styles.contains("<title>styles &lt;&amp;&gt;</title>"))
        #expect(texts(styles).contains("a&lt;b&amp;c&gt;&quot;d&apos;"))
        #expect(SVGText.escaped("a\u{0}b\u{7}c\u{9F}d\u{FFFE}e\tf") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f")
        #expect(SVGText.escaped("界 é 👩‍💻") == "界 é 👩‍💻")
    }

    @Test func fractionsAreWrittenExactlyFromSixteenths() {
        #expect([72, 1, -7, 160, 0, 8].map(SVGNumber.subpixels) == ["4.5", "0.0625", "-0.4375", "10", "0", "0.5"])
        #expect([Proportion(1, 4), Proportion(1, 2), Proportion(3, 4), Proportion(1, 1)].map(SVGNumber.decimal)
                == ["0.25", "0.5", "0.75", "1"])
    }

    @Test func symbolIdsAreTheCodePoint() {
        #expect(SVGFrameRenderer.symbolID(0x2500) == "u2500")
        #expect(SVGFrameRenderer.symbolID(0x28FF) == "u28FF")
        #expect(SVGFrameRenderer.symbolID(0x1FB00) == "u1FB00")
    }

    @Test func aDecimalIsTheExactRatioItNames() {
        #expect(Proportion(decimal: "1.2") == Proportion(12, 10))
        #expect(Proportion(decimal: "0.6") == Proportion(6, 10))
        #expect(Proportion(decimal: "2") == Proportion(2, 1))
        for text in ["", "-1", "1e2", ".5", "1.", "1.2.3", "１", "1.1234567"] {
            #expect(Proportion(decimal: text) == nil, "\(text)")
        }
        #expect(CellMetrics(fontSize: 15, lineHeight: Proportion(decimal: "1.5")!,
                            advance: CellMetrics.jetBrainsMonoAdvance).cellHeight == 23)
    }
}
