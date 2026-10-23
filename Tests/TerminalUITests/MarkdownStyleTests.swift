import Testing
@testable import TerminalUI

// Every markdown element was drawn in one fixed role and nothing but the whole
// theme could change it. Crush keeps its `##` markers, draws inline code as a
// padded chip, and mutes a model's thinking on a block of its own — three
// looks in one app, none expressible. A MarkdownStyle states what it changes;
// everything it leaves unset is drawn as before.

private struct LoudTheme: Theme {
    var accent: Color = .rgb(1, 2, 3)
    var foreground: Color = .rgb(10, 20, 30)
    var foregroundEmphasis: Color = .rgb(11, 21, 31)
    var foregroundMuted: Color = .rgb(12, 22, 32)
    var foregroundSubtle: Color = .rgb(13, 23, 33)
    var secondary: Color = .rgb(14, 24, 34)
    var separator: Color = .rgb(15, 25, 35)
    var backgroundRaised: Color = .rgb(16, 26, 36)
    var background: Color = .rgb(17, 27, 37)
}

/// Colours no theme role above produces, so a cell wearing one can only have
/// come from the style.
private let red = Color.rgb(200, 0, 0)
private let green = Color.rgb(0, 200, 0)
private let blue = Color.rgb(0, 0, 200)

@MainActor
private func render(_ view: some TerminalView, width: Int = 30, height: Int) -> CellBuffer {
    renderedBuffer(view, width: width, height: height, theme: LoudTheme())
}

/// The first cell on row `y` showing `character`.
private func cell(_ character: Character, onRow y: Int, in buffer: CellBuffer) -> Cell? {
    (0..<buffer.width).lazy.map { buffer[$0, y] }.first { $0.character == character }
}

@Suite("MarkdownStyle — element styles a developer sets")
@MainActor
struct MarkdownStyleTests {

    private let document = """
        # One
        ## Two
        Body with **bold**, *slant*, `code` and [a link](https://x.y).

        - item
        > quoted

        ```
        plain code
        ```

        ---
        """

    /// The contract that lets a style state only what it changes.
    @Test func anEmptyStyleChangesNothing() {
        let plain = render(MarkdownView(document), height: 14)
        let styled = render(MarkdownView(document).markdownStyle(MarkdownStyle()), height: 14)
        for y in 0..<plain.height {
            for x in 0..<plain.width {
                #expect(plain[x, y] == styled[x, y], "cell \(x),\(y)")
            }
        }
    }

    // MARK: - Headings

    @Test func aHeadingCanKeepItsMarker() {
        var style = MarkdownStyle()
        style.h2.prefix = "## "
        let buffer = render(MarkdownView("## Two").markdownStyle(style), height: 1)
        #expect(buffer.text(row: 0) == "## Two")
        // The marker is drawn in the heading's own style.
        #expect(cell("#", onRow: 0, in: buffer)?.style.foreground == LoudTheme().accent)
        #expect(cell("#", onRow: 0, in: buffer)?.style.bold == true)
    }

    @Test func aLevelBeatsAllHeadingsWhichBeatTheDefault() {
        var style = MarkdownStyle()
        style.heading.foreground = red
        style.h2.foreground = green
        // Blocks are separated by a blank row, so block n lands on row 2n.
        let buffer = render(MarkdownView("# One\n## Two\n### Six").markdownStyle(style), height: 5)
        #expect(cell("O", onRow: 0, in: buffer)?.style.foreground == red)
        #expect(cell("T", onRow: 2, in: buffer)?.style.foreground == green)
        #expect(cell("S", onRow: 4, in: buffer)?.style.foreground == red)
    }

    /// A bold word inside a heading keeps the heading's colour unless the
    /// strong style says otherwise.
    @Test func inlineStylesLayerOverTheirBlock() {
        var style = MarkdownStyle()
        style.heading.foreground = red
        let kept = render(MarkdownView("# A **B**").markdownStyle(style), height: 1)
        #expect(cell("B", onRow: 0, in: kept)?.style.foreground == red)

        style.strong.foreground = green
        let overridden = render(MarkdownView("# A **B**").markdownStyle(style), height: 1)
        #expect(cell("B", onRow: 0, in: overridden)?.style.foreground == green)
        #expect(cell("A", onRow: 0, in: overridden)?.style.foreground == red)
    }

    // MARK: - The document layer

    @Test func theDocumentColourReachesEveryTextElementButInlineCode() {
        var style = MarkdownStyle()
        style.text.foreground = red
        let buffer = render(MarkdownView("# Head\nBody `code`").markdownStyle(style), height: 3)
        #expect(cell("H", onRow: 0, in: buffer)?.style.foreground == red)
        #expect(cell("B", onRow: 2, in: buffer)?.style.foreground == red)
        #expect(cell("c", onRow: 2, in: buffer)?.style.foreground == LoudTheme().secondary)
    }

    /// The quiet block: a fill that runs under every row, the blank one
    /// between paragraphs included, across the full width.
    @Test func theDocumentBackgroundFillsEveryRow() {
        var style = MarkdownStyle()
        style.text.background = blue
        let buffer = render(MarkdownView("one\n\ntwo").markdownStyle(style), width: 10, height: 3)
        for y in 0..<3 {
            #expect(buffer[9, y].style.background == blue, "row \(y) is filled to the edge")
        }
    }

    @Test func aMoreSpecificElementBeatsTheDocument() {
        var style = MarkdownStyle()
        style.text.foreground = red
        style.heading.foreground = green
        let buffer = render(MarkdownView("# Head\nBody").markdownStyle(style), height: 3)
        #expect(cell("H", onRow: 0, in: buffer)?.style.foreground == green)
        #expect(cell("B", onRow: 2, in: buffer)?.style.foreground == red)
    }

    // MARK: - Inline code, links

    /// Padding and colour in one run: the chip's background runs under its
    /// padding as well as its text.
    @Test func inlineCodeCanBeAPaddedChip() {
        var style = MarkdownStyle()
        style.inlineCode = .init(foreground: red, background: blue, prefix: " ", suffix: " ")
        let buffer = render(MarkdownView("a `x` b").markdownStyle(style), height: 1)
        #expect(buffer.text(row: 0) == "a  x  b")
        let chip = (2...4).map { buffer[$0, 0] }
        #expect(chip.allSatisfy { $0.style.background == blue })
        #expect(chip[1].style.foreground == red)
    }

    @Test func aLinkCanDropItsUnderline() {
        var style = MarkdownStyle()
        style.link = .init(foreground: green, underline: false)
        let buffer = render(MarkdownView("[go](https://x.y)").markdownStyle(style), height: 1)
        #expect(cell("g", onRow: 0, in: buffer)?.style.foreground == green)
        #expect(cell("g", onRow: 0, in: buffer)?.style.underline == false)
    }

    // MARK: - Blocks

    @Test func aCodeBlockTakesItsColourAndFill() {
        var style = MarkdownStyle()
        style.codeBlock = .init(foreground: red, background: blue)
        let buffer = render(MarkdownView("```\nplain\n```").markdownStyle(style), width: 12, height: 1)
        #expect(cell("p", onRow: 0, in: buffer)?.style.foreground == red)
        #expect(buffer[11, 0].style.background == blue)
    }

    @Test func markersRailsAndRulesTakeTheirStyles() {
        var style = MarkdownStyle()
        style.listMarker.foreground = red
        style.blockQuote.foreground = green
        style.rule.foreground = blue
        let buffer = render(MarkdownView("- item\n\n> said\n\n---").markdownStyle(style), height: 5)
        #expect(cell("•", onRow: 0, in: buffer)?.style.foreground == red)
        #expect(buffer[0, 2].style.foreground == green, "the quote's rail")
        #expect(cell("─", onRow: 4, in: buffer)?.style.foreground == blue)
    }

    // MARK: - Scope

    @Test func aStyleReachesOnlyItsSubtree() {
        var style = MarkdownStyle()
        style.paragraph.foreground = red
        let buffer = render(VStack {
            MarkdownView("styled").markdownStyle(style)
            MarkdownView("stock")
        }, height: 2)
        #expect(cell("s", onRow: 0, in: buffer)?.style.foreground == red)
        #expect(cell("s", onRow: 1, in: buffer)?.style.foreground == LoudTheme().foreground)
    }
}
