import Foundation
import Testing
import TerminalUI
import TerminalUIConfig
@testable import TerminalUIRecording

// A recording as an animated SVG, byte for byte: hand-written logs in
// Fixtures/ and the documents they render to, the same on macOS and Linux.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

private func reader(_ name: String) throws -> RecordingReader {
    try RecordingReader(bytes: try Data(contentsOf: fixtures.appendingPathComponent("\(name).tuirec")))
}

private let docsMetrics = CellMetrics(fontSize: 15, advance: CellMetrics.jetBrainsMonoAdvance)

/// The whole log, on the script clock, at the docs' metrics.
private func animate(_ log: RecordingReader, loopPause: Int = SVGAnimationRenderer.defaultLoopPause,
                     font: SVGEmbeddedFont? = nil) throws -> String {
    let timeline = try PresentationClock(mode: .script).timeline(of: log)
    let frames = SVGFrameRenderer(metrics: docsMetrics, palette: .catppuccinMocha, embeddedFont: font)
    return SVGAnimationRenderer(frames: frames, loopPause: loopPause).render(log, timeline: timeline,
                                                                              title: log.header.app)
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

/// The lines of `svg` that start with `prefix`.
private func lines(_ svg: String, startingWith prefix: String) -> [Substring] {
    svg.split(separator: "\n").filter { $0.hasPrefix(prefix) }
}

/// The body of the element `<g id="id">`, up to its `</g>`.
private func group(_ id: String, in svg: String) -> String? {
    guard let start = svg.range(of: "<g id=\"\(id)\">\n"),
          let end = svg.range(of: "\n</g>", range: start.upperBound..<svg.endIndex) else { return nil }
    return String(svg[start.upperBound..<end.lowerBound])
}

/// A log of `rows` rows of 4 columns: one frame a screen, each held 1 s.
private func log(_ screens: [(windowBg: String?, rows: [String])]) throws -> RecordingReader {
    var text = #"{"tuirec":1,"cols":4,"rows":2,"cursor":"hidden","app":"made","env":{}}"# + "\n"
        + #"{"style":0,"fg":null,"bg":null}"# + "\n"
    for (index, screen) in screens.enumerated() {
        let rows = screen.rows.enumerated().map { #"[\#($0.offset),[[0,"\#($0.element)"]]]"# }.joined(separator: ",")
        let background = screen.windowBg.map { #","windowBg":"\#($0)""# } ?? ""
        text += #"{"t":\#(index * 10_000),"frame":\#(index + 1)\#(background),"rows":[\#(rows)]}"# + "\n"
        text += #"{"t":\#(index * 10_000 + 1),"mark":"m\#(index)","hold":1000}"# + "\n"
    }
    return try RecordingReader(bytes: Array(text.utf8))
}

@Suite("The SVG animation renderer")
struct SVGAnimationRendererTests {

    @Test func threeFramesRenderToTheirGolden() throws {
        try expectGolden(try animate(try reader("animation")), named: "animation.svg")
    }

    @Test func aRenderIsTheSameBytesEveryTime() throws {
        let first = try animate(try reader("animation"))
        #expect(try animate(try reader("animation")) == first)
        #expect(try animate(try reader("animation")) == first)
    }

    @Test func eachPresentedFrameIsOneGroup() throws {
        let svg = try animate(try reader("animation"))
        #expect(lines(svg, startingWith: "<g id=\"f").map { $0.prefix(9) } == ["<g id=\"f0", "<g id=\"f1", "<g id=\"f2"])
        // The first draws every row; a later one only the rows that changed,
        // each covered first, across the canvas, in the terminal's ground.
        #expect(try #require(group("f0", in: svg)).split(separator: "\n").count == 3)
        let second = try #require(group("f1", in: svg)).split(separator: "\n")
        #expect(second.first == ##"<rect x="0" y="30" width="132" height="36" fill="#1e1e2e" shape-rendering="crispEdges"/>"##)
        #expect(second.count == 3)
    }

    @Test func keyframesAreTheMillisecondsOfTheLoopAndTheLastFrameHoldsThroughThePause() throws {
        // Frames at 0, 1000 and 2000 ms of a 3000 ms timeline; with the
        // 1.5 s pause the loop is 4500 ms, the last frame shown from 2000
        // to its end.
        let svg = try animate(try reader("animation"))
        #expect(lines(svg, startingWith: "@keyframes") == [
            "@keyframes k1{0%{visibility:hidden}22.222%{visibility:visible}}",
            "@keyframes k2{0%{visibility:hidden}44.444%{visibility:visible}}",
        ])
        #expect(lines(svg, startingWith: "#f") == [
            "#f1{animation:k1 4500ms step-end infinite}",
            "#f2{animation:k2 4500ms step-end infinite}",
        ])
        let unpaused = try animate(try reader("animation"), loopPause: 0)
        #expect(unpaused.contains("33.333%{visibility:visible}") && unpaused.contains("66.667%{visibility:visible}"))
        #expect(unpaused.contains("3000ms step-end infinite"))
    }

    @Test func aPercentageIsPlacedFromItsOwnMillisecond() {
        // A third of a second, nine times over: each from its own time, so
        // the ninth is where 3 s falls, not nine roundings later.
        let placed = (1...9).map { SVGAnimationRenderer.percentage($0 * 333, of: 10_000) }
        #expect(placed == ["3.330%", "6.660%", "9.990%", "13.320%", "16.650%", "19.980%", "23.310%", "26.640%", "29.970%"])
        #expect(SVGAnimationRenderer.percentage(1, of: 3) == "33.333%")
        #expect(SVGAnimationRenderer.percentage(2, of: 3) == "66.667%")
        // Never 0%, which would show a later frame as the loop starts, nor
        // past the end.
        #expect(SVGAnimationRenderer.percentage(1, of: 1_000_000) == "0.001%")
        #expect(SVGAnimationRenderer.percentage(5, of: 5) == "100.000%")
    }

    @Test func reducedMotionAndNoAnimationShowTheLastFrame() throws {
        let svg = try animate(try reader("animation"))
        #expect(svg.contains("@media (prefers-reduced-motion: reduce){g{animation:none!important}}"))
        // Nothing is hidden but by an animation: without one every group
        // shows, and the last, painted last, is on top.
        #expect(svg.components(separatedBy: "visibility:hidden").count - 1 == 2)
        #expect(!svg.contains("visibility=") && !svg.contains("display=") && !svg.contains("opacity:0"))
        #expect(svg.contains("where animation is off or motion is reduced, it shows its last frame"))
    }

    @Test func aRecurringRowIsDefinedOnce() throws {
        let svg = try animate(try reader("animation"))
        // The last frame is the first again below its title: its two rows
        // are the first frame's definitions, placed a second time. Five
        // rows were drawn in all.
        #expect(lines(svg, startingWith: "<g id=\"r").count == 5)
        #expect(group("f2", in: svg)?.hasSuffix("<use href=\"#r1\" y=\"30\"/>\n<use href=\"#r2\" y=\"48\"/>") == true)
        #expect(svg.components(separatedBy: "<use href=\"#r1\" y=\"30\"/>").count - 1 == 2)
        // A row placed anywhere on the screen is the same definition.
        let moved = try animate(try log([(nil, ["ab  ", "    "]), (nil, ["    ", "ab  "])]))
        #expect(lines(moved, startingWith: "<g id=\"r").count == 1)
        #expect(moved.contains("<use href=\"#r0\" y=\"12\"/>") && moved.contains("<use href=\"#r0\" y=\"30\"/>"))
    }

    @Test func aNewWindowBackgroundRepaintsTheWholeCanvas() throws {
        let svg = try animate(try log([("rgb:101020", ["ab  ", "cd  "]), ("rgb:202010", ["ab  ", "cd  "])]))
        let second = try #require(group("f1", in: svg))
        #expect(second.hasPrefix(##"<rect x="0" y="0" width="60" height="60" fill="#202010" shape-rendering="crispEdges"/>"##))
        #expect(second.split(separator: "\n").count == 3)
        // An unchanged screen keeps its group, empty and never animated.
        let same = try animate(try log([(nil, ["ab  ", "    "]), (nil, ["ab  ", "    "])]))
        #expect(same.contains("<g id=\"f1\"/>") && !same.contains("@keyframes"))
        #expect(!same.contains("prefers-reduced-motion"))
    }

    @Test func aStillsRowsAreTheAnimationsRows() throws {
        // The first frame's text is drawn as the still draws it, shifted to
        // its row's own space.
        let log = try reader("animation")
        let screen = try #require(log.screens.first { $0.index == 0 })
        let still = SVGFrameRenderer(metrics: docsMetrics, palette: .catppuccinMocha)
            .render(screen.buffer, windowBackground: screen.windowBackground, title: "")
        let animation = try animate(log)
        #expect(still.contains(##"<text x="12" y="26" textLength="45" lengthAdjust="spacing" fill="#cba6f7" font-weight="700">Tasks</text>"##))
        #expect(animation.contains(##"<text x="12" y="14" textLength="45" lengthAdjust="spacing" fill="#cba6f7" font-weight="700">Tasks</text>"##))
        #expect(animation.contains("<use href=\"#r0\" y=\"12\"/>"))
    }

    @Test func anEmbeddedFontIsADataURLFaceFirstInTheStack() throws {
        let font = SVGEmbeddedFont(family: "Mono Test", faces: [
            .init(weight: SVGEmbeddedFont.regularWeight, trueType: Array("foob".utf8)),
            .init(weight: SVGEmbeddedFont.boldWeight, trueType: Array("fooba".utf8)),
        ])
        let svg = try animate(try reader("animation"), font: font)
        #expect(svg.contains(#"@font-face{font-family:"Mono Test";font-weight:400;src:url(data:font/ttf;base64,Zm9vYg==) format("truetype")}"#))
        #expect(svg.contains(#"@font-face{font-family:"Mono Test";font-weight:700;src:url(data:font/ttf;base64,Zm9vYmE=) format("truetype")}"#))
        #expect(svg.contains(#"font-family='"Mono Test","JetBrains Mono","SF Mono""#))
        // The still carries it the same way; without one, neither has a style.
        let screen = try #require(try reader("styles").screens.first { _ in true })
        let still = SVGFrameRenderer(metrics: docsMetrics, palette: .catppuccinMocha, embeddedFont: font)
            .render(screen.buffer, windowBackground: screen.windowBackground, title: "")
        #expect(still.contains("<style>\n@font-face{font-family:\"Mono Test\";font-weight:400;"))
        #expect(!(try animate(try reader("animation"))).contains("@font-face"))
    }

    @Test func base64IsRFC4648() {
        // RFC 4648 §10's test vectors.
        let vectors = ["": "", "f": "Zg==", "fo": "Zm8=", "foo": "Zm9v", "foob": "Zm9vYg==", "fooba": "Zm9vYmE=",
                       "foobar": "Zm9vYmFy"]
        for (input, output) in vectors {
            #expect(Base64.encoded(Array(input.utf8)) == output, "\(input)")
        }
        #expect(Base64.encoded([0xFB, 0xFF, 0xBF]) == "+/+/")
    }

    @Test func consecutiveRowsAreOneRun() {
        #expect(SVGAnimationRenderer.consecutiveRuns([1, 2, 3, 5, 7, 8]) == [1..<4, 5..<6, 7..<9])
        #expect(SVGAnimationRenderer.consecutiveRuns([]) == [])
    }
}
