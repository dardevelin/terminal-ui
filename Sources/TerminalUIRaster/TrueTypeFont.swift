/// The vertical metrics a renderer lays lines out by, in font units:
/// ascender above the baseline, descender below it (negative), and the gap
/// between one line's descender and the next one's ascender.
package struct FontMetrics: Equatable, Sendable {
    package var ascender: Int
    package var descender: Int
    package var lineGap: Int
}

/// One face of a TrueType font (`glyf` outlines), read from the file's
/// bytes. Section names below are the Microsoft OpenType specification's
/// table pages (learn.microsoft.com/typography/opentype/spec); Apple's
/// TrueType Reference Manual describes the same tables.
///
/// Parsing reads the headers and checks each table lies inside the file;
/// outlines are read on demand. A malformed font throws `FontError`
/// wherever the damage is found, and never traps.
package struct TrueTypeFont: Sendable {
    /// How deep composite glyphs may nest. `maxp` declares a font's own
    /// maxComponentDepth, but a malformed font may lie in it; real fonts
    /// stay under 4, and the limit is also what ends a composite that
    /// contains itself.
    package static let maximumComponentDepth = 8
    /// Point numbers in `glyf` and in composite point matching are 16 bits.
    package static let maximumPointCount = Int(UInt16.max)

    /// "head": unitsPerEm is 16 to 16384.
    package static let unitsPerEmRange = 16...16_384

    package let unitsPerEm: Int
    package let glyphCount: Int
    /// The metrics a line is laid out by: OS/2's typographic metrics when
    /// its USE_TYPO_METRICS flag asks for them, else hhea's ("OS/2",
    /// fsSelection bit 7).
    package let metrics: FontMetrics
    package let horizontalHeaderMetrics: FontMetrics
    /// OS/2's sTypoAscender, sTypoDescender, sTypoLineGap; nil without an
    /// OS/2 table long enough to hold them.
    package let typographicMetrics: FontMetrics?
    package let usesTypographicMetrics: Bool

    private let characterMap: CharacterMap
    private let horizontalMetrics: FontTable
    private let horizontalMetricCount: Int
    private let locations: FontTable
    private let usesLongLocations: Bool
    private let glyphData: FontTable

    // MARK: - The file's layout

    /// "Font file" (the OpenType font file page): the sfnt version, or a
    /// collection's tag.
    private enum Signature {
        static let trueType = 0x0001_0000
        /// Apple's TrueType Reference Manual, "The font directory": 'true'
        /// marks a TrueType font on Apple platforms.
        static let appleTrueType = 0x7472_7565
        /// 'OTTO': CFF outlines.
        static let compactFontFormat = 0x4F54_544F
        /// 'ttcf': a TrueType collection.
        static let collection = 0x7474_6366
    }

    private enum Directory {
        static let tableCount = 4
        static let records = 12
        static let recordSize = 16
        /// A collection's header: tag, major and minor version, numFonts,
        /// then numFonts offsets to table directories.
        static let collectionFaceCount = 8
        static let collectionOffsets = 12
    }

    private enum Head {
        static let magicNumber = 0x5F0F_3CF5
        static let magicNumberOffset = 12
        static let unitsPerEm = 18
        static let indexToLocFormat = 50
        static let minimumLength = 54
    }

    private enum HorizontalHeader {
        static let ascender = 4
        static let descender = 6
        static let lineGap = 8
        static let numberOfHMetrics = 34
        static let minimumLength = 36
    }

    private enum MaximumProfile {
        static let numGlyphs = 4
    }

    private enum OS2 {
        static let fsSelection = 62
        /// fsSelection bit 7.
        static let useTypoMetrics = 1 << 7
        static let typoAscender = 68
        static let typoDescender = 70
        static let typoLineGap = 72
        /// Version 0 as Microsoft specified it ends after usWinDescent; the
        /// typographic fields need at least this much.
        static let typoMetricsEnd = 74
    }

    /// "hmtx": a longHorMetric is advanceWidth and lsb, 16 bits each.
    private static let longHorizontalMetricSize = 4

    // MARK: - Reading

    /// How many faces `bytes` holds: a collection's count, else 1.
    package static func faceCount(in bytes: [UInt8]) throws(FontError) -> Int {
        let file = FontTable(file: bytes)
        return try file.uint32(at: 0) == Signature.collection ? file.uint32(at: Directory.collectionFaceCount) : 1
    }

    /// Face `faceIndex` of `bytes`: of a collection ("TrueType collections",
    /// on the font file page), the face whose table directory its offset
    /// table names; of a single font, only face 0.
    package init(bytes: [UInt8], faceIndex: Int = 0) throws(FontError) {
        let file = FontTable(file: bytes)
        var directory = 0
        if try file.uint32(at: 0) == Signature.collection {
            let count = try file.uint32(at: Directory.collectionFaceCount)
            guard (0..<count).contains(faceIndex) else { throw .faceOutOfRange(index: faceIndex, count: count) }
            directory = try file.uint32(at: Directory.collectionOffsets + 4 * faceIndex)
        } else if faceIndex != 0 {
            throw .faceOutOfRange(index: faceIndex, count: 1)
        }
        switch try file.uint32(at: directory) {
        case Signature.trueType, Signature.appleTrueType: break
        case Signature.compactFontFormat: throw .cffOutlines
        case let signature: throw .unknownSignature(UInt32(truncatingIfNeeded: signature))
        }

        var tables: [String: FontTable] = [:]
        for index in 0..<(try file.uint16(at: directory + Directory.tableCount)) {
            let record = directory + Directory.records + index * Directory.recordSize
            let tag = try file.tag(at: record)
            let offset = try file.uint32(at: record + 8)
            let length = try file.uint32(at: record + 12)
            guard offset <= bytes.count, length <= bytes.count - offset else {
                throw .malformed(table: tag, reason: "\(length) bytes at \(offset) in a file of \(bytes.count)")
            }
            tables[tag] = FontTable(bytes: bytes, start: offset, length: length, name: "the '\(tag)' table")
        }
        func table(_ tag: String) throws(FontError) -> FontTable {
            guard let table = tables[tag] else { throw .missingTable(tag) }
            return table
        }

        let head = try table("head")
        guard head.length >= Head.minimumLength, try head.uint32(at: Head.magicNumberOffset) == Head.magicNumber else {
            throw .malformed(table: "head", reason: "no magic number")
        }
        unitsPerEm = try head.uint16(at: Head.unitsPerEm)
        guard Self.unitsPerEmRange.contains(unitsPerEm) else {
            throw .malformed(table: "head", reason: "\(unitsPerEm) units per em")
        }
        switch try head.int16(at: Head.indexToLocFormat) {
        case 0: usesLongLocations = false
        case 1: usesLongLocations = true
        case let format: throw .malformed(table: "head", reason: "indexToLocFormat \(format)")
        }

        glyphCount = try table("maxp").uint16(at: MaximumProfile.numGlyphs)

        let horizontalHeader = try table("hhea")
        guard horizontalHeader.length >= HorizontalHeader.minimumLength else { throw .truncated("the 'hhea' table") }
        horizontalHeaderMetrics = FontMetrics(ascender: try horizontalHeader.int16(at: HorizontalHeader.ascender),
                                              descender: try horizontalHeader.int16(at: HorizontalHeader.descender),
                                              lineGap: try horizontalHeader.int16(at: HorizontalHeader.lineGap))
        horizontalMetricCount = try horizontalHeader.uint16(at: HorizontalHeader.numberOfHMetrics)
        horizontalMetrics = try table("hmtx")
        guard (1...max(1, glyphCount)).contains(horizontalMetricCount),
              horizontalMetricCount * Self.longHorizontalMetricSize <= horizontalMetrics.length else {
            throw .malformed(table: "hmtx", reason: "\(horizontalMetricCount) metrics in \(horizontalMetrics.length) bytes")
        }

        if let os2 = tables["OS/2"], os2.length >= OS2.typoMetricsEnd {
            typographicMetrics = FontMetrics(ascender: try os2.int16(at: OS2.typoAscender),
                                             descender: try os2.int16(at: OS2.typoDescender),
                                             lineGap: try os2.int16(at: OS2.typoLineGap))
            usesTypographicMetrics = try os2.uint16(at: OS2.fsSelection) & OS2.useTypoMetrics != 0
        } else {
            typographicMetrics = nil
            usesTypographicMetrics = false
        }
        metrics = usesTypographicMetrics ? typographicMetrics ?? horizontalHeaderMetrics : horizontalHeaderMetrics

        characterMap = try CharacterMap(table("cmap"))
        locations = try table("loca")
        glyphData = try table("glyf")
        guard (glyphCount + 1) * (usesLongLocations ? 4 : 2) <= locations.length else {
            throw .truncated("the 'loca' table")
        }
    }

    // MARK: - Glyphs

    /// The glyph `scalar` maps to, or nil if the font lacks it.
    package func glyphID(for scalar: Unicode.Scalar) -> Int? {
        characterMap.glyphID(for: scalar).flatMap { $0 < glyphCount ? $0 : nil }
    }

    /// "hmtx": glyphs past numberOfHMetrics share the last advance, which
    /// is how a monospaced font stores one advance for all.
    package func advanceWidth(ofGlyph glyph: Int) throws(FontError) -> Int {
        try checkGlyph(glyph)
        let record = min(glyph, horizontalMetricCount - 1)
        return try horizontalMetrics.uint16(at: record * Self.longHorizontalMetricSize)
    }

    /// Glyph `glyph`'s outline in font units, composites resolved.
    package func outline(ofGlyph glyph: Int) throws(FontError) -> GlyphOutline {
        try outline(ofGlyph: glyph, depth: 0)
    }

    private func checkGlyph(_ glyph: Int) throws(FontError) {
        guard (0..<glyphCount).contains(glyph) else {
            throw .malformed(table: "loca", reason: "glyph \(glyph) of \(glyphCount)")
        }
    }

    /// "loca": glyph *i*'s data runs from offset *i* to offset *i* + 1;
    /// the short format stores offsets halved. An empty range is a glyph
    /// with no outline, as a space is.
    private func data(ofGlyph glyph: Int) throws(FontError) -> FontTable? {
        try checkGlyph(glyph)
        let start: Int
        let end: Int
        if usesLongLocations {
            start = try locations.uint32(at: 4 * glyph)
            end = try locations.uint32(at: 4 * glyph + 4)
        } else {
            start = try locations.uint16(at: 2 * glyph) * 2
            end = try locations.uint16(at: 2 * glyph + 2) * 2
        }
        guard start <= end else { throw .malformed(table: "loca", reason: "glyph \(glyph) ends before it starts") }
        guard end > start else { return nil }
        return try glyphData.subtable(at: start, length: end - start)
    }

    private func outline(ofGlyph glyph: Int, depth: Int) throws(FontError) -> GlyphOutline {
        guard let data = try data(ofGlyph: glyph) else { return GlyphOutline() }
        let contourCount = try data.int16(at: 0)
        return contourCount >= 0 ? try simpleOutline(data, contourCount: contourCount)
            : try compositeOutline(data, glyph: glyph, depth: depth)
    }

    // MARK: Simple glyphs

    /// "glyf", simple glyph description: flags.
    private enum PointFlag {
        static let onCurve = 0x01
        static let xIsShort = 0x02
        static let yIsShort = 0x04
        static let repeats = 0x08
        /// With the short flag, the sign of the one-byte delta (set is
        /// positive); without it, set means the coordinate repeats.
        static let xIsSameOrPositive = 0x10
        static let yIsSameOrPositive = 0x20
    }

    /// A glyph's header: numberOfContours, then its bounding box, which is
    /// not trusted (the outline's own points are what gets drawn).
    private static let glyphHeaderSize = 10

    private func simpleOutline(_ data: FontTable, contourCount: Int) throws(FontError) -> GlyphOutline {
        var outline = GlyphOutline()
        guard contourCount > 0 else { return outline }
        var previousEnd = -1
        for index in 0..<contourCount {
            let end = try data.uint16(at: Self.glyphHeaderSize + 2 * index)
            guard end > previousEnd else { throw .malformed(table: "glyf", reason: "contour ends out of order") }
            outline.contourEnds.append(end)
            previousEnd = end
        }
        let pointCount = previousEnd + 1
        let instructionLength = try data.uint16(at: Self.glyphHeaderSize + 2 * contourCount)
        var offset = Self.glyphHeaderSize + 2 * contourCount + 2 + instructionLength

        var flags: [Int] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount {
            let flag = try data.uint8(at: offset)
            offset += 1
            var count = 1
            if flag & PointFlag.repeats != 0 {
                count += try data.uint8(at: offset)
                offset += 1
            }
            guard flags.count + count <= pointCount else {
                throw .malformed(table: "glyf", reason: "a flag repeats past the last point")
            }
            flags += repeatElement(flag, count: count)
        }

        func coordinates(short: Int, sameOrPositive: Int) throws(FontError) -> [Int] {
            var value = 0
            var values: [Int] = []
            values.reserveCapacity(pointCount)
            for flag in flags {
                if flag & short != 0 {
                    let delta = try data.uint8(at: offset)
                    offset += 1
                    value += flag & sameOrPositive != 0 ? delta : -delta
                } else if flag & sameOrPositive == 0 {
                    value += try data.int16(at: offset)
                    offset += 2
                }
                values.append(value)
            }
            return values
        }
        let xCoordinates = try coordinates(short: PointFlag.xIsShort, sameOrPositive: PointFlag.xIsSameOrPositive)
        let yCoordinates = try coordinates(short: PointFlag.yIsShort, sameOrPositive: PointFlag.yIsSameOrPositive)
        outline.points = (0..<pointCount).map { OutlinePoint(xCoordinates[$0], yCoordinates[$0], onCurve: flags[$0] & PointFlag.onCurve != 0) }
        return outline
    }

    // MARK: Composite glyphs

    /// "glyf", composite glyph description: component flags.
    private enum ComponentFlag {
        static let argumentsAreWords = 0x0001
        /// Set, the arguments are an offset; clear, they are point numbers
        /// to match, one in the glyph so far and one in the component.
        static let argumentsAreXYValues = 0x0002
        static let hasScale = 0x0008
        static let moreComponents = 0x0020
        static let hasXAndYScale = 0x0040
        static let hasTwoByTwo = 0x0080
        static let scaledComponentOffset = 0x0800
        static let unscaledComponentOffset = 0x1000
        // ROUND_XY_TO_GRID (0x0004), WE_HAVE_INSTRUCTIONS (0x0100) and
        // USE_MY_METRICS (0x0200) only matter to a hinting engine, which
        // this is not.
    }

    /// F2Dot14 (OpenType "Data types"): a 2.14 signed fixed-point number.
    private static let f2Dot14One = 1 << 14

    /// A component's 2×2 transform in F2Dot14, the spec's xscale, scale01,
    /// scale10 and yscale, applied as it writes them:
    /// x′ = xscale·x + scale10·y, y′ = scale01·x + yscale·y.
    private struct ComponentTransform {
        var xScale = f2Dot14One
        var scale01 = 0
        var scale10 = 0
        var yScale = f2Dot14One

        var isIdentity: Bool { xScale == f2Dot14One && scale01 == 0 && scale10 == 0 && yScale == f2Dot14One }

        /// Rounded to whole font units, as an unhinted FreeType load does.
        func apply(_ x: Int, _ y: Int) -> (x: Int, y: Int) {
            (IntegerMath.roundedDivide(xScale * x + scale10 * y, f2Dot14One),
             IntegerMath.roundedDivide(scale01 * x + yScale * y, f2Dot14One))
        }
    }

    private func compositeOutline(_ data: FontTable, glyph: Int, depth: Int) throws(FontError) -> GlyphOutline {
        guard depth < Self.maximumComponentDepth else { throw .compositeTooDeep(glyph: glyph) }
        var outline = GlyphOutline()
        var offset = Self.glyphHeaderSize
        var flags: Int
        repeat {
            flags = try data.uint16(at: offset)
            let component = try data.uint16(at: offset + 2)
            offset += 4
            let isOffset = flags & ComponentFlag.argumentsAreXYValues != 0
            let first: Int
            let second: Int
            switch (flags & ComponentFlag.argumentsAreWords != 0, isOffset) {
            case (true, true): (first, second) = (try data.int16(at: offset), try data.int16(at: offset + 2))
            case (true, false): (first, second) = (try data.uint16(at: offset), try data.uint16(at: offset + 2))
            case (false, true): (first, second) = (try data.int8(at: offset), try data.int8(at: offset + 1))
            case (false, false): (first, second) = (try data.uint8(at: offset), try data.uint8(at: offset + 1))
            }
            offset += flags & ComponentFlag.argumentsAreWords != 0 ? 4 : 2

            var transform = ComponentTransform()
            if flags & ComponentFlag.hasScale != 0 {
                transform.xScale = try data.int16(at: offset)
                transform.yScale = transform.xScale
                offset += 2
            } else if flags & ComponentFlag.hasXAndYScale != 0 {
                transform.xScale = try data.int16(at: offset)
                transform.yScale = try data.int16(at: offset + 2)
                offset += 4
            } else if flags & ComponentFlag.hasTwoByTwo != 0 {
                transform.xScale = try data.int16(at: offset)
                transform.scale01 = try data.int16(at: offset + 2)
                transform.scale10 = try data.int16(at: offset + 4)
                transform.yScale = try data.int16(at: offset + 6)
                offset += 8
            }

            var part = try self.outline(ofGlyph: component, depth: depth + 1)
            if !transform.isIdentity {
                part = part.map { point in
                    let moved = transform.apply(point.x, point.y)
                    return OutlinePoint(moved.x, moved.y, onCurve: point.isOnCurve)
                }
            }
            let shift: (x: Int, y: Int)
            if isOffset {
                // Whether the offset is transformed too is the font's to say;
                // with neither flag set, the spec says Microsoft's engines
                // leave it unscaled, and so does this.
                let scalesOffset = flags & ComponentFlag.scaledComponentOffset != 0
                    && flags & ComponentFlag.unscaledComponentOffset == 0
                shift = scalesOffset ? transform.apply(first, second) : (first, second)
            } else {
                guard first < outline.points.count, second < part.points.count else {
                    throw .malformed(table: "glyf", reason: "glyph \(glyph) matches point \(first) to \(second)")
                }
                shift = (outline.points[first].x - part.points[second].x, outline.points[first].y - part.points[second].y)
            }
            for contour in part.contours {
                outline.append(contour: contour.map { OutlinePoint($0.x + shift.x, $0.y + shift.y, onCurve: $0.isOnCurve) })
            }
            guard outline.points.count <= Self.maximumPointCount else {
                throw .malformed(table: "glyf", reason: "glyph \(glyph) has more than \(Self.maximumPointCount) points")
            }
        } while flags & ComponentFlag.moreComponents != 0
        return outline
    }
}
