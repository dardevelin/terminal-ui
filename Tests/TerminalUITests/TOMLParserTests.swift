import Testing
@testable import TerminalUIConfig

@Suite("TOMLParser")
struct TOMLParserTests {

    @Test("parse empty string")
    func parseEmpty() {
        let result = TOMLParser.parse("")
        #expect(result.isEmpty)
    }

    @Test("parse top-level key-value")
    func parseTopLevel() {
        let result = TOMLParser.parse("key = \"value\"")
        #expect(result[""]?["key"] == "value")
    }

    @Test("parse section header")
    func parseSection() {
        let input = """
        [diagnostics]
        trace = true
        """
        let result = TOMLParser.parse(input)
        #expect(result["diagnostics"]?["trace"] == "true")
    }

    @Test("parse multiple sections")
    func parseMultipleSections() {
        let input = """
        [diagnostics]
        trace = true

        [keybindings]
        toggle_overlay = "F1"
        """
        let result = TOMLParser.parse(input)
        #expect(result["diagnostics"]?["trace"] == "true")
        #expect(result["keybindings"]?["toggle_overlay"] == "F1")
    }

    @Test("parse integer value")
    func parseInteger() {
        let result = TOMLParser.parse("frame_limit = 50")
        #expect(result[""]?["frame_limit"] == "50")
    }

    @Test("parse bool value")
    func parseBool() {
        let result = TOMLParser.parse("enabled = true")
        #expect(result[""]?["enabled"] == "true")
    }

    @Test("strips quotes from string values")
    func stripsQuotes() {
        let result = TOMLParser.parse("name = \"hello world\"")
        #expect(result[""]?["name"] == "hello world")
    }

    @Test("skips comment lines")
    func skipsComments() {
        let input = """
        # this is a comment
        key = "value"
        # another comment
        """
        let result = TOMLParser.parse(input)
        #expect(result[""]?["key"] == "value")
        #expect(result[""]?.count == 1)
    }

    @Test("skips blank lines")
    func skipsBlankLines() {
        let input = """
        key1 = "a"


        key2 = "b"
        """
        let result = TOMLParser.parse(input)
        #expect(result[""]?["key1"] == "a")
        #expect(result[""]?["key2"] == "b")
    }

    @Test("handles whitespace around keys and values")
    func handlesWhitespace() {
        let result = TOMLParser.parse("  key   =   \"value\"  ")
        #expect(result[""]?["key"] == "value")
    }

    @Test("write empty sections produces empty string")
    func writeEmpty() {
        let output = TOMLParser.write([:])
        #expect(output.isEmpty)
    }

    @Test("write single section")
    func writeSingleSection() {
        let output = TOMLParser.write(["diagnostics": ["trace": "true"]])
        #expect(output.contains("[diagnostics]"))
        #expect(output.contains("trace = true"))
    }

    @Test("write formats bools bare")
    func writeBoolBare() {
        let output = TOMLParser.write(["": ["flag": "true"]])
        #expect(output.contains("flag = true"))
        #expect(!output.contains("\"true\""))
    }

    @Test("write formats integers bare")
    func writeIntegerBare() {
        let output = TOMLParser.write(["": ["count": "42"]])
        #expect(output.contains("count = 42"))
        #expect(!output.contains("\"42\""))
    }

    @Test("write quotes non-bool non-int strings")
    func writeQuotesStrings() {
        let output = TOMLParser.write(["": ["name": "hello"]])
        #expect(output.contains("name = \"hello\""))
    }

    @Test("write sorts sections and keys deterministically")
    func writeIsSorted() {
        let input: [String: [String: String]] = [
            "zeta": ["b": "1", "a": "2"],
            "alpha": ["y": "3", "x": "4"],
        ]
        let output = TOMLParser.write(input)
        let alphaIdx = output.range(of: "[alpha]")!.lowerBound
        let zetaIdx = output.range(of: "[zeta]")!.lowerBound
        #expect(alphaIdx < zetaIdx)
        let xIdx = output.range(of: "x =")!.lowerBound
        let yIdx = output.range(of: "y =")!.lowerBound
        #expect(xIdx < yIdx)
    }

    @Test("round-trip preserves data")
    func roundTrip() {
        let original: [String: [String: String]] = [
            "diagnostics": ["trace": "true", "frame_limit": "50"],
            "keybindings": ["toggle_overlay": "F1", "toggle_panel": "F2"],
        ]
        let serialized = TOMLParser.write(original)
        let parsed = TOMLParser.parse(serialized)
        #expect(parsed["diagnostics"]?["trace"] == "true")
        #expect(parsed["diagnostics"]?["frame_limit"] == "50")
        #expect(parsed["keybindings"]?["toggle_overlay"] == "F1")
        #expect(parsed["keybindings"]?["toggle_panel"] == "F2")
    }

    @Test("ignores lines without equals sign")
    func ignoresMalformedLines() {
        let input = """
        key = "value"
        this is not valid
        other = "data"
        """
        let result = TOMLParser.parse(input)
        #expect(result[""]?["key"] == "value")
        #expect(result[""]?["other"] == "data")
        #expect(result[""]?.count == 2)
    }
}

// The keymap file needs what the diagnostics config never did: quoted keys
// ("ctrl+k" is not a bare TOML key), arrays of strings, comments after a
// value, and the line of every entry, so a mistake can be pointed at.
@Suite("TOMLParser.document — keys, arrays, and where each line is")
struct TOMLDocumentTests {

    @Test("Quoted keys, strings, arrays, booleans and integers, each with its line")
    func values() {
        let document = TOMLParser.document("""
        [text]
        "ctrl+k" = "deleteToLineEnd"
        "enter" = ["insertNewline", "submit"]
        bare_key = true
        count = 3
        """)
        #expect(document.problems.isEmpty)
        #expect(document.entries == [
            .init(section: "text", key: "ctrl+k", value: .string("deleteToLineEnd"), line: 2),
            .init(section: "text", key: "enter", value: .strings(["insertNewline", "submit"]), line: 3),
            .init(section: "text", key: "bare_key", value: .bool(true), line: 4),
            .init(section: "text", key: "count", value: .integer(3), line: 5),
        ])
    }

    @Test("An empty array, and comments after a value or on their own line")
    func emptyArrayAndComments() {
        let document = TOMLParser.document("""
        # whole-line comment
        "ctrl+w" = []   # unbind
        "#" = "a # inside a string"
        """)
        #expect(document.problems.isEmpty)
        #expect(document.entries.map(\.value) == [.strings([]), .string("a # inside a string")])
        #expect(document.entries.map(\.key) == ["ctrl+w", "#"])
    }

    @Test("Escapes in strings and keys")
    func escapes() {
        let document = TOMLParser.document(#""a\"b" = "x\\y\tz""#)
        #expect(document.entries.first?.key == "a\"b")
        #expect(document.entries.first?.value == .string("x\\y\tz"))
    }

    @Test("A malformed line is reported with its line, and the rest still loads")
    func problems() {
        let document = TOMLParser.document("""
        [text]
        "ctrl+k" = "deleteToLineEnd"
        no equals sign here
        "ctrl+u" = "unterminated
        "ctrl+y" = yank
        "ctrl+a" = "moveToLineStart"
        """)
        #expect(document.entries.map(\.key) == ["ctrl+k", "ctrl+a"])
        #expect(document.problems.map(\.line) == [3, 4, 5])
    }
}

