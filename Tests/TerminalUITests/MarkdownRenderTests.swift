import Testing
@testable import TerminalUI

// Rendering turns the tree into rows on a grid. The properties worth pinning
// are the ones a reader notices: a wrapped bullet lands under its own text
// rather than under the bullet, a quote's rail runs the whole quote, and every
// colour came from a theme role rather than a literal.

@MainActor
@Suite struct MarkdownRenderTests {

    /// Roles set to values no literal in the codebase would produce, so a cell
    /// wearing one can only have come from the theme.
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

    private func render(_ source: String, width: Int, height: Int) -> CellBuffer {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        var env = EnvironmentValues()
        env.theme = LoudTheme()
        env.terminalSize = TerminalSize(cols: width, rows: height)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
                graph.update(from: MarkdownView(source))
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        return buffer
    }

    private func rows(_ buffer: CellBuffer) -> [String] {
        (0..<buffer.height).map { y in
            var line = ""
            for x in 0..<buffer.width { line.append(buffer[x, y].character) }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    private func colors(_ buffer: CellBuffer) -> [Color] {
        var found: [Color] = []
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                if let fg = buffer[x, y].style.foreground, !found.contains(fg) { found.append(fg) }
            }
        }
        return found
    }

    // MARK: - Layout

    @Test func paragraphsRenderTheirText() {
        #expect(rows(render("hello there", width: 20, height: 1))[0] == "hello there")
    }

    /// The property the whole flatten-to-rows design exists for: a bullet's
    /// continuation lands under its text, not under the bullet.
    @Test func aWrappedBulletHangsUnderItsOwnText() {
        let out = rows(render("- alpha beta gamma delta", width: 14, height: 3))
        #expect(out[0] == "• alpha beta")
        #expect(out[1] == "  gamma delta")
    }

    @Test func orderedMarkersAlignWhenTheOrdinalsWiden() {
        let source = (9...11).map { "\($0). item" }.joined(separator: "\n")
        let out = rows(render(source, width: 20, height: 3))
        // The single-digit marker is padded so every "item" starts in the
        // same column.
        #expect(out[0] == " 9. item")
        #expect(out[1] == "10. item")
        #expect(out[2] == "11. item")
    }

    @Test func nestedListsStepInUnderTheirParent() {
        let out = rows(render("- outer\n  - inner", width: 20, height: 2))
        #expect(out[0] == "• outer")
        #expect(out[1] == "  • inner")
    }

    /// A rail that only marked the first line would read as a bullet, not a
    /// quote — it has to run the height of the quoted content, which is why
    /// it is a border edge rather than a gutter glyph.
    @Test func aQuotesRailRunsEveryRow() {
        let out = rows(render("> alpha beta gamma", width: 12, height: 3))
        #expect(out[0] == "┃alpha beta")
        #expect(out[1] == "┃gamma")
    }

    @Test func codeBlocksKeepTheirOwnLineBreaks() {
        let out = rows(render("```\nlet a = 1\nlet b = 2\n```", width: 20, height: 2))
        #expect(out[0] == "  let a = 1")
        #expect(out[1] == "  let b = 2")
    }

    /// Code must not reflow — a wrapped source line is unreadable, so it
    /// truncates and says so.
    @Test func longCodeLinesTruncateRatherThanWrap() {
        let out = rows(render("```\nlet somethingVeryLongIndeed = 1\n```", width: 14, height: 2))
        #expect(out[0].hasSuffix("…"))
        #expect(out[1] == "")
    }

    @Test func blocksAreSeparatedByABlankRow() {
        let out = rows(render("one\n\ntwo", width: 20, height: 3))
        #expect(out[0] == "one")
        #expect(out[1] == "")
        #expect(out[2] == "two")
    }

    // MARK: - Styling comes from the theme

    @Test func headingsTakeTheAccent() {
        #expect(colors(render("# Title", width: 20, height: 1)).contains(LoudTheme().accent))
    }

    @Test func deeperHeadingsStepDownToEmphasis() {
        let used = colors(render("### Title", width: 20, height: 1))
        #expect(used.contains(LoudTheme().foregroundEmphasis))
        #expect(!used.contains(LoudTheme().accent))
    }

    @Test func inlineCodeTakesItsOwnRoleAndSurface() {
        let buffer = render("use `code` here", width: 20, height: 1)
        #expect(colors(buffer).contains(LoudTheme().secondary))
        // And sits on the raised surface rather than the page ground.
        var sawRaised = false
        for x in 0..<20 where buffer[x, 0].style.background == LoudTheme().backgroundRaised {
            sawRaised = true
        }
        #expect(sawRaised)
    }

    @Test func linksTakeTheAccentUnderlined() {
        let buffer = render("[docs](https://example.com)", width: 20, height: 1)
        #expect(colors(buffer).contains(LoudTheme().accent))
        #expect(buffer[0, 0].style.underline)
        // The destination is not printed — it would drown a narrow column.
        #expect(!rows(buffer)[0].contains("example.com"))
    }

    @Test func emphasisBecomesBoldAndItalicCells() {
        let bold = render("**b**", width: 8, height: 1)
        #expect(bold[0, 0].style.bold)
        let italic = render("*i*", width: 8, height: 1)
        #expect(italic[0, 0].style.italic)
    }

    @Test func markerGlyphsUseTheMutedRole() {
        #expect(colors(render("- item", width: 20, height: 1)).contains(LoudTheme().foregroundMuted))
    }

    @Test func quoteRailsUseTheSeparatorRole() {
        #expect(colors(render("> quoted", width: 20, height: 1)).contains(LoudTheme().separator))
    }

    /// Swift fences are highlighted; an unknown language stays plain rather
    /// than guessing a lexer.
    @Test func swiftFencesAreHighlightedAndUnknownOnesAreNot() {
        let swift = colors(render("```swift\nlet x = 1\n```", width: 20, height: 1))
        let plain = colors(render("```nosuchlang\nlet x = 1\n```", width: 20, height: 1))
        #expect(swift != plain, "a swift fence should not render identically to an unknown one")
        #expect(plain.contains(LoudTheme().foregroundSubtle))
    }
}
