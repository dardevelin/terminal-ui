/// A font's map from Unicode scalars to glyph ids: the one `cmap` subtable
/// chosen from those the font offers (OpenType spec, "cmap — Character to
/// Glyph Index Mapping Table").
struct CharacterMap {
    /// cmap's platform ids: 0 Unicode, 3 Windows.
    private enum Platform {
        static let unicode = 0
        static let windows = 3
    }

    /// The encodings, platform by platform. Windows 1 is Unicode BMP and 10
    /// the full repertoire; Unicode 0–3 are BMP-only encodings and 4 the
    /// full repertoire (5 is variation sequences and 6 format 13's
    /// last-resort mapping, neither of which maps characters to outlines).
    private enum Encoding {
        static let windowsBMP = 1
        static let windowsFullRepertoire = 10
        static let unicodeBMPOnly = 0...3
        static let unicodeFullRepertoire = 4
    }

    /// The subtable formats read here: 4, segment mapping to delta values,
    /// covers the BMP; 12, segmented coverage, covers all of Unicode.
    private enum Format {
        static let segmentMapping = 4
        static let segmentedCoverage = 12
    }

    private enum Layout {
        static let headerSize = 4
        static let encodingRecordSize = 8
        /// Format 4: format, length, language, segCountX2, then the
        /// binary-search fields; endCode starts at 14.
        static let format4EndCodes = 14
        /// The reservedPad between endCode and startCode.
        static let format4Padding = 2
        /// Format 12: format, reserved, length (32-bit), language, numGroups;
        /// groups start at 16, each start, end and start glyph, 32 bits each.
        static let format12Length = 4
        static let format12GroupCount = 12
        static let format12Groups = 16
        static let format12GroupSize = 12
    }

    private enum Subtable {
        case segmentMapping(FontTable, segmentCount: Int)
        case segmentedCoverage(FontTable, groupCount: Int)
    }

    private let subtable: Subtable

    /// The spec's advice ("Windows platform", "Unicode platform"): a font
    /// that maps characters beyond the BMP carries a full-repertoire format
    /// 12 subtable, Windows (3, 10) or Unicode (0, 4), with a BMP format 4
    /// beside it for older readers, (3, 1) or (0, 3). The fullest map read
    /// here wins.
    init(_ table: FontTable) throws(FontError) {
        let recordCount = try table.uint16(at: 2)
        var candidates: [(rank: Int, offset: Int)] = []
        for index in 0..<recordCount {
            let record = Layout.headerSize + index * Layout.encodingRecordSize
            let platform = try table.uint16(at: record)
            let encoding = try table.uint16(at: record + 2)
            let offset = try table.uint32(at: record + 4)
            let format = try table.uint16(at: offset)
            let rank: Int? = switch (platform, encoding, format) {
            case (Platform.windows, Encoding.windowsFullRepertoire, Format.segmentedCoverage): 0
            case (Platform.unicode, Encoding.unicodeFullRepertoire, Format.segmentedCoverage): 1
            case (Platform.windows, Encoding.windowsBMP, Format.segmentMapping): 2
            case (Platform.unicode, Encoding.unicodeBMPOnly, Format.segmentMapping): 3
            default: nil
            }
            if let rank { candidates.append((rank, offset)) }
        }
        guard let chosen = candidates.min(by: { $0.rank < $1.rank }) else { throw .noUnicodeCharacterMap }
        subtable = try Self.subtable(in: table, at: chosen.offset)
    }

    /// The glyph `scalar` maps to; nil for none, or for `.notdef` (glyph 0),
    /// which is what a font maps a character it lacks to.
    func glyphID(for scalar: Unicode.Scalar) -> Int? {
        let code = Int(scalar.value)
        let glyph: Int? = switch subtable {
        case .segmentMapping(let table, let segmentCount):
            try? Self.segmentMappingLookup(code, in: table, segmentCount: segmentCount)
        case .segmentedCoverage(let table, let groupCount):
            try? Self.segmentedCoverageLookup(code, in: table, groupCount: groupCount)
        }
        return glyph.flatMap { $0 == 0 ? nil : $0 }
    }

    private static func subtable(in table: FontTable, at offset: Int) throws(FontError) -> Subtable {
        switch try table.uint16(at: offset) {
        case Format.segmentMapping:
            let length = try table.uint16(at: offset + 2)
            let subtable = try table.subtable(at: offset, length: length)
            let segmentCountTimesTwo = try subtable.uint16(at: 6)
            let segmentCount = segmentCountTimesTwo / 2
            guard segmentCountTimesTwo % 2 == 0, segmentCount > 0 else {
                throw .malformed(table: "cmap", reason: "format 4 has \(segmentCountTimesTwo) as segCountX2")
            }
            // endCode, the pad, then startCode, idDelta and idRangeOffset,
            // each segCount entries of 16 bits.
            let arraysEnd = Layout.format4EndCodes + 4 * segmentCountTimesTwo + Layout.format4Padding
            guard arraysEnd <= length else { throw .truncated("the 'cmap' table") }
            return .segmentMapping(subtable, segmentCount: segmentCount)
        case Format.segmentedCoverage:
            let length = try table.uint32(at: offset + Layout.format12Length)
            let subtable = try table.subtable(at: offset, length: length)
            let groupCount = try subtable.uint32(at: Layout.format12GroupCount)
            guard groupCount <= (length - Layout.format12Groups) / Layout.format12GroupSize else {
                throw .truncated("the 'cmap' table")
            }
            return .segmentedCoverage(subtable, groupCount: groupCount)
        case let format:
            throw .malformed(table: "cmap", reason: "format \(format) chosen")
        }
    }

    /// Format 4: the first segment whose endCode is at least `code`, by
    /// binary search (the spec requires endCode in increasing order); if
    /// its startCode is past `code`, the code is unmapped. A zero
    /// idRangeOffset maps by idDelta, modulo 65536; otherwise it is the
    /// distance in bytes from the idRangeOffset entry itself into
    /// glyphIdArray.
    private static func segmentMappingLookup(_ code: Int, in table: FontTable, segmentCount: Int) throws(FontError) -> Int? {
        guard code <= Int(UInt16.max) else { return nil }
        let endCodes = Layout.format4EndCodes
        let startCodes = endCodes + 2 * segmentCount + Layout.format4Padding
        let idDeltas = startCodes + 2 * segmentCount
        let idRangeOffsets = idDeltas + 2 * segmentCount
        var low = 0
        var high = segmentCount
        while low < high {
            let middle = (low + high) / 2
            if try table.uint16(at: endCodes + 2 * middle) < code { low = middle + 1 } else { high = middle }
        }
        guard low < segmentCount else { return nil }
        let start = try table.uint16(at: startCodes + 2 * low)
        guard start <= code else { return nil }
        let delta = try table.int16(at: idDeltas + 2 * low)
        let rangeOffsetField = idRangeOffsets + 2 * low
        let rangeOffset = try table.uint16(at: rangeOffsetField)
        if rangeOffset == 0 { return (code + delta) & Int(UInt16.max) }
        let glyph = try table.uint16(at: rangeOffsetField + rangeOffset + 2 * (code - start))
        return glyph == 0 ? 0 : (glyph + delta) & Int(UInt16.max)
    }

    /// Format 12: groups sorted by start code, searched in binary.
    private static func segmentedCoverageLookup(_ code: Int, in table: FontTable, groupCount: Int) throws(FontError) -> Int? {
        var low = 0
        var high = groupCount
        while low < high {
            let middle = (low + high) / 2
            let group = Layout.format12Groups + middle * Layout.format12GroupSize
            if try table.uint32(at: group + 4) < code {
                low = middle + 1
            } else if try table.uint32(at: group) > code {
                high = middle
            } else {
                return try table.uint32(at: group + 8) + code - table.uint32(at: group)
            }
        }
        return nil
    }
}
