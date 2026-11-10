/// An element of an XML document, read into a tree: the shape a GPX file
/// has, small enough to hold whole.
///
/// Names are kept without their namespace prefix — `gpxtpx:speed` is
/// `speed` — which is how a reader that knows the vocabulary it expects
/// finds its elements whatever prefix the writer chose.
struct XMLNode: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [XMLNode]
    /// The character data directly inside the element, entities decoded,
    /// CDATA sections included as they are.
    var text: String

    init(name: String, attributes: [String: String] = [:], children: [XMLNode] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    /// The first child of that name.
    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// Every child of that name, in order.
    func children(_ name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    /// The text of the first child of that name, trimmed of white space.
    func childText(_ name: String) -> String? {
        child(name).map { $0.text.trimmingXMLWhitespace() }
    }
}

/// Why a document could not be read, and where.
struct XMLReadError: Error, Sendable, Equatable, CustomStringConvertible {
    var reason: String
    /// The byte offset in the document.
    var offset: Int

    var description: String { "XML at byte \(offset): \(reason)" }
}

/// A reader of the XML 1.0 a data file holds (W3C, "Extensible Markup
/// Language (XML) 1.0", fifth edition): elements, attributes in single or
/// double quotes, character data, the five predefined entities and
/// character references, CDATA sections, comments, processing
/// instructions and a document type declaration, the last three skipped.
/// It does not read a DTD or expand entities one declares — GPX declares
/// none — and it does not validate.
enum XMLReader {
    static func parse(_ text: String) throws -> XMLNode {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.document()
    }

    static func parse(_ bytes: [UInt8]) throws -> XMLNode {
        var parser = Parser(bytes: bytes)
        return try parser.document()
    }

    private enum Byte {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let question = UInt8(ascii: "?")
        static let exclamation = UInt8(ascii: "!")
        static let equals = UInt8(ascii: "=")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let ampersand = UInt8(ascii: "&")
        static let semicolon = UInt8(ascii: ";")
        static let colon = UInt8(ascii: ":")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")
        static let hash = UInt8(ascii: "#")
        static let lowercaseX = UInt8(ascii: "x")
        /// The UTF-8 byte order mark, EF BB BF, which may open a document.
        static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

        /// XML's white space: space, tab, carriage return, line feed
        /// (production [3] S).
        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.starts(with: Byte.byteOrderMark) { position = Byte.byteOrderMark.count }
        }

        func fail(_ reason: String) -> XMLReadError { XMLReadError(reason: reason, offset: position) }

        func starts(with literal: String) -> Bool {
            bytes[position...].starts(with: literal.utf8)
        }

        mutating func skip(past literal: String) throws {
            let pattern = Array(literal.utf8)
            while position < bytes.count {
                if bytes[position...].starts(with: pattern) {
                    position += pattern.count
                    return
                }
                position += 1
            }
            throw fail("expected \(literal) before the end")
        }

        mutating func skipWhitespace() {
            while position < bytes.count, Byte.isWhitespace(bytes[position]) { position += 1 }
        }

        /// Comments, processing instructions and a document type
        /// declaration, which can stand outside the root and between
        /// elements.
        mutating func skipMisc() throws -> Bool {
            if starts(with: "<!--") {
                try skip(past: "-->")
            } else if starts(with: "<?") {
                try skip(past: "?>")
            } else if starts(with: "<!DOCTYPE") {
                var depth = 0
                while position < bytes.count {
                    let byte = bytes[position]
                    position += 1
                    if byte == Byte.openBracket { depth += 1 }
                    if byte == Byte.closeBracket { depth -= 1 }
                    if byte == Byte.greaterThan, depth <= 0 { return true }
                }
                throw fail("unterminated document type declaration")
            } else {
                return false
            }
            return true
        }

        mutating func document() throws -> XMLNode {
            while true {
                skipWhitespace()
                guard position < bytes.count else { throw fail("no root element") }
                if try !skipMisc() { break }
            }
            guard bytes[position] == Byte.lessThan else { throw fail("text before the root element") }
            let root = try element()
            while true {
                skipWhitespace()
                guard position < bytes.count else { return root }
                if try !skipMisc() { throw fail("content after the root element") }
            }
        }

        mutating func name() throws -> String {
            let start = position
            while position < bytes.count {
                let byte = bytes[position]
                if Byte.isWhitespace(byte) || byte == Byte.greaterThan || byte == Byte.slash || byte == Byte.equals {
                    break
                }
                position += 1
            }
            guard position > start else { throw fail("expected a name") }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        static func localName(_ qualified: String) -> String {
            guard let colon = qualified.utf8.lastIndex(of: Byte.colon) else { return qualified }
            return String(qualified[qualified.utf8.index(after: colon)...])
        }

        mutating func element() throws -> XMLNode {
            position += 1
            let qualified = try name()
            var node = XMLNode(name: Parser.localName(qualified))
            while true {
                skipWhitespace()
                guard position < bytes.count else { throw fail("unterminated start tag <\(qualified)>") }
                let byte = bytes[position]
                if byte == Byte.slash {
                    position += 1
                    guard position < bytes.count, bytes[position] == Byte.greaterThan else {
                        throw fail("expected > after / in <\(qualified)>")
                    }
                    position += 1
                    return node
                }
                if byte == Byte.greaterThan {
                    position += 1
                    break
                }
                let attribute = try name()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == Byte.equals else {
                    throw fail("expected = after attribute \(attribute)")
                }
                position += 1
                skipWhitespace()
                guard position < bytes.count, bytes[position] == Byte.doubleQuote || bytes[position] == Byte.singleQuote
                else { throw fail("expected a quoted value for \(attribute)") }
                let quote = bytes[position]
                position += 1
                let start = position
                while position < bytes.count, bytes[position] != quote { position += 1 }
                guard position < bytes.count else { throw fail("unterminated value of \(attribute)") }
                let value = try Parser.decodeEntities(bytes[start..<position], at: start)
                position += 1
                if attribute != "xmlns", !attribute.hasPrefix("xmlns:") {
                    node.attributes[Parser.localName(attribute)] = value
                }
            }
            try content(of: &node, qualified: qualified)
            return node
        }

        mutating func content(of node: inout XMLNode, qualified: String) throws {
            var text: [UInt8] = []
            while position < bytes.count {
                if bytes[position] != Byte.lessThan {
                    let start = position
                    while position < bytes.count, bytes[position] != Byte.lessThan { position += 1 }
                    text += Array(try Parser.decodeEntities(bytes[start..<position], at: start).utf8)
                    continue
                }
                if starts(with: "</") {
                    position += 2
                    let closing = try name()
                    guard closing == qualified else {
                        throw fail("</\(closing)> closes <\(qualified)>")
                    }
                    skipWhitespace()
                    guard position < bytes.count, bytes[position] == Byte.greaterThan else {
                        throw fail("expected > to close </\(closing)>")
                    }
                    position += 1
                    node.text = String(decoding: text, as: UTF8.self)
                    return
                }
                if starts(with: "<![CDATA[") {
                    position += "<![CDATA[".utf8.count
                    let start = position
                    try skip(past: "]]>")
                    text += bytes[start..<(position - "]]>".utf8.count)]
                    continue
                }
                if try skipMisc() { continue }
                node.children.append(try element())
            }
            throw fail("<\(qualified)> is never closed")
        }

        /// Character data with `&lt;` `&gt;` `&amp;` `&quot;` `&apos;` and
        /// `&#…;` / `&#x…;` references replaced (XML 1.0 §4.1, §4.6).
        static func decodeEntities(_ slice: ArraySlice<UInt8>, at offset: Int) throws -> String {
            guard slice.contains(Byte.ampersand) else { return String(decoding: slice, as: UTF8.self) }
            var output: [UInt8] = []
            var index = slice.startIndex
            while index < slice.endIndex {
                let byte = slice[index]
                guard byte == Byte.ampersand else {
                    output.append(byte)
                    index += 1
                    continue
                }
                guard let end = slice[index...].firstIndex(of: Byte.semicolon) else {
                    throw XMLReadError(reason: "an & begins no reference", offset: offset + index - slice.startIndex)
                }
                let reference = String(decoding: slice[(index + 1)..<end], as: UTF8.self)
                let scalar: Unicode.Scalar?
                switch reference {
                case "lt": scalar = "<"
                case "gt": scalar = ">"
                case "amp": scalar = "&"
                case "quot": scalar = "\""
                case "apos": scalar = "'"
                default:
                    if reference.utf8.first == Byte.hash {
                        let digits = reference.dropFirst()
                        let hex = digits.utf8.first == Byte.lowercaseX
                        let value = hex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                        scalar = value.flatMap(Unicode.Scalar.init)
                    } else {
                        scalar = nil
                    }
                }
                guard let scalar else {
                    throw XMLReadError(reason: "unknown reference &\(reference);",
                                       offset: offset + index - slice.startIndex)
                }
                output += Array(String(Character(scalar)).utf8)
                index = end + 1
            }
            return String(decoding: output, as: UTF8.self)
        }
    }
}

/// Writes an XML document a line an element, indented, its text and
/// attribute values escaped.
struct XMLWriter: Sendable {
    private(set) var output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    private var open: [String] = []

    private static let indentUnit = "  "

    init() {}

    private var indent: String { String(repeating: XMLWriter.indentUnit, count: open.count) }

    private static func attributes(_ pairs: [(String, String)]) -> String {
        pairs.map { " \($0.0)=\"\(escape($0.1, inAttribute: true))\"" }.joined()
    }

    /// Open an element whose children follow.
    mutating func start(_ name: String, _ attributes: [(String, String)] = []) {
        output += "\(indent)<\(name)\(XMLWriter.attributes(attributes))>\n"
        open.append(name)
    }

    /// Close the element last opened.
    mutating func end() {
        guard let name = open.popLast() else { return }
        output += "\(indent)</\(name)>\n"
    }

    /// An element holding only text.
    mutating func element(_ name: String, _ attributes: [(String, String)] = [], text: String) {
        output += "\(indent)<\(name)\(XMLWriter.attributes(attributes))>\(XMLWriter.escape(text, inAttribute: false))</\(name)>\n"
    }

    /// An element with no content.
    mutating func empty(_ name: String, _ attributes: [(String, String)] = []) {
        output += "\(indent)<\(name)\(XMLWriter.attributes(attributes))/>\n"
    }

    /// `&` and `<` always, `>` so `]]>` cannot appear, and in an attribute
    /// the quote that delimits it (XML 1.0 §2.4, production [10]).
    static func escape(_ text: String, inAttribute: Bool) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"" where inAttribute: escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

extension String {
    /// The string without XML white space at either end.
    func trimmingXMLWhitespace() -> String {
        let scalars = unicodeScalars
        let isSpace: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }
}
