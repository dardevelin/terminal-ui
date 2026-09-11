import Testing
@testable import TerminalUI

// The parser is a value tree with no styling in it, which is what lets the
// whole grammar be tested without a cell buffer.
//
// Scope is set by what a coding agent's output actually contains. The cases
// worth guarding are the ones that break a transcript: a fence that never
// closes because the message is still streaming, a list written directly under
// a sentence, `snake_case` that must not turn into emphasis, and a dangling
// asterisk that must not swallow the rest of the line.

@Suite struct MarkdownParserTests {

    // MARK: - Headings

    @Test func atxHeadingsCarryTheirLevel() {
        #expect(Markdown.parse("# One") == [.heading(level: 1, content: [.text("One")])])
        #expect(Markdown.parse("### Three") == [.heading(level: 3, content: [.text("Three")])])
    }

    /// ATX requires a space after the hashes, so a hashtag stays prose.
    @Test func hashWithoutASpaceIsNotAHeading() {
        #expect(Markdown.parse("#hashtag") == [.paragraph([.text("#hashtag")])])
    }

    /// CommonMark allows one to six hashes; a seventh makes the line a
    /// paragraph rather than clamping it to level six.
    @Test func sevenHashesAreNotAHeading() {
        #expect(Markdown.parse("####### seven") == [.paragraph([.text("####### seven")])])
        guard case .heading(let level, _)? = Markdown.parse("###### six").first else {
            Issue.record("six hashes should still be a heading")
            return
        }
        #expect(level == 6)
    }

    /// Asterisks may open inside a word even though underscores may not.
    @Test func intrawordAsterisksStillEmphasise() {
        #expect(MarkdownInline.parse("a*b*c")
                == [.text("a"), .emphasis([.text("b")]), .text("c")])
    }

    // MARK: - Paragraphs

    @Test func softBreaksJoinIntoOneParagraph() {
        #expect(Markdown.parse("one\ntwo") == [.paragraph([.text("one two")])])
    }

    @Test func blankLinesSeparateParagraphs() {
        #expect(Markdown.parse("one\n\ntwo") == [
            .paragraph([.text("one")]), .paragraph([.text("two")]),
        ])
    }

    /// A list written directly under a sentence is a list, not part of it.
    /// Getting this wrong swallows every bulleted answer an agent gives.
    @Test func aBlockInterruptsAParagraph() {
        let blocks = Markdown.parse("Here they are:\n- first\n- second")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .paragraph([.text("Here they are:")]))
        guard case .bulletList(let items)? = blocks.last else {
            Issue.record("expected a bullet list, got \(String(describing: blocks.last))")
            return
        }
        #expect(items.count == 2)
    }

    // MARK: - Code blocks

    @Test func fencedCodeKeepsItsLinesVerbatim() {
        let blocks = Markdown.parse("```swift\nlet x = 1\n  indented\n```")
        #expect(blocks == [.codeBlock(language: "swift", lines: ["let x = 1", "  indented"])])
    }

    @Test func aFenceWithoutAnInfoStringHasNoLanguage() {
        #expect(Markdown.parse("```\nplain\n```") == [.codeBlock(language: nil, lines: ["plain"])])
    }

    /// A truncated stream is the normal case while an agent is typing — the
    /// content must show rather than be discarded with the broken fence.
    @Test func anUnterminatedFenceRunsToTheEnd() {
        #expect(Markdown.parse("```\nstill typing") == [.codeBlock(language: nil, lines: ["still typing"])])
    }

    @Test func markupInsideCodeIsNotParsed() {
        #expect(Markdown.parse("```\n**not bold**\n```")
                == [.codeBlock(language: nil, lines: ["**not bold**"])])
    }

    // MARK: - Lists

    @Test func orderedListsRememberWhereTheyStart() {
        let blocks = Markdown.parse("3. third\n4. fourth")
        guard case .orderedList(let start, let items)? = blocks.first else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test func listItemsHoldBlocksSoTheyCanNest() {
        let blocks = Markdown.parse("- outer\n  - inner\n- sibling")
        guard case .bulletList(let items)? = blocks.first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.count == 2)
        // The first item holds its own paragraph plus the nested list.
        #expect(items[0].blocks.count == 2)
        guard case .bulletList(let nested) = items[0].blocks[1] else {
            Issue.record("expected a nested list, got \(items[0].blocks[1])")
            return
        }
        #expect(nested.count == 1)
    }

    @Test func aListItemCanHoldACodeBlock() {
        let blocks = Markdown.parse("- run this:\n  ```\n  swift build\n  ```")
        guard case .bulletList(let items)? = blocks.first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items[0].blocks.contains(.codeBlock(language: nil, lines: ["swift build"])))
    }

    @Test func switchingMarkerKindStartsANewList() {
        let blocks = Markdown.parse("- bullet\n1. ordered")
        #expect(blocks.count == 2)
    }

    // MARK: - Quotes and breaks

    @Test func blockQuotesParseTheirContentAsBlocks() {
        let blocks = Markdown.parse("> # quoted heading\n> and prose")
        guard case .blockQuote(let inner)? = blocks.first else {
            Issue.record("expected a block quote")
            return
        }
        #expect(inner.count == 2)
        #expect(inner[0] == .heading(level: 1, content: [.text("quoted heading")]))
    }

    @Test func thematicBreaksAcceptAllThreeGlyphs() {
        #expect(Markdown.parse("---") == [.thematicBreak])
        #expect(Markdown.parse("***") == [.thematicBreak])
        #expect(Markdown.parse("___") == [.thematicBreak])
    }

    @Test func twoDashesAreNotABreak() {
        #expect(Markdown.parse("--") == [.paragraph([.text("--")])])
    }

    // MARK: - Inline

    @Test func strongAndEmphasisNest() {
        #expect(MarkdownInline.parse("**bold**") == [.strong([.text("bold")])])
        #expect(MarkdownInline.parse("*italic*") == [.emphasis([.text("italic")])])
        #expect(MarkdownInline.parse("**a *b* c**")
                == [.strong([.text("a "), .emphasis([.text("b")]), .text(" c")])])
    }

    /// The failure people actually notice: identifiers must survive intact.
    @Test func intrawordUnderscoresAreNotEmphasis() {
        #expect(MarkdownInline.parse("snake_case_name") == [.text("snake_case_name")])
    }

    @Test func aDelimiterAcrossWhitespaceDoesNotPair() {
        #expect(MarkdownInline.parse("a * b * c") == [.text("a * b * c")])
    }

    /// A half-typed message must stay readable rather than having its tail
    /// eaten by an unmatched delimiter.
    @Test func anUnmatchedDelimiterStaysLiteral() {
        #expect(MarkdownInline.parse("a **b") == [.text("a **b")])
    }

    @Test func codeSpansTakeTheirContentVerbatim() {
        #expect(MarkdownInline.parse("`**not bold**`") == [.code("**not bold**")])
    }

    @Test func doubledBackticksCanHoldABacktick() {
        #expect(MarkdownInline.parse("`` ` ``") == [.code("`")])
    }

    @Test func linksKeepTextAndDestinationApart() {
        #expect(MarkdownInline.parse("[docs](https://example.com)")
                == [.link(content: [.text("docs")], destination: "https://example.com")])
    }

    @Test func linkLabelsMayContainBrackets() {
        #expect(MarkdownInline.parse("[a [b] c](u)")
                == [.link(content: [.text("a [b] c")], destination: "u")])
    }

    @Test func escapedPunctuationIsLiteral() {
        #expect(MarkdownInline.parse("\\*not emphasis\\*") == [.text("*not emphasis*")])
    }

    @Test func aBareBracketIsNotALink() {
        #expect(MarkdownInline.parse("[unclosed") == [.text("[unclosed")])
    }

    // MARK: - Whole documents

    @Test func aRealisticMessageParsesIntoItsParts() {
        let source = """
            Found it. The `previousBuffer` field is overloaded.

            ## What changed

            1. Added a `skippedFrame` flag
            2. Left the buffer alone

            > This is the part that bit us.

            ```swift
            if skippedFrame { return }
            ```
            """
        let blocks = Markdown.parse(source)
        #expect(blocks.count == 5)
        guard case .paragraph = blocks[0] else { Issue.record("0: \(blocks[0])"); return }
        guard case .heading(let level, _) = blocks[1], level == 2 else { Issue.record("1"); return }
        guard case .orderedList = blocks[2] else { Issue.record("2: \(blocks[2])"); return }
        guard case .blockQuote = blocks[3] else { Issue.record("3: \(blocks[3])"); return }
        guard case .codeBlock(let language, _) = blocks[4], language == "swift" else {
            Issue.record("4: \(blocks[4])")
            return
        }
    }

    @Test func emptyInputProducesNoBlocks() {
        #expect(Markdown.parse("").isEmpty)
        #expect(Markdown.parse("\n\n\n").isEmpty)
    }
}
