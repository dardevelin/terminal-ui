import Testing
@testable import TerminalUI

// Syntax highlighting infrastructure.
//
// The framework ships:
//   * `SyntaxToken` enum — finite categories (keyword, string, etc.)
//   * `SyntaxHighlighter` protocol — `tokenize(line:)` returns ranges.
//   * `SyntaxTheme` — token → foreground Color map. Default dark theme.
//   * `SwiftSyntaxHighlighter` — naive keyword/string/comment/number tokenizer.
//
// Tests below exercise the protocol contract + the Swift highlighter's
// recognition for the categories named in the spec.

@Suite("SyntaxHighlighter — protocol + theme + Swift tokenizer")
struct SyntaxHighlighterTests {

    // MARK: - SyntaxToken

    @Test("SyntaxToken enum covers every category named in the design spec")
    func tokenCategoriesExist() {
        // If any of these don't compile, the case is missing.
        let _: SyntaxToken = .keyword
        let _: SyntaxToken = .string
        let _: SyntaxToken = .comment
        let _: SyntaxToken = .number
        let _: SyntaxToken = .type
        let _: SyntaxToken = .function
        let _: SyntaxToken = .operatorToken
        let _: SyntaxToken = .plain
    }

    // MARK: - SyntaxTheme

    @Test("Default theme provides distinct colors per token kind")
    func defaultThemeDistinctColors() {
        let theme = SyntaxTheme.defaultDark
        let kw = theme.color(for: .keyword)
        let str = theme.color(for: .string)
        let cmt = theme.color(for: .comment)
        let num = theme.color(for: .number)
        let typ = theme.color(for: .type)
        // Plain falls through to .default and is excluded — the
        // semantic kinds must each have a non-default color.
        let allColors: [Color] = [kw, str, cmt, num, typ]
        let unique = Set(allColors.map { "\($0)" })
        #expect(unique.count == allColors.count,
                "default theme must assign distinct colors per token kind")
    }

    // MARK: - SwiftSyntaxHighlighter — Keywords

    @Test("Recognises the canonical Swift keywords")
    func recognisesKeywords() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "func foo() { return }")
        let kinds = tokens.map(\.token)
        #expect(kinds.contains(.keyword), "should tag at least one keyword")
        // Find the `func` keyword span.
        let funcSpan = tokens.first(where: { $0.token == .keyword })
        #expect(funcSpan != nil)
    }

    @Test("Bare identifier is NOT a keyword")
    func bareIdentifierNotKeyword() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "foo")
        for tok in tokens {
            #expect(tok.token != .keyword, "lowercase identifier 'foo' is not a keyword")
        }
    }

    // MARK: - SwiftSyntaxHighlighter — Strings

    @Test("String literals tagged as .string from open-quote to close-quote")
    func stringLiteralRecognised() {
        let h = SwiftSyntaxHighlighter()
        let line = #"let s = "hello""#
        let tokens = h.tokenize(line: line)
        let stringTokens = tokens.filter { $0.token == .string }
        #expect(!stringTokens.isEmpty, "should tag the literal as .string")
        if let first = stringTokens.first {
            let segment = String(line[first.range])
            #expect(segment.contains("hello"), "string token range should cover the literal contents")
        }
    }

    @Test("String literal with escaped quote is preserved")
    func stringLiteralWithEscape() {
        let h = SwiftSyntaxHighlighter()
        let line = #"let s = "a\"b""#
        let tokens = h.tokenize(line: line)
        let stringTokens = tokens.filter { $0.token == .string }
        #expect(stringTokens.count == 1,
                "escaped \\\" should not split the literal in two; got \(stringTokens.count)")
    }

    // MARK: - SwiftSyntaxHighlighter — Comments

    @Test("Line comment tagged from // to end of line")
    func lineCommentRecognised() {
        let h = SwiftSyntaxHighlighter()
        let line = "let x = 1 // trailing comment"
        let tokens = h.tokenize(line: line)
        let commentTokens = tokens.filter { $0.token == .comment }
        #expect(commentTokens.count == 1)
        if let comment = commentTokens.first {
            let segment = String(line[comment.range])
            #expect(segment.hasPrefix("//"))
            #expect(segment.contains("trailing comment"))
        }
    }

    @Test("Code BEFORE a // comment isn't swallowed by the comment token")
    func codeBeforeCommentTokenisedSeparately() {
        let h = SwiftSyntaxHighlighter()
        let line = "let x = 1 // c"
        let tokens = h.tokenize(line: line)
        // `let` should still be recognised as a keyword.
        #expect(tokens.contains(where: { $0.token == .keyword }),
                "keyword before // must NOT be eaten by the comment token")
    }

    // MARK: - SwiftSyntaxHighlighter — Numbers

    @Test("Integer literals tagged as .number")
    func integerLiteralRecognised() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "let x = 42")
        #expect(tokens.contains(where: { $0.token == .number }))
    }

    @Test("Float literals (with decimal point) tagged as .number")
    func floatLiteralRecognised() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "let x = 3.14")
        #expect(tokens.contains(where: { $0.token == .number }))
    }

    // MARK: - SwiftSyntaxHighlighter — Types

    @Test("UpperCamelCase identifiers tagged as .type")
    func typeRecognised() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "let x: String = \"hi\"")
        #expect(tokens.contains(where: { $0.token == .type }),
                "'String' should be tagged as a type")
    }

    @Test("Lowercase identifier NOT tagged as type")
    func lowercaseNotType() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "let foo = 1")
        // 'foo' must not be a .type
        let fooRanges = tokens.filter { $0.token == .type }
        #expect(fooRanges.isEmpty || !fooRanges.contains(where: { _ in
            // crude search: make sure no .type token covers the `foo` substring
            let line = "let foo = 1"
            return tokens.contains { String(line[$0.range]) == "foo" && $0.token == .type }
        }))
    }

    // MARK: - Empty / no-op input

    @Test("Empty line produces no tokens")
    func emptyLineNoTokens() {
        let h = SwiftSyntaxHighlighter()
        #expect(h.tokenize(line: "").isEmpty)
    }

    @Test("Whitespace-only line produces no semantic tokens")
    func whitespaceLineNoSemanticTokens() {
        let h = SwiftSyntaxHighlighter()
        let tokens = h.tokenize(line: "    ")
        // Either empty OR only .plain — never .keyword / .string / etc.
        for tok in tokens {
            #expect(tok.token == .plain)
        }
    }

    // MARK: - TextArea integration

    @Test("TextArea.buildDisplaySpans applies highlighter colors to plain runs")
    @MainActor
    func textAreaIntegrationAppliesColor() {
        let line = "func foo() { return }"
        let highlighter = SwiftSyntaxHighlighter()
        let theme = SyntaxTheme.defaultDark
        let spans = TextArea.buildDisplaySpans(
            lines: [line],
            cursor: TextAreaCursor(row: 0, col: 0),
            selection: nil,
            scrollOffset: 0,
            visibleHeight: 5,
            lineNumbers: false,
            wrapWidth: line.count,
            highlighter: highlighter,
            theme: theme
        )
        // Confirm at least one span carries the keyword color (magenta in
        // defaultDark). The spans' foreground should NOT all be .default
        // — proves token color is overlaying.
        let foregrounds = spans.compactMap(\.foreground)
        #expect(foregrounds.contains(theme.keyword) || foregrounds.contains(Color.magenta),
                "highlighter-active spans should include the keyword color")
    }

    @Test("TextArea.buildDisplaySpans without highlighter preserves legacy plain spans")
    @MainActor
    func textAreaNoHighlighterPlainSpans() {
        let spans = TextArea.buildDisplaySpans(
            lines: ["func foo()"],
            cursor: TextAreaCursor(row: 0, col: 0),
            selection: nil,
            scrollOffset: 0,
            visibleHeight: 5,
            lineNumbers: false,
            wrapWidth: 100,
            highlighter: nil,
            theme: .defaultDark
        )
        // Without a highlighter, the only colored runs are cursor /
        // selection / line-number markers. No keyword color should
        // appear on the body content.
        let foregrounds = spans.compactMap(\.foreground)
        #expect(!foregrounds.contains(Color.magenta),
                "no highlighter → body spans should not carry syntax colors")
    }
}
