// The `.tuirec` recording log, version 1: one JSON object per line (JSON
// Lines), written by the debug runtime's frame recorder and read by `swtui`.
//
// Every picture of the framework is rendered from these logs, on macOS and
// on Linux, so the writer is hand-rolled rather than left to a JSON encoder
// whose key order, number formatting and escaping are its own: keys in a
// fixed order, integers only, and the escapes RFC 8259 §7 requires and
// nothing else. The same lines give the same bytes on every system.
//
// This file knows nothing of TerminalUI's types. Colours arrive as the
// spellings the log keeps — `null` for the terminal's own, the 16 palette
// names (`red`, `gray`, `brightWhite`…), `idx:N`, `rgb:rrggbb` — because
// resolving them to pixels is the renderer's choice of palette.

/// The format's constants.
package enum RecordingLog {
    /// The version this file writes and reads, the header's `tuirec` value.
    package static let version = 1
    /// The extension a recording's file is given.
    package static let fileExtension = "tuirec"
}

// MARK: - Lines

/// How a style draws, with its colours as the log spells them; `nil` is
/// the terminal's own.
package struct RecordedStyle: Hashable, Sendable {
    package var foreground: String?
    package var background: String?
    package var bold: Bool
    package var italic: Bool
    package var underline: Bool

    package init(foreground: String? = nil, background: String? = nil,
                 bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// Adjacent cells of one style, one `Character` per cell.
package struct RecordedRun: Equatable, Sendable {
    package var style: Int
    package var cells: [Character]

    package init(style: Int, cells: [Character]) {
        self.style = style
        self.cells = cells
    }
}

/// One row of the screen, whole, as runs of cells.
package struct RecordedRow: Equatable, Sendable {
    package var index: Int
    package var runs: [RecordedRun]

    package init(index: Int, runs: [RecordedRun]) {
        self.index = index
        self.runs = runs
    }

    /// The row whose cell `i` is `characters[i]` drawn in `styles[i]`,
    /// adjacent cells of a style gathered into one run.
    package init(index: Int, styles: [Int], characters: [Character]) {
        precondition(styles.count == characters.count, "a style for every cell")
        var runs: [RecordedRun] = []
        for (style, character) in zip(styles, characters) {
            if runs.last?.style == style {
                runs[runs.count - 1].cells.append(character)
            } else {
                runs.append(RecordedRun(style: style, cells: [character]))
            }
        }
        self.init(index: index, runs: runs)
    }

    /// Every cell's character, left to right.
    package var characters: [Character] { runs.flatMap(\.cells) }
}

/// The header's `env`: a variable of the recorded app's environment.
package struct RecordedVariable: Equatable, Sendable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The first line: the screen's size and what the app ran as.
package struct RecordingHeader: Equatable, Sendable {
    package var cols: Int
    package var rows: Int
    package var cursorVisible: Bool
    package var app: String
    /// In the order they are written.
    package var environment: [RecordedVariable]

    package init(cols: Int, rows: Int, cursorVisible: Bool, app: String, environment: [RecordedVariable]) {
        self.cols = cols
        self.rows = rows
        self.cursorVisible = cursorVisible
        self.app = app
        self.environment = environment
    }
}

/// A frame the runtime drew: the rows that changed since the frame before
/// it, and every row of the first.
package struct RecordedFrame: Equatable, Sendable {
    /// Microseconds since the recording started.
    package var time: Int
    /// The runtime's frame counter.
    package var number: Int
    /// The colour behind the whole terminal, present only when it changed:
    /// `nil` is unchanged, `.some(nil)` the terminal's own again.
    package var windowBackground: String??
    package var rows: [RecordedRow]

    package init(time: Int, number: Int, windowBackground: String??, rows: [RecordedRow]) {
        self.time = time
        self.number = number
        self.windowBackground = windowBackground
        self.rows = rows
    }
}

/// One line of a log. Times are microseconds since the recording started.
package enum RecordingLine: Equatable, Sendable {
    case header(RecordingHeader)
    /// A style, declared once, before the first frame that uses it.
    case style(id: Int, RecordedStyle)
    case frame(RecordedFrame)
    /// A named moment; `holdMs` is how long a picture should show it.
    case mark(time: Int, label: String, holdMs: Int?)
    /// The screen's new size; the frame after it holds every row.
    case resize(time: Int, cols: Int, rows: Int)
    /// The recording was stopped, with how many frames and marks it holds.
    case end(time: Int, frames: Int, marks: Int)
}

// MARK: - Writing

/// Lines encoded into bytes, held until the owner takes them to write.
package struct RecordingLogWriter: Sendable {
    package private(set) var bytes: [UInt8] = []

    package init() {}

    package mutating func write(_ line: RecordingLine) {
        bytes.append(contentsOf: line.json.utf8)
        bytes.append(JSONByte.newline)
    }

    /// The bytes written since the last take.
    package mutating func takeBytes() -> [UInt8] {
        defer { bytes.removeAll(keepingCapacity: true) }
        return bytes
    }
}

extension RecordingLine {
    /// The line as the log holds it, without its newline.
    package var json: String {
        switch self {
        case .header(let header):
            let environment = header.environment
                .map { "\(quoted($0.name)):\(quoted($0.value))" }
                .joined(separator: ",")
            return "{\"tuirec\":\(RecordingLog.version),\"cols\":\(header.cols),\"rows\":\(header.rows)"
                + ",\"cursor\":\(quoted(header.cursorVisible ? CursorSpelling.visible : CursorSpelling.hidden))"
                + ",\"app\":\(quoted(header.app)),\"env\":{\(environment)}}"
        case .style(let id, let style):
            var text = "{\"style\":\(id),\"fg\":\(nullable(style.foreground)),\"bg\":\(nullable(style.background))"
            if style.bold { text += ",\"bold\":true" }
            if style.italic { text += ",\"italic\":true" }
            if style.underline { text += ",\"underline\":true" }
            return text + "}"
        case .frame(let frame):
            var text = "{\"t\":\(frame.time),\"frame\":\(frame.number)"
            if let change = frame.windowBackground {
                text += ",\"windowBg\":\(nullable(change))"
            }
            let rows = frame.rows.map { row in
                "[\(row.index),[\(row.runs.map(encodedRun).joined(separator: ","))]]"
            }
            return text + ",\"rows\":[\(rows.joined(separator: ","))]}"
        case .mark(let time, let label, let holdMs):
            var text = "{\"t\":\(time),\"mark\":\(quoted(label))"
            if let holdMs { text += ",\"hold\":\(holdMs)" }
            return text + "}"
        case .resize(let time, let cols, let rows):
            return "{\"t\":\(time),\"resize\":[\(cols),\(rows)]}"
        case .end(let time, let frames, let marks):
            return "{\"t\":\(time),\"end\":true,\"frames\":\(frames),\"marks\":\(marks)}"
        }
    }
}

/// A run as `[style,"text"]`, which a reader splits into one cell per
/// `Character`. Where the cells' characters, side by side, would join into
/// fewer graphemes — two regional indicators become one flag (UAX #29,
/// GB12/GB13) — the text would read back as fewer cells, so the run is
/// written `[style,["c","e","l","l"]]` instead.
private func encodedRun(_ run: RecordedRun) -> String {
    let text = String(run.cells)
    if Array(text) == run.cells {
        return "[\(run.style),\(quoted(text))]"
    }
    return "[\(run.style),[\(run.cells.map { quoted(String($0)) }.joined(separator: ","))]]"
}

private enum CursorSpelling {
    static let hidden = "hidden"
    static let visible = "visible"
}

private func nullable(_ text: String?) -> String {
    text.map(quoted) ?? "null"
}

/// A JSON string (RFC 8259 §7): the quotation mark, the reverse solidus and
/// the controls U+0000–U+001F escaped, the five with a short escape by it,
/// the rest as `\u00XX` in lowercase hex; everything else as it is, in UTF-8.
private func quoted(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case UInt32(JSONByte.quote): out += "\\\""
        case UInt32(JSONByte.reverseSolidus): out += "\\\\"
        case UInt32(JSONByte.backspace): out += "\\b"
        case UInt32(JSONByte.formFeed): out += "\\f"
        case UInt32(JSONByte.newline): out += "\\n"
        case UInt32(JSONByte.carriageReturn): out += "\\r"
        case UInt32(JSONByte.tab): out += "\\t"
        case 0..<UInt32(JSONByte.space):
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

// MARK: - Reading

/// Why a log could not be read, and on which line (1-based).
package struct RecordingLogError: Error, Equatable, CustomStringConvertible {
    package var line: Int?
    package var reason: String

    package init(line: Int? = nil, _ reason: String) {
        self.line = line
        self.reason = reason
    }

    package var description: String {
        line.map { "line \($0): \(reason)" } ?? reason
    }
}

package enum RecordingLogReader {
    /// Every line of a log. Keys may come in any order, and keys this
    /// version does not know are passed over.
    package static func lines(in bytes: some Collection<UInt8>) throws(RecordingLogError) -> [RecordingLine] {
        var lines: [RecordingLine] = []
        for (offset, slice) in bytes.split(separator: JSONByte.newline, omittingEmptySubsequences: false).enumerated() {
            if slice.isEmpty { continue }
            do throws(RecordingLogError) {
                var parser = JSONParser(bytes: Array(slice))
                lines.append(try RecordingLine(parser.document()))
            } catch {
                throw RecordingLogError(line: offset + 1, error.reason)
            }
        }
        return lines
    }
}

extension RecordingLine {
    fileprivate init(_ value: JSONValue) throws(RecordingLogError) {
        guard case .object(let pairs) = value else { throw RecordingLogError("a line is an object") }
        let fields = Fields(pairs: pairs)
        if fields.has("tuirec") {
            guard try fields.integer("tuirec") == RecordingLog.version else {
                throw RecordingLogError("not a version \(RecordingLog.version) log")
            }
            let cursor = try fields.string("cursor")
            guard cursor == CursorSpelling.hidden || cursor == CursorSpelling.visible else {
                throw RecordingLogError("cursor is \(CursorSpelling.hidden) or \(CursorSpelling.visible)")
            }
            guard case .object(let variables) = try fields.value("env") else {
                throw RecordingLogError("env is an object")
            }
            let environment = try variables.map { pair throws(RecordingLogError) in
                guard case .string(let value) = pair.value else { throw RecordingLogError("env values are strings") }
                return RecordedVariable(name: pair.key, value: value)
            }
            self = .header(RecordingHeader(
                cols: try fields.integer("cols"), rows: try fields.integer("rows"),
                cursorVisible: cursor == CursorSpelling.visible, app: try fields.string("app"),
                environment: environment))
        } else if fields.has("style") {
            self = .style(id: try fields.integer("style"), RecordedStyle(
                foreground: try fields.nullableString("fg"), background: try fields.nullableString("bg"),
                bold: try fields.flag("bold"), italic: try fields.flag("italic"),
                underline: try fields.flag("underline")))
        } else if fields.has("frame") {
            var windowBackground: String?? = nil
            if fields.has("windowBg") { windowBackground = .some(try fields.nullableString("windowBg")) }
            self = .frame(RecordedFrame(
                time: try fields.integer("t"), number: try fields.integer("frame"),
                windowBackground: windowBackground,
                rows: try fields.array("rows").map(RecordedRow.init(json:))))
        } else if fields.has("mark") {
            self = .mark(time: try fields.integer("t"), label: try fields.string("mark"),
                         holdMs: try fields.has("hold") ? fields.integer("hold") : nil)
        } else if fields.has("resize") {
            let size = try fields.array("resize")
            guard size.count == 2, case .integer(let cols) = size[0], case .integer(let rows) = size[1] else {
                throw RecordingLogError("resize is [cols,rows]")
            }
            self = .resize(time: try fields.integer("t"), cols: cols, rows: rows)
        } else if fields.has("end") {
            self = .end(time: try fields.integer("t"), frames: try fields.integer("frames"),
                        marks: try fields.integer("marks"))
        } else {
            throw RecordingLogError("not a line this version knows")
        }
    }
}

extension RecordedRow {
    fileprivate init(json value: JSONValue) throws(RecordingLogError) {
        guard case .array(let pair) = value, pair.count == 2,
              case .integer(let index) = pair[0], case .array(let runs) = pair[1] else {
            throw RecordingLogError("a row is [index,[runs]]")
        }
        self.init(index: index, runs: try runs.map(RecordedRun.init(json:)))
    }
}

extension RecordedRun {
    fileprivate init(json value: JSONValue) throws(RecordingLogError) {
        guard case .array(let pair) = value, pair.count == 2, case .integer(let style) = pair[0] else {
            throw RecordingLogError("a run is [style,text]")
        }
        switch pair[1] {
        case .string(let text):
            self.init(style: style, cells: Array(text))
        case .array(let cells):
            let characters = try cells.map { cell throws(RecordingLogError) -> Character in
                guard case .string(let text) = cell, text.count == 1, let character = text.first else {
                    throw RecordingLogError("a run's cells are one character each")
                }
                return character
            }
            self.init(style: style, cells: characters)
        default:
            throw RecordingLogError("a run's cells are text or a list of characters")
        }
    }
}

/// An object's members, looked up by key; a key given twice is its last.
private struct Fields {
    let pairs: [(key: String, value: JSONValue)]

    func has(_ key: String) -> Bool {
        pairs.contains { $0.key == key }
    }

    func value(_ key: String) throws(RecordingLogError) -> JSONValue {
        guard let pair = pairs.last(where: { $0.key == key }) else { throw RecordingLogError("no \(key)") }
        return pair.value
    }

    func integer(_ key: String) throws(RecordingLogError) -> Int {
        guard case .integer(let number) = try value(key) else { throw RecordingLogError("\(key) is an integer") }
        return number
    }

    func string(_ key: String) throws(RecordingLogError) -> String {
        guard case .string(let text) = try value(key) else { throw RecordingLogError("\(key) is a string") }
        return text
    }

    /// Absent or `null` is nil.
    func nullableString(_ key: String) throws(RecordingLogError) -> String? {
        guard has(key) else { return nil }
        switch try value(key) {
        case .null: return nil
        case .string(let text): return text
        default: throw RecordingLogError("\(key) is a string or null")
        }
    }

    /// Absent is false.
    func flag(_ key: String) throws(RecordingLogError) -> Bool {
        guard has(key) else { return false }
        guard case .bool(let flag) = try value(key) else { throw RecordingLogError("\(key) is true or false") }
        return flag
    }

    func array(_ key: String) throws(RecordingLogError) -> [JSONValue] {
        guard case .array(let elements) = try value(key) else { throw RecordingLogError("\(key) is a list") }
        return elements
    }
}

// MARK: - JSON

/// The JSON a log is made of (RFC 8259) less fractions and exponents,
/// which the log never holds.
private enum JSONValue {
    case null
    case bool(Bool)
    case integer(Int)
    case string(String)
    case array([JSONValue])
    /// In the order the members came.
    case object([(key: String, value: JSONValue)])
}

/// The bytes RFC 8259 gives a meaning.
private enum JSONByte {
    static let backspace = UInt8(0x08)
    static let tab = UInt8(0x09)
    static let newline = UInt8(0x0A)
    static let formFeed = UInt8(0x0C)
    static let carriageReturn = UInt8(0x0D)
    static let space = UInt8(0x20)
    static let quote = UInt8(ascii: "\"")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let minus = UInt8(ascii: "-")
    static let period = UInt8(ascii: ".")
    static let solidus = UInt8(ascii: "/")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let colon = UInt8(ascii: ":")
    static let openBracket = UInt8(ascii: "[")
    static let reverseSolidus = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let lowerE = UInt8(ascii: "e")
    static let upperE = UInt8(ascii: "E")
}

/// UTF-16 surrogates (Unicode §3.8), which a `\u` escape spells a scalar
/// above the Basic Multilingual Plane with: a high one, then a low one.
private enum Surrogate {
    static let high: ClosedRange<UInt32> = 0xD800...0xDBFF
    static let low: ClosedRange<UInt32> = 0xDC00...0xDFFF
    static let planeOffset: UInt32 = 0x10000
    static let bitsPerHalf: UInt32 = 10
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    /// One value and nothing after it but white space.
    mutating func document() throws(RecordingLogError) -> JSONValue {
        let value = try parseValue()
        skipWhiteSpace()
        guard index == bytes.count else { throw RecordingLogError("more after the object") }
        return value
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhiteSpace() {
        while let byte = current, byte == JSONByte.space || byte == JSONByte.tab
                || byte == JSONByte.newline || byte == JSONByte.carriageReturn {
            index += 1
        }
    }

    private mutating func expect(_ byte: UInt8) throws(RecordingLogError) {
        guard current == byte else { throw RecordingLogError("expected \(Character(Unicode.Scalar(byte)))") }
        index += 1
    }

    private mutating func consume(_ literal: String) -> Bool {
        let literalBytes = Array(literal.utf8)
        guard bytes[index...].starts(with: literalBytes) else { return false }
        index += literalBytes.count
        return true
    }

    private mutating func parseValue() throws(RecordingLogError) -> JSONValue {
        skipWhiteSpace()
        switch current {
        case JSONByte.openBrace: return try parseObject()
        case JSONByte.openBracket: return try parseArray()
        case JSONByte.quote: return .string(try parseString())
        case .some(let byte) where byte == JSONByte.minus || (JSONByte.zero...JSONByte.nine).contains(byte):
            return .integer(try parseInteger())
        default:
            if consume("null") { return .null }
            if consume("true") { return .bool(true) }
            if consume("false") { return .bool(false) }
            throw RecordingLogError("not a value")
        }
    }

    private mutating func parseObject() throws(RecordingLogError) -> JSONValue {
        try expect(JSONByte.openBrace)
        var pairs: [(key: String, value: JSONValue)] = []
        skipWhiteSpace()
        if current == JSONByte.closeBrace {
            index += 1
            return .object(pairs)
        }
        while true {
            skipWhiteSpace()
            let key = try parseString()
            skipWhiteSpace()
            try expect(JSONByte.colon)
            let value = try parseValue()
            pairs.append((key, value))
            skipWhiteSpace()
            if current == JSONByte.comma {
                index += 1
                continue
            }
            try expect(JSONByte.closeBrace)
            return .object(pairs)
        }
    }

    private mutating func parseArray() throws(RecordingLogError) -> JSONValue {
        try expect(JSONByte.openBracket)
        var elements: [JSONValue] = []
        skipWhiteSpace()
        if current == JSONByte.closeBracket {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try parseValue())
            skipWhiteSpace()
            if current == JSONByte.comma {
                index += 1
                continue
            }
            try expect(JSONByte.closeBracket)
            return .array(elements)
        }
    }

    /// An integer as RFC 8259 §6 writes one: no leading zeros, no plus.
    private mutating func parseInteger() throws(RecordingLogError) -> Int {
        let start = index
        if current == JSONByte.minus { index += 1 }
        let digitsStart = index
        while let byte = current, (JSONByte.zero...JSONByte.nine).contains(byte) { index += 1 }
        let digits = index - digitsStart
        guard digits > 0, !(digits > 1 && bytes[digitsStart] == JSONByte.zero) else {
            throw RecordingLogError("not an integer")
        }
        if let byte = current, [JSONByte.period, JSONByte.lowerE, JSONByte.upperE, JSONByte.plus].contains(byte) {
            throw RecordingLogError("numbers in a log are integers")
        }
        guard let number = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw RecordingLogError("an integer out of range")
        }
        return number
    }

    private mutating func parseString() throws(RecordingLogError) -> String {
        try expect(JSONByte.quote)
        var utf8: [UInt8] = []
        while true {
            guard let byte = current else { throw RecordingLogError("a string with no end") }
            index += 1
            switch byte {
            case JSONByte.quote:
                guard let text = String(validating: utf8, as: UTF8.self) else {
                    throw RecordingLogError("a string that is not UTF-8")
                }
                return text
            case JSONByte.reverseSolidus:
                try appendEscape(to: &utf8)
            case 0..<JSONByte.space:
                throw RecordingLogError("a control character in a string")
            default:
                utf8.append(byte)
            }
        }
    }

    private mutating func appendEscape(to utf8: inout [UInt8]) throws(RecordingLogError) {
        guard let byte = current else { throw RecordingLogError("a string with no end") }
        index += 1
        let simple: [UInt8: UInt8] = [
            JSONByte.quote: JSONByte.quote, JSONByte.reverseSolidus: JSONByte.reverseSolidus,
            JSONByte.solidus: JSONByte.solidus, UInt8(ascii: "b"): JSONByte.backspace,
            UInt8(ascii: "f"): JSONByte.formFeed, UInt8(ascii: "n"): JSONByte.newline,
            UInt8(ascii: "r"): JSONByte.carriageReturn, UInt8(ascii: "t"): JSONByte.tab,
        ]
        if let escaped = simple[byte] {
            utf8.append(escaped)
            return
        }
        guard byte == UInt8(ascii: "u") else { throw RecordingLogError("an unknown escape") }
        var value = try parseHexQuad()
        if Surrogate.high.contains(value) {
            guard consume("\\u") else { throw RecordingLogError("a high surrogate alone") }
            let low = try parseHexQuad()
            guard Surrogate.low.contains(low) else { throw RecordingLogError("a high surrogate alone") }
            value = Surrogate.planeOffset
                + ((value - Surrogate.high.lowerBound) << Surrogate.bitsPerHalf)
                + (low - Surrogate.low.lowerBound)
        }
        guard let scalar = Unicode.Scalar(value) else { throw RecordingLogError("a low surrogate alone") }
        utf8.append(contentsOf: String(scalar).utf8)
    }

    private mutating func parseHexQuad() throws(RecordingLogError) -> UInt32 {
        let hexDigits = 4
        guard index + hexDigits <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + hexDigits], as: UTF8.self), radix: 16)
        else { throw RecordingLogError("\\u takes four hex digits") }
        index += hexDigits
        return value
    }
}

// MARK: - Replaying

/// The screen a log shows at a moment: its frames applied in order, from
/// the header to that moment.
package struct RecordingScreen: Sendable {
    /// A cell as drawn; `style` is nil for a cell no frame has drawn.
    package struct Cell: Equatable, Sendable {
        package var character: Character
        package var style: Int?
    }

    /// The moment to stop at.
    package enum Position: Equatable, Sendable {
        /// After the last line.
        case end
        /// After the frame the runtime counted as this one.
        case frame(Int)
        /// As the screen was when the first mark with this label was made.
        case mark(String)
    }

    package private(set) var header: RecordingHeader
    package private(set) var cells: [[Cell]]
    package private(set) var styles: [Int: RecordedStyle] = [:]
    /// The colour behind the whole terminal; nil is the terminal's own.
    package private(set) var windowBackground: String?
    /// The last frame applied.
    package private(set) var frameNumber: Int?

    package init(header: RecordingHeader) {
        self.header = header
        self.cells = Self.blank(cols: header.cols, rows: header.rows)
    }

    private static func blank(cols: Int, rows: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(character: " ", style: nil), count: max(cols, 0)), count: max(rows, 0))
    }

    /// Each row's characters, one per cell.
    package var textRows: [String] {
        cells.map { String($0.map(\.character)) }
    }

    package mutating func apply(_ line: RecordingLine) {
        switch line {
        case .header, .mark, .end:
            break
        case .style(let id, let style):
            styles[id] = style
        case .resize(_, let cols, let rows):
            cells = Self.blank(cols: cols, rows: rows)
        case .frame(let frame):
            if let change = frame.windowBackground { windowBackground = change }
            for row in frame.rows where cells.indices.contains(row.index) {
                var column = 0
                for run in row.runs {
                    for character in run.cells where column < cells[row.index].count {
                        cells[row.index][column] = Cell(character: character, style: run.style)
                        column += 1
                    }
                }
            }
            frameNumber = frame.number
        }
    }

    /// The screen `lines` show at `position`.
    package static func replay(_ lines: [RecordingLine], to position: Position) throws(RecordingLogError) -> RecordingScreen {
        guard case .header(let header) = lines.first else { throw RecordingLogError("the log has no header") }
        var screen = RecordingScreen(header: header)
        for line in lines.dropFirst() {
            if case .mark(_, let label, _) = line, position == .mark(label) { return screen }
            screen.apply(line)
            if case .frame(let frame) = line, position == .frame(frame.number) { return screen }
        }
        switch position {
        case .end: return screen
        case .frame(let number): throw RecordingLogError("the log has no frame \(number)")
        case .mark(let label): throw RecordingLogError("the log has no mark \(label)")
        }
    }
}
