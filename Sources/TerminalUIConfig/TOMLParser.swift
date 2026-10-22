import Foundation

/// A TOML-subset parser: `[section]` headers, `key = value` pairs whose key
/// is bare or quoted and whose value is a string, a bool, an integer or a
/// single-line list of strings, and `#` comments. No nested tables,
/// multiline strings or datetimes. Every config it writes is valid TOML.
public enum TOMLParser {

    // MARK: - Parse

    /// Parse a TOML string into `[section: [key: value]]`, each value as
    /// its text: what ``document(_:)`` reads, less the line numbers, the
    /// problems and the lists. Top-level keys (before any section header)
    /// use the empty string as section name.
    public static func parse(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        for entry in document(contents).entries {
            let value: String
            switch entry.value {
            case .string(let text): value = text
            case .bool(let flag): value = String(flag)
            case .integer(let number): value = String(number)
            case .strings: continue
            }
            sections[entry.section, default: [:]][entry.key] = value
        }
        return sections
    }

    // MARK: - Write

    /// Serialize sections back to a TOML string.
    /// Sections and keys are written in sorted order for deterministic output.
    public static func write(_ sections: [String: [String: String]]) -> String {
        var output = ""

        let sortedSections = sections.keys.sorted()
        for (index, section) in sortedSections.enumerated() {
            guard let pairs = sections[section], !pairs.isEmpty else { continue }

            if index > 0 { output += "\n" }

            if !section.isEmpty {
                output += "[\(section)]\n"
            }

            for key in pairs.keys.sorted() {
                if let value = pairs[key] {
                    output += "\(key) = \(formatValue(value))\n"
                }
            }
        }

        return output
    }

    // MARK: - Value formatting

    /// Format a value for TOML output.
    /// Bools and integers are written bare. Everything else is quoted.
    private static func formatValue(_ value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if Int(value) != nil {
            return value
        }
        return "\"\(value)\""
    }
}

// MARK: - Document

/// A TOML file read line by line: every entry with the line it came from,
/// and a problem for every line that could not be read, so a file a person
/// wrote can be loaded as far as it is right and its mistakes pointed at.
///
/// The subset `TOMLParser.parse` reads, and more: quoted keys (`"ctrl+k"`
/// is not a bare key), single-line arrays of strings, comments after a
/// value. TOML v1.0.0: basic strings and their escapes (§ String), bare and
/// quoted keys (§ Keys), integers, booleans and arrays (§ Array).
public struct TOMLDocument: Sendable, Equatable {
    /// One `key = value` line.
    public struct Entry: Sendable, Equatable {
        /// The `[section]` above it; empty before the first.
        public let section: String
        public let key: String
        public let value: TOMLValue
        /// 1-based.
        public let line: Int

        public init(section: String, key: String, value: TOMLValue, line: Int) {
            self.section = section
            self.key = key
            self.value = value
            self.line = line
        }
    }

    /// A line that could not be read.
    public struct Problem: Sendable, Equatable, CustomStringConvertible {
        /// 1-based.
        public let line: Int
        public let message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }

        public var description: String { "line \(line): \(message)" }
    }

    public var entries: [Entry] = []
    public var problems: [Problem] = []
}

/// A value in a ``TOMLDocument``.
public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case strings([String])
    case bool(Bool)
    case integer(Int)
}

extension TOMLParser {
    /// Reads `contents` as far as it can; see ``TOMLDocument``.
    public static func document(_ contents: String) -> TOMLDocument {
        var document = TOMLDocument()
        var section = ""
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var scanner = LineScanner(line)
            scanner.skipWhitespace()
            guard !scanner.atEndOrComment else { continue }
            do throws(LineError) {
                if scanner.consume("[") {
                    section = try scanner.sectionName()
                } else {
                    let key = try scanner.key()
                    scanner.skipWhitespace()
                    guard scanner.consume("=") else { throw LineError("expected `=` after the key") }
                    scanner.skipWhitespace()
                    let value = try scanner.value()
                    document.entries.append(.init(section: section, key: key, value: value, line: index + 1))
                }
                scanner.skipWhitespace()
                guard scanner.atEndOrComment else { throw LineError("unexpected text after the value") }
            } catch {
                document.problems.append(.init(line: index + 1, message: error.message))
            }
        }
        return document
    }
}

private struct LineError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One line of a TOML document, read left to right.
private struct LineScanner {
    private let characters: [Character]
    private var position = 0

    init(_ line: Substring) {
        characters = Array(line.hasSuffix("\r") ? line.dropLast() : line)
    }

    private var current: Character? {
        position < characters.count ? characters[position] : nil
    }

    var atEndOrComment: Bool {
        current == nil || current == "#"
    }

    mutating func skipWhitespace() {
        while current == " " || current == "\t" { position += 1 }
    }

    mutating func consume(_ character: Character) -> Bool {
        guard current == character else { return false }
        position += 1
        return true
    }

    mutating func sectionName() throws(LineError) -> String {
        skipWhitespace()
        let name = bareKey()
        skipWhitespace()
        guard !name.isEmpty, consume("]") else { throw LineError("a section is `[name]`") }
        return name
    }

    mutating func key() throws(LineError) -> String {
        if current == "\"" { return try basicString() }
        let key = bareKey()
        guard !key.isEmpty else {
            throw LineError("a key is letters, digits, `_` and `-`, or a quoted string such as \"ctrl+k\"")
        }
        return key
    }

    /// TOML § Keys: A-Z a-z 0-9 _ -.
    private mutating func bareKey() -> String {
        let start = position
        while let character = current, character.isASCII,
              character.isLetter || character.isNumber || character == "_" || character == "-" {
            position += 1
        }
        return String(characters[start..<position])
    }

    mutating func value() throws(LineError) -> TOMLValue {
        switch current {
        case "\"":
            return .string(try basicString())
        case "[":
            position += 1
            return .strings(try stringArray())
        default:
            let start = position
            while let character = current, !character.isWhitespace, character != "#" { position += 1 }
            let word = String(characters[start..<position])
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            if let integer = Int(word.replacingOccurrences(of: "_", with: "")) { return .integer(integer) }
            throw LineError("a value is a quoted string, a list of them in `[ ]`, true, false or a number")
        }
    }

    /// The rest of `[ "a", "b" ]`, after the `[`. A trailing comma is allowed.
    private mutating func stringArray() throws(LineError) -> [String] {
        var strings: [String] = []
        while true {
            skipWhitespace()
            if consume("]") { return strings }
            guard current == "\"" else { throw LineError("a list holds quoted strings, as [\"submit\", \"insertNewline\"]") }
            strings.append(try basicString())
            skipWhitespace()
            if consume(",") { continue }
            guard consume("]") else { throw LineError("a list ends with `]`") }
            return strings
        }
    }

    /// TOML § String, basic strings: `"…"` with backslash escapes.
    private mutating func basicString() throws(LineError) -> String {
        position += 1
        var string = ""
        while let character = current {
            position += 1
            switch character {
            case "\"":
                return string
            case "\\":
                string.append(try escape())
            default:
                string.append(character)
            }
        }
        throw LineError("a string is missing its closing `\"`")
    }

    private mutating func escape() throws(LineError) -> Character {
        guard let character = current else { throw LineError("a string is missing its closing `\"`") }
        position += 1
        switch character {
        case "\"": return "\""
        case "\\": return "\\"
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "u", "U":
            let digits = character == "u" ? 4 : 8
            guard position + digits <= characters.count,
                  let code = UInt32(String(characters[position..<position + digits]), radix: 16),
                  let scalar = Unicode.Scalar(code) else {
                throw LineError("`\\\(character)` takes \(digits) hexadecimal digits")
            }
            position += digits
            return Character(scalar)
        default:
            throw LineError("`\\\(character)` is not an escape TOML knows")
        }
    }
}
