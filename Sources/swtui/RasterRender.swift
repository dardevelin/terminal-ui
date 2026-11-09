import Foundation
import TerminalUIConfig
import TerminalUIRaster
import TerminalUIRecording

// The raster side of `swtui record render`: the fonts a PNG or GIF draws
// its text with, and the `[render]` section of `.terminalui/terminalui.toml`
// that every format's settings may come from.

// MARK: - [render]

/// `[render]` in `.terminalui/terminalui.toml`: the render flags' defaults
/// for this project, spelled as the flags are less their dashes, with `_`
/// for `-` (`font_size = 15`, `missing_glyph = "fail"`), and
/// `fallback_fonts = ["a.ttf", "b.ttf"]` for `--fallback-font`. A flag on
/// the command line wins. swtui reads it itself: it is no part of
/// `DiagConfig`, which configures a running app.
///
/// The settings parser reads strings, integers, booleans and lists of
/// strings, so a decimal or a duration is a string: `line_height = "1.2"`,
/// `quantum = "40ms"`.
enum RenderSection {
    static let name = "render"
    static let fallbackFontsKey = "fallback_fonts"

    /// The keys `[render]` takes: each one's flag.
    static let flags: [String: String] = Dictionary(uniqueKeysWithValues: [
        "palette", "font-size", "line-height", "padding", "scale", "quantum", "clock", "loop-pause",
        "font", "font-bold", "font-italic", "font-bold-italic", "engine", "missing-glyph",
    ].map { ($0.replacingOccurrences(of: "-", with: "_"), "--" + $0) })

    /// The section's settings as flags and their values, and its fallback
    /// fonts; nil values when the file has no `[render]`. A key it does not
    /// know, or a value it cannot read, is an error naming its line.
    static func load(from path: String = DiagPaths.configFile) throws(RenderSettingsError)
        -> (options: [String: String], fallbackFonts: [String]) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return ([:], []) }
        let document = TOMLParser.document(contents)
        let renderLines = lines(inSection: name, of: contents)
        if let problem = document.problems.first(where: { renderLines.contains($0.line) }) {
            throw RenderSettingsError("\(path): [\(name)] \(problem)")
        }
        var options: [String: String] = [:]
        var fallbackFonts: [String] = []
        for entry in document.entries where entry.section == name {
            let place = "\(path) line \(entry.line)"
            if entry.key == fallbackFontsKey {
                guard case .strings(let paths) = entry.value else {
                    throw RenderSettingsError("\(place): \(fallbackFontsKey) is a list of font paths, as [\"a.ttf\"]")
                }
                fallbackFonts = paths
                continue
            }
            guard let flag = flags[entry.key] else {
                throw RenderSettingsError("\(place): [\(name)] has no key \(entry.key); it takes "
                    + (flags.keys.sorted() + [fallbackFontsKey]).joined(separator: ", "))
            }
            switch entry.value {
            case .string(let text): options[flag] = text
            case .integer(let number): options[flag] = String(number)
            case .bool, .strings:
                throw RenderSettingsError("\(place): \(entry.key) takes a string or a number")
            }
        }
        return (options, fallbackFonts)
    }

    /// The 1-based numbers of the lines inside `[section]`, its header
    /// excluded: where a problem the parser reports belongs to it.
    private static func lines(inSection section: String, of contents: String) -> Set<Int> {
        var inside = false
        var numbers: Set<Int> = []
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inside = trimmed.replacingOccurrences(of: " ", with: "").hasPrefix("[\(section)]")
                continue
            }
            if inside { numbers.insert(index + 1) }
        }
        return numbers
    }
}

struct RenderSettingsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Fonts

/// JetBrains Mono, bundled under `tools/fonts/JetBrainsMono/` in the
/// checkout swtui was built from, found from this source file's own path:
/// the font is developer tooling, in no product, so an installed swtui has
/// no copy of its own. The raster pictures draw with it and
/// `--svg-embed-font` carries it.
enum BundledFont {
    static let family = "JetBrains Mono"
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/fonts/JetBrainsMono")

    static let files: [FontStyle: String] = [
        .regular: "JetBrainsMono-Regular.ttf", .bold: "JetBrainsMono-Bold.ttf",
        .italic: "JetBrainsMono-Italic.ttf", .boldItalic: "JetBrainsMono-BoldItalic.ttf",
    ]

    static func path(_ style: FontStyle) -> String {
        directory.appendingPathComponent(files[style] ?? "").path
    }
}

/// The fonts a raster picture's text is drawn with, from `--font`,
/// `--font-bold`, `--font-italic`, `--font-bold-italic`, `--fallback-font`
/// and `--engine`.
///
/// `--font bundled` (the default) is ``BundledFont``. `--font
/// PATH` is a TrueType file (`.ttf`, or face 0 of a `.ttc`); a style without
/// a file of its own is synthesized from the nearest one. `--font system`
/// and `--engine system` need the system font engine, which raster pictures
/// do not have yet, so they are refused rather than quietly drawn in another
/// font than the one asked for.
struct RasterFonts {
    static let engines = ["auto", "builtin"]
    private static let styleFlags: [(flag: String, style: FontStyle)] = [
        ("--font-bold", .bold), ("--font-italic", .italic), ("--font-bold-italic", .boldItalic),
    ]

    let fonts: FontSet
    let fallbacks: [TrueTypeFont]

    init(options: [String: String], fallbackFonts: [String]) throws(RenderSettingsError) {
        let engine = options["--engine"] ?? "auto"
        guard Self.engines.contains(engine) else {
            if engine == "system" {
                throw RenderSettingsError("--engine system needs the system font engine, which raster pictures do not"
                    + " have yet: render with --engine builtin (what auto picks for now)")
            }
            throw RenderSettingsError("--engine is \(Self.engines.joined(separator: " or ")), not \(engine)")
        }
        var files: [FontStyle: String] = [:]
        switch options["--font"] ?? "bundled" {
        case "system":
            throw RenderSettingsError("--font system needs the system font engine, which raster pictures do not have"
                + " yet: render with --font bundled (the default for now) or --font PATH")
        case "bundled":
            guard FileManager.default.fileExists(atPath: BundledFont.directory.path) else {
                throw RenderSettingsError("the bundled font is not at \(BundledFont.directory.path), where the checkout"
                    + " swtui was built from keeps it: give a TrueType file with --font PATH")
            }
            for style in FontStyle.allCases { files[style] = BundledFont.path(style) }
        case let path:
            files[.regular] = path
        }
        for (flag, style) in Self.styleFlags {
            if let path = options[flag] { files[style] = path }
        }
        guard let regularPath = files[.regular] else { preconditionFailure("every font choice names a regular face") }
        let regular = try Self.font(at: regularPath)
        fonts = FontSet(regular: regular, bold: try files[.bold].map(Self.font),
                        italic: try files[.italic].map(Self.font), boldItalic: try files[.boldItalic].map(Self.font))
        var fallbacks: [TrueTypeFont] = []
        for path in fallbackFonts { fallbacks.append(try Self.font(at: path)) }
        self.fallbacks = fallbacks
    }

    /// The cell's width as a share of the font's size: a monospaced font's
    /// advance over its em (`hmtx` over `head.unitsPerEm`), read from the
    /// digit zero, which every such font has at its one advance.
    var advance: Proportion {
        guard let glyph = fonts.regular.glyphID(for: "0"), let width = try? fonts.regular.advanceWidth(ofGlyph: glyph),
              width > 0 else { return CellMetrics.jetBrainsMonoAdvance }
        return Proportion(width, fonts.regular.unitsPerEm)
    }

    /// The glyph sources, best first, at the picture's size.
    func sources(fontSize: Int, scale: Int) -> [any GlyphSource] {
        let size = GlyphSize(pixelsPerEm: fontSize, scale: scale)
        return [BuiltinGlyphSource(fonts: fonts, size: size)]
            + fallbacks.map { BuiltinGlyphSource(fonts: FontSet(regular: $0), size: size) }
    }

    private static func font(at path: String) throws(RenderSettingsError) -> TrueTypeFont {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw RenderSettingsError("cannot read the font \(path)")
        }
        do {
            return try TrueTypeFont(bytes: [UInt8](data))
        } catch {
            throw RenderSettingsError("\(path): \(error)")
        }
    }
}

// MARK: - Missing glyphs

extension MissingGlyphPolicy {
    /// `--missing-glyph`, `system` when it is not given.
    init(option: String?) throws(RenderSettingsError) {
        guard let policy = MissingGlyphPolicy(rawValue: option ?? MissingGlyphPolicy.system.rawValue) else {
            throw RenderSettingsError("--missing-glyph is \(MissingGlyphPolicy.allCases.map(\.rawValue).joined(separator: ", ")),"
                + " not \(option ?? "")")
        }
        self = policy
    }
}
