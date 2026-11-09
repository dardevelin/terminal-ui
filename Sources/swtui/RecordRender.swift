import Foundation
import TerminalLog
import TerminalUIConfig
import TerminalUIRaster
import TerminalUIRecording

private let log = Log("swtui")

private let renderUsage = """
    Usage: swtui record render <log.tuirec> --format cast|svg|png|gif -o OUT
             [--at LABEL | --frame N | --from LABEL --to LABEL] [--clock script|draw]
             [--quantum 40ms] [--palette \(RecordingPalette.all.map(\.name).joined(separator: "|"))]
             [--font-size 15] [--line-height 1.2] [--padding 12] [--scale 1|2]   (svg, png, gif)
             [--loop-pause 1.5s]   (svg and gif animations)   [--svg-embed-font]   (svg)
             [--font bundled|PATH] [--font-bold PATH] [--font-italic PATH] [--font-bold-italic PATH]
             [--fallback-font PATH]... [--engine auto|builtin] [--missing-glyph system|box|fail]   (png, gif)
    An SVG with --at or --frame is a still; without, it plays the recording
    (or --from to --to) as a CSS animation that loops after --loop-pause.
    A PNG is a still; a GIF plays and loops as an animated SVG does.
    Defaults for these flags may be set in the [render] section of .terminalui/terminalui.toml.
    """

/// The formats `render` writes.
private enum RenderFormat: String {
    case cast
    case svg
    case png
    case gif
}

/// The cell metrics and padding of a picture, from `--font-size`,
/// `--line-height`, `--padding` and `--scale`.
private struct PictureSettings {
    static let defaultFontSize = 15
    static let scales = 1...2

    var metrics: CellMetrics
    var padding: Int

    /// `advance` is the cell's width as a share of the font's size: the
    /// raster font's own, else JetBrains Mono's, which the SVG's font stack
    /// leads with.
    init(options: [String: String], advance: Proportion = CellMetrics.jetBrainsMonoAdvance) {
        let fontSize = Self.count(options, "--font-size", default: Self.defaultFontSize, least: 1)
        let padding = Self.count(options, "--padding", default: SVGFrameRenderer.defaultPadding, least: 0)
        let scale = Self.count(options, "--scale", default: 1, least: 1)
        guard Self.scales.contains(scale) else { fail("--scale is 1 or 2, not \(scale)") }
        var lineHeight = CellMetrics.defaultLineHeight
        if let text = options["--line-height"] {
            guard let value = Proportion(decimal: text), value.numerator > 0 else {
                fail("--line-height takes a multiple of the font size such as 1.2, not \(text)")
            }
            lineHeight = value
        }
        metrics = CellMetrics(fontSize: fontSize, lineHeight: lineHeight, advance: advance, scale: scale)
        self.padding = padding
    }

    private static func count(_ options: [String: String], _ flag: String, default value: Int, least: Int) -> Int {
        guard let text = options[flag] else { return value }
        guard let number = Int(text), number >= least else { fail("\(flag) takes a whole number, not \(text)") }
        return number
    }
}

/// `swtui record render <log> --format cast|svg|png|gif -o OUT …` — a
/// picture of a `.tuirec` recording. `--at` renders the frame showing at a
/// mark, `--frame N` the frame the app counted as N, and `--from`/`--to`
/// the part between two marks. The clock is `script` — marks and their
/// holds make the timeline — when the log has marks, else `draw`, its real
/// times with long gaps cut; `--clock` chooses. An SVG with `--at` or
/// `--frame` is a still; otherwise it animates, and `--loop-pause` is how
/// long its last frame stays before it starts again. `--svg-embed-font`
/// carries the bundled JetBrains Mono, Regular and Bold, inside the SVG. A
/// PNG is a still, and a GIF animates as an SVG does. Flags not given come
/// from `[render]` in `.terminalui/terminalui.toml`, when it has them.
func renderCommand(args: [String]) {
    var options: [String: String] = [:]
    var fallbackFonts: [String] = []
    var operands: [String] = []
    let valued: Set = ["--format", "-o", "--at", "--frame", "--from", "--to", "--clock", "--quantum", "--palette",
                       "--font-size", "--line-height", "--padding", "--scale", "--loop-pause", "--font",
                       "--font-bold", "--font-italic", "--font-bold-italic", "--engine", "--missing-glyph"]
    let switches: Set = ["--svg-embed-font"]
    let repeated: Set = ["--fallback-font"]
    var index = 0
    while index < args.count {
        let argument = args[index]
        if switches.contains(argument) {
            options[argument] = ""
            index += 1
        } else if valued.contains(argument) || repeated.contains(argument) {
            guard index + 1 < args.count else { fail("\(argument) takes a value\n\(renderUsage)") }
            if repeated.contains(argument) {
                fallbackFonts.append(args[index + 1])
            } else {
                options[argument] = args[index + 1]
            }
            index += 2
        } else if argument.hasPrefix("-") {
            fail("unknown option \(argument)\n\(renderUsage)")
        } else {
            operands.append(argument)
            index += 1
        }
    }
    guard operands.count == 1, let path = operands.first, let output = options["-o"],
          let formatName = options["--format"] else {
        fail(renderUsage)
    }
    guard let format = RenderFormat(rawValue: formatName) else {
        fail("--format \(formatName) is not one swtui renders; it renders cast, svg, png and gif")
    }
    var frameNumber: Int?
    if let text = options["--frame"] {
        guard let number = Int(text) else { fail("--frame takes a frame number, not \(text)") }
        frameNumber = number
    }
    let range: PresentationClock.Range
    switch (options["--at"], frameNumber, options["--from"], options["--to"]) {
    case (nil, nil, nil, nil), (nil, _?, nil, nil): range = .whole
    case (let label?, nil, nil, nil): range = .at(label)
    case (nil, nil, let from?, let to?): range = .between(from: from, to: to)
    default: fail("--at, --frame and --from with --to each name the whole picture; give one\n\(renderUsage)")
    }
    let isStill = options["--at"] != nil || frameNumber != nil
    switch format {
    case .svg:
        if isStill, options["--loop-pause"] != nil { fail("--loop-pause is for an animation, not a still") }
    case .png:
        guard isStill else {
            fail("a PNG is a still: give --at LABEL or --frame N, or render an animation with --format gif")
        }
        if options["--loop-pause"] != nil { fail("--loop-pause is for an animation, not a still") }
    case .cast, .gif:
        guard frameNumber == nil else {
            fail("--frame names a still; a \(format.rawValue) plays --at, --from with --to, or all")
        }
        if format == .cast, options["--loop-pause"] != nil { fail("--loop-pause is for an SVG or a GIF") }
    }
    if format != .svg, options["--svg-embed-font"] != nil { fail("--svg-embed-font is for an SVG") }
    // The settings file fills in what the command line left out, after the
    // checks above: a project's loop pause does not make every still fail.
    do throws(RenderSettingsError) {
        let section = try RenderSection.load()
        options.merge(section.options) { given, _ in given }
        if fallbackFonts.isEmpty { fallbackFonts = section.fallbackFonts }
    } catch {
        fail("\(error)")
    }
    let paletteName = options["--palette"] ?? RecordingPalette.catppuccinMocha.name
    guard let palette = RecordingPalette.named(paletteName) else {
        fail("no palette \(paletteName); there are \(RecordingPalette.all.map(\.name).joined(separator: ", "))")
    }
    var raster: (fonts: RasterFonts, missingGlyph: MissingGlyphPolicy)?
    if format == .png || format == .gif {
        do throws(RenderSettingsError) {
            raster = (try RasterFonts(options: options, fallbackFonts: fallbackFonts),
                      try MissingGlyphPolicy(option: options["--missing-glyph"]))
        } catch {
            fail("\(error)")
        }
    }
    var loopPause = format == .gif ? RasterAnimator.defaultLoopPause : SVGAnimationRenderer.defaultLoopPause
    if let text = options["--loop-pause"] {
        guard let milliseconds = PresentationClock.milliseconds(parsing: text) else {
            fail("--loop-pause takes a duration such as 1.5s, not \(text)")
        }
        loopPause = milliseconds
    }
    let settings = PictureSettings(options: options, advance: raster?.fonts.advance ?? CellMetrics.jetBrainsMonoAdvance)
    let embeddedFont = options["--svg-embed-font"] == nil ? nil : bundledFont()
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }

    do throws(RecordingLogError) {
        let reader = try RecordingReader(bytes: data)
        let mode: PresentationClock.Mode
        switch options["--clock"] {
        case nil: mode = reader.marks.isEmpty ? .draw : .script
        case "script": mode = .script
        case "draw": mode = .draw
        case let other?: fail("--clock is script or draw, not \(other)")
        }
        var quantum = PresentationClock.defaultQuantum
        if let text = options["--quantum"] {
            guard let milliseconds = PresentationClock.milliseconds(parsing: text) else {
                fail("--quantum takes a duration such as 40ms, not \(text)")
            }
            quantum = milliseconds
        }
        let clock = try PresentationClock(mode: mode, quantum: quantum)
        /// The screen a still shows: the frame `--frame` names, else the one
        /// showing at `--at`'s mark.
        func stillScreen() throws(RecordingLogError) -> RecordingReader.Screen {
            let frame: Int
            if let frameNumber {
                guard let index = reader.frames.firstIndex(where: { $0.number == frameNumber }) else {
                    throw RecordingLogError("the log has no frame \(frameNumber)")
                }
                frame = index
            } else {
                frame = try clock.timeline(of: reader, range: range).frames[0].frame
            }
            guard let screen = reader.screens.first(where: { $0.index == frame }) else {
                throw RecordingLogError("the log has no frame at index \(frame)")
            }
            return screen
        }
        let picture: [UInt8]
        switch format {
        case .cast:
            picture = Array(CastEncoder(palette: palette)
                .encode(reader, timeline: try clock.timeline(of: reader, range: range)).utf8)
        case .svg where !isStill:
            let frames = SVGFrameRenderer(metrics: settings.metrics, palette: palette, padding: settings.padding,
                                          embeddedFont: embeddedFont)
            picture = Array(SVGAnimationRenderer(frames: frames, loopPause: loopPause)
                .render(reader, timeline: try clock.timeline(of: reader, range: range), title: reader.header.app).utf8)
        case .svg:
            let screen = try stillScreen()
            picture = Array(SVGFrameRenderer(metrics: settings.metrics, palette: palette, padding: settings.padding,
                                             embeddedFont: embeddedFont)
                .render(screen.buffer, windowBackground: screen.windowBackground, title: reader.header.app).utf8)
        case .png, .gif:
            guard let raster else { preconditionFailure("a raster format has its fonts") }
            let composer = RasterFrameComposer(metrics: settings.metrics, palette: palette, padding: settings.padding,
                                               glyphs: raster.fonts.sources(fontSize: settings.metrics.fontSize,
                                                                            scale: settings.metrics.scale))
            let drawn: RasterPicture
            if format == .png {
                let screen = try stillScreen()
                drawn = composer.still(screen, frameNumber: reader.frames[screen.index].number)
            } else {
                drawn = try RasterAnimator(composer: composer, loopPause: loopPause)
                    .animate(reader, timeline: try clock.timeline(of: reader, range: range))
            }
            do throws(MissingGlyphError) {
                for warning in try raster.missingGlyph.outcome(of: drawn.missing) + drawn.warnings {
                    log.warn("\(path): \(warning)")
                }
            } catch {
                fail("\(path): \(error)")
            }
            picture = drawn.bytes
        }
        guard FileManager.default.createFile(atPath: output, contents: Data(picture)) else {
            fail("cannot write \(output)")
        }
    } catch {
        fail("\(path): \(error)")
    }
}

/// The bundled JetBrains Mono's Regular and Bold, for `--svg-embed-font`.
private func bundledFont() -> SVGEmbeddedFont {
    let files = [(SVGEmbeddedFont.regularWeight, FontStyle.regular), (SVGEmbeddedFont.boldWeight, FontStyle.bold)]
    let faces = files.map { weight, style in
        let path = BundledFont.path(style)
        guard let data = FileManager.default.contents(atPath: path) else {
            fail("--svg-embed-font embeds the bundled font, and \(path) cannot be read:"
                 + " run swtui from a checkout of TerminalUI")
        }
        return SVGEmbeddedFont.Face(weight: weight, trueType: Array(data))
    }
    return SVGEmbeddedFont(family: BundledFont.family, faces: faces)
}

private func fail(_ message: String) -> Never {
    log.error(message)
    exit(1)
}
