/// Why a font file could not be read. A font comes from wherever the user
/// pointed the renderer, so every way it can be wrong is an error here,
/// never a trap.
package enum FontError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A read ran past the end of the named table, or of the file.
    case truncated(String)
    /// The file holds CFF outlines (sfnt version `OTTO`), which this
    /// rasterizer does not draw: they go to the system engine.
    case cffOutlines
    /// The first four bytes are no sfnt version or collection tag this
    /// reader knows.
    case unknownSignature(UInt32)
    case missingTable(String)
    /// A collection was asked for a face it does not hold.
    case faceOutOfRange(index: Int, count: Int)
    /// A table whose fields contradict each other or the file.
    case malformed(table: String, reason: String)
    /// No `cmap` subtable maps Unicode in a format read here (4 or 12).
    case noUnicodeCharacterMap
    /// A composite glyph nests deeper than `TrueTypeFont.maximumComponentDepth`,
    /// which is also how a composite that contains itself ends.
    case compositeTooDeep(glyph: Int)

    package var description: String {
        switch self {
        case .truncated(let place): "the font is truncated: a read runs past the end of \(place)"
        case .cffOutlines:
            "the font has CFF outlines (an OTTO font), which the builtin engine does not draw: "
                + "render it with the system engine"
        case .unknownSignature(let tag): "not a TrueType font or collection (it begins 0x\(String(tag, radix: 16)))"
        case .missingTable(let tag): "the font has no '\(tag)' table"
        case .faceOutOfRange(let index, let count): "face \(index) of a collection of \(count)"
        case .malformed(let table, let reason): "the '\(table)' table is malformed: \(reason)"
        case .noUnicodeCharacterMap: "the font has no Unicode character map in format 4 or 12"
        case .compositeTooDeep(let glyph): "composite glyph \(glyph) nests too deeply, or contains itself"
        }
    }
}

/// A window onto one table of a font file: every read is big-endian, as
/// all OpenType data is (OpenType spec, "Data types"), and is checked
/// against the window, so a bad offset or length surfaces as
/// `FontError.truncated` naming the table.
struct FontTable {
    let bytes: [UInt8]
    let start: Int
    let length: Int
    let name: String

    /// The whole file, for the headers that come before any table.
    init(file bytes: [UInt8]) {
        self.bytes = bytes
        start = 0
        length = bytes.count
        name = "the file"
    }

    init(bytes: [UInt8], start: Int, length: Int, name: String) {
        self.bytes = bytes
        self.start = start
        self.length = length
        self.name = name
    }

    /// The `length` bytes at `offset`, as a table of their own.
    func subtable(at offset: Int, length: Int, name: String? = nil) throws(FontError) -> FontTable {
        try check(offset, length)
        return FontTable(bytes: bytes, start: start + offset, length: length, name: name ?? self.name)
    }

    func uint8(at offset: Int) throws(FontError) -> Int {
        try check(offset, 1)
        return Int(bytes[start + offset])
    }

    func int8(at offset: Int) throws(FontError) -> Int {
        Int(Int8(truncatingIfNeeded: try uint8(at: offset)))
    }

    func uint16(at offset: Int) throws(FontError) -> Int {
        try check(offset, 2)
        return Int(bytes[start + offset]) << 8 | Int(bytes[start + offset + 1])
    }

    func int16(at offset: Int) throws(FontError) -> Int {
        Int(Int16(truncatingIfNeeded: try uint16(at: offset)))
    }

    func uint32(at offset: Int) throws(FontError) -> Int {
        try check(offset, 4)
        return (start + offset..<start + offset + 4).reduce(0) { $0 << 8 | Int(bytes[$1]) }
    }

    /// A four-character tag, as the table directory and collections hold.
    func tag(at offset: Int) throws(FontError) -> String {
        let value = try uint32(at: offset)
        return String(decoding: (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }, as: UTF8.self)
    }

    private func check(_ offset: Int, _ count: Int) throws(FontError) {
        guard offset >= 0, count >= 0, offset <= length - count else { throw .truncated(name) }
    }
}
