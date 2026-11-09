import Foundation
import Testing
@testable import TerminalUIRaster

// MARK: - The bundled font

/// JetBrains Mono's four files, read from `tools/fonts/JetBrainsMono/` in
/// the checkout: in no target, so found from this file's own path.
enum BundledFont {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/fonts/JetBrainsMono")

    static func fileName(_ style: FontStyle) -> String {
        switch style {
        case .regular: "JetBrainsMono-Regular.ttf"
        case .bold: "JetBrainsMono-Bold.ttf"
        case .italic: "JetBrainsMono-Italic.ttf"
        case .boldItalic: "JetBrainsMono-BoldItalic.ttf"
        }
    }

    /// Read once; a missing file reads as no bytes, which the parser then
    /// rejects with an error the test reports.
    private static let files: [FontStyle: [UInt8]] = Dictionary(uniqueKeysWithValues: FontStyle.allCases.map { style in
        (style, (try? [UInt8](Data(contentsOf: directory.appendingPathComponent(fileName(style))))) ?? [])
    })

    static func bytes(_ style: FontStyle) -> [UInt8] { files[style] ?? [] }

    static func font(_ style: FontStyle = .regular) throws -> TrueTypeFont {
        try TrueTypeFont(bytes: bytes(style))
    }

    static func fontSet() throws -> FontSet {
        FontSet(regular: try font(.regular), bold: try font(.bold), italic: try font(.italic),
                boldItalic: try font(.boldItalic))
    }
}

// MARK: - Fonts made to order

/// Writes a minimal TrueType font — head, hhea, maxp, OS/2, hmtx, cmap,
/// loca, glyf — from glyphs described here, for what the bundled font
/// does not exercise: scaled and rotated components, point matching,
/// collections, and damage.
struct FontBuilder {
    struct Component {
        var glyph: Int
        var arguments: (Int, Int)
        /// Added to the builder's own: ARG_1_AND_2_ARE_WORDS always, and
        /// MORE_COMPONENTS on all but the last.
        var flags: Int = ComponentFlags.argumentsAreXYValues
        /// F2Dot14 values: none, one (WE_HAVE_A_SCALE), two
        /// (WE_HAVE_AN_X_AND_Y_SCALE) or four (WE_HAVE_A_TWO_BY_TWO).
        var transform: [Int] = []
    }

    enum ComponentFlags {
        static let argumentsAreWords = 0x0001
        static let argumentsAreXYValues = 0x0002
        static let hasScale = 0x0008
        static let moreComponents = 0x0020
        static let hasXAndYScale = 0x0040
        static let hasTwoByTwo = 0x0080
        static let scaledComponentOffset = 0x0800
    }

    enum Glyph {
        case empty
        case simple([[OutlinePoint]])
        case composite([Component])
    }

    /// Glyph 0 is `.notdef`.
    var glyphs: [Glyph] = [.empty]
    var characters: [UInt32: Int] = [:]
    var unitsPerEm = 1000
    var advance = 600
    var horizontalHeaderMetrics = FontMetrics(ascender: 800, descender: -200, lineGap: 0)
    var typographicMetrics = FontMetrics(ascender: 750, descender: -250, lineGap: 100)
    var usesTypographicMetrics = false

    mutating func add(_ glyph: Glyph, for character: Character? = nil) -> Int {
        glyphs.append(glyph)
        if let character { characters[character.unicodeScalars.first!.value] = glyphs.count - 1 }
        return glyphs.count - 1
    }

    func build() -> [UInt8] { Self.assemble([tables()]) }

    /// A TrueType collection of `fonts`, each face's directory pointing at
    /// its own tables.
    static func collection(_ fonts: [FontBuilder]) -> [UInt8] { assemble(fonts.map { $0.tables() }) }

    func tables() -> [(tag: String, bytes: [UInt8])] {
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        for glyph in glyphs {
            loca += Self.uint32(glyf.count)
            glyf += encode(glyph)
            while glyf.count % 4 != 0 { glyf.append(0) }
        }
        loca += Self.uint32(glyf.count)

        var head = [UInt8](repeating: 0, count: 54)
        head.replaceSubrange(0..<4, with: Self.uint32(0x0001_0000))
        head.replaceSubrange(12..<16, with: Self.uint32(0x5F0F_3CF5))
        head.replaceSubrange(18..<20, with: Self.uint16(unitsPerEm))
        head.replaceSubrange(50..<52, with: Self.uint16(1))

        var hhea = [UInt8](repeating: 0, count: 36)
        hhea.replaceSubrange(0..<4, with: Self.uint32(0x0001_0000))
        hhea.replaceSubrange(4..<6, with: Self.uint16(horizontalHeaderMetrics.ascender))
        hhea.replaceSubrange(6..<8, with: Self.uint16(horizontalHeaderMetrics.descender))
        hhea.replaceSubrange(8..<10, with: Self.uint16(horizontalHeaderMetrics.lineGap))
        hhea.replaceSubrange(34..<36, with: Self.uint16(glyphs.count))

        var os2 = [UInt8](repeating: 0, count: 78)
        os2.replaceSubrange(62..<64, with: Self.uint16(usesTypographicMetrics ? 1 << 7 : 0))
        os2.replaceSubrange(68..<70, with: Self.uint16(typographicMetrics.ascender))
        os2.replaceSubrange(70..<72, with: Self.uint16(typographicMetrics.descender))
        os2.replaceSubrange(72..<74, with: Self.uint16(typographicMetrics.lineGap))

        let maxp = Self.uint32(0x0000_5000) + Self.uint16(glyphs.count)
        let hmtx = glyphs.flatMap { _ in Self.uint16(advance) + Self.uint16(0) }
        return [("OS/2", os2), ("cmap", characterMap()), ("glyf", glyf), ("head", head), ("hhea", hhea),
                ("hmtx", hmtx), ("loca", loca), ("maxp", maxp)]
    }

    /// Format 4 for the BMP, a segment a character and the closing 0xFFFF
    /// one; format 12 beside it when any character is past the BMP.
    private func characterMap() -> [UInt8] {
        let sorted = characters.sorted { $0.key < $1.key }
        let bmp = sorted.filter { $0.key <= 0xFFFF }
        let segments = bmp.map { (code: Int($0.key), glyph: $0.value) } + [(code: 0xFFFF, glyph: 0)]
        var format4 = Self.uint16(4) + Self.uint16(0) + Self.uint16(0) + Self.uint16(2 * segments.count)
            + Self.uint16(0) + Self.uint16(0) + Self.uint16(0)
        format4 += segments.flatMap { Self.uint16($0.code) } + Self.uint16(0)
        format4 += segments.flatMap { Self.uint16($0.code) }
        format4 += segments.flatMap { Self.uint16(($0.glyph == 0 ? 1 : $0.glyph - $0.code) & 0xFFFF) }
        format4 += segments.flatMap { _ in Self.uint16(0) }
        format4.replaceSubrange(2..<4, with: Self.uint16(format4.count))

        let needsFull = sorted.contains { $0.key > 0xFFFF }
        var format12: [UInt8] = []
        if needsFull {
            format12 = Self.uint16(12) + Self.uint16(0) + Self.uint32(16 + 12 * sorted.count) + Self.uint32(0)
                + Self.uint32(sorted.count)
            format12 += sorted.flatMap { Self.uint32(Int($0.key)) + Self.uint32(Int($0.key)) + Self.uint32($0.value) }
        }
        let recordCount = needsFull ? 2 : 1
        var cmap = Self.uint16(0) + Self.uint16(recordCount)
        let first = 4 + 8 * recordCount
        cmap += Self.uint16(3) + Self.uint16(1) + Self.uint32(first)
        if needsFull { cmap += Self.uint16(3) + Self.uint16(10) + Self.uint32(first + format4.count) }
        return cmap + format4 + format12
    }

    private func encode(_ glyph: Glyph) -> [UInt8] {
        switch glyph {
        case .empty:
            return []
        case .simple(let contours):
            let points = contours.flatMap { $0 }
            let xCoordinates = points.map(\.x), yCoordinates = points.map(\.y)
            var bytes = Self.uint16(contours.count)
            bytes += [xCoordinates.min()!, yCoordinates.min()!, xCoordinates.max()!, yCoordinates.max()!].flatMap(Self.uint16)
            var end = -1
            for contour in contours {
                end += contour.count
                bytes += Self.uint16(end)
            }
            bytes += Self.uint16(0)
            // Every coordinate a 16-bit delta: no short or same flags.
            bytes += points.map { $0.isOnCurve ? 1 : 0 }
            var previous = 0
            for x in xCoordinates { bytes += Self.uint16(x - previous); previous = x }
            previous = 0
            for y in yCoordinates { bytes += Self.uint16(y - previous); previous = y }
            return bytes
        case .composite(let components):
            var bytes = Self.uint16(-1) + [UInt8](repeating: 0, count: 8)
            for (index, component) in components.enumerated() {
                var flags = component.flags | ComponentFlags.argumentsAreWords
                if index < components.count - 1 { flags |= ComponentFlags.moreComponents }
                switch component.transform.count {
                case 1: flags |= ComponentFlags.hasScale
                case 2: flags |= ComponentFlags.hasXAndYScale
                case 4: flags |= ComponentFlags.hasTwoByTwo
                default: break
                }
                bytes += Self.uint16(flags) + Self.uint16(component.glyph)
                bytes += Self.uint16(component.arguments.0) + Self.uint16(component.arguments.1)
                bytes += component.transform.flatMap(Self.uint16)
            }
            return bytes
        }
    }

    /// The sfnt header and table directory for each face, then every
    /// table, each on a four-byte boundary (OpenType "Font file").
    private static func assemble(_ faces: [[(tag: String, bytes: [UInt8])]]) -> [UInt8] {
        let isCollection = faces.count > 1
        let collectionHeader = isCollection ? 12 + 4 * faces.count : 0
        let directorySizes = faces.map { 12 + 16 * $0.count }
        var tableOffset = collectionHeader + directorySizes.reduce(0, +)
        var directories: [[UInt8]] = []
        var body: [UInt8] = []
        for face in faces {
            var directory = uint32(0x0001_0000) + uint16(face.count) + uint16(0) + uint16(0) + uint16(0)
            for table in face {
                directory += Array(table.tag.utf8) + uint32(0) + uint32(tableOffset) + uint32(table.bytes.count)
                var padded = table.bytes
                while padded.count % 4 != 0 { padded.append(0) }
                body += padded
                tableOffset += padded.count
            }
            directories.append(directory)
        }
        var file: [UInt8] = []
        if isCollection {
            file = Array("ttcf".utf8) + uint16(1) + uint16(0) + uint32(faces.count)
            var directoryOffset = collectionHeader
            for size in directorySizes {
                file += uint32(directoryOffset)
                directoryOffset += size
            }
        }
        return file + directories.flatMap { $0 } + body
    }

    static func uint16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func uint32(_ value: Int) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}

/// A 24.8 rectangle's corners, clockwise on a y-down screen — which is
/// counter-clockwise in a y-up font — from pixel coordinates.
func rectangle(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) -> [OutlinePoint] {
    let one = CoverageRasterizer.one
    return [OutlinePoint(left * one, top * one), OutlinePoint(right * one, top * one),
            OutlinePoint(right * one, bottom * one), OutlinePoint(left * one, bottom * one)]
}

// MARK: - Looking at glyphs

/// A bitmap as text, darkest ink as `@`, one character a pixel — what a
/// failing golden prints, and what to eyeball one by.
func asciiArt(width: Int, height: Int, coverage: [UInt8]) -> String {
    let ramp = Array(" .:-=+*#%@")
    return (0..<height).map { row in
        String((0..<width).map { column in ramp[Int(coverage[row * width + column]) * (ramp.count - 1) / 255] })
    }.joined(separator: "\n")
}

func asciiArt(_ glyph: GlyphBitmap) -> String {
    guard case .coverage(let coverage) = glyph.pixels else { return "(colour)" }
    return asciiArt(width: glyph.width, height: glyph.height, coverage: coverage)
}

/// A glyph as a binary PGM (Netpbm "P5"), its placement in a comment: the
/// format of the golden glyphs, which any image viewer opens.
func portableGraymap(_ glyph: GlyphBitmap) -> [UInt8] {
    guard case .coverage(let coverage) = glyph.pixels else { return [] }
    let header = "P5\n# left \(glyph.left) top \(glyph.top) advance \(glyph.advance)\n\(glyph.width) \(glyph.height)\n255\n"
    return Array(header.utf8) + coverage
}

func coverage(of glyph: GlyphBitmap?) -> [UInt8] {
    guard case .coverage(let coverage)? = glyph?.pixels else { return [] }
    return coverage
}
