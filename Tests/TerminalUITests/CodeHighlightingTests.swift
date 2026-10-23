import Testing
@testable import TerminalUI

// Code colours were fixed in place: markdown fences used one hard-wired
// palette whatever the app's theme, only Swift could ever be highlighted
// because the language lookup was internal, and there was no view for a
// read-only excerpt at all. The colours are a theme role now, lexers register
// through the environment, and CodeView draws code the way the rest of the
// framework draws everything else.

/// Classifies the word `toy` and nothing else, so every other character is a
/// stretch no span covers.
private struct ToyHighlighter: SyntaxHighlighter {
    func tokenize(line: String) -> [SyntaxSpan] {
        guard let range = line.range(of: "toy") else { return [] }
        return [SyntaxSpan(range: range, token: .keyword)]
    }
}

/// Token colours no literal in the codebase would produce.
private let loudSyntax = SyntaxTheme(
    keyword: .rgb(1, 1, 1), string: .rgb(2, 2, 2), comment: .rgb(3, 3, 3),
    number: .rgb(4, 4, 4), type: .rgb(5, 5, 5), function: .rgb(6, 6, 6),
    operatorColor: .rgb(7, 7, 7), plain: .rgb(8, 8, 8)
)

private struct LoudTheme: Theme {
    var syntax: SyntaxTheme = loudSyntax
    var foregroundMuted: Color = .rgb(20, 20, 20)
}

@MainActor
private func render(_ view: some TerminalView, width: Int, height: Int,
                    theme: any Theme = LoudTheme()) -> CellBuffer {
    renderedBuffer(view, width: width, height: height, theme: theme)
}

/// Foreground of the first cell on row `y` showing `character`.
private func foreground(of character: Character, onRow y: Int, in buffer: CellBuffer) -> Color? {
    for x in 0..<buffer.width where buffer[x, y].character == character {
        return buffer[x, y].style.foreground
    }
    return nil
}

@Suite("Code highlighting a developer controls")
@MainActor
struct CodeHighlightingTests {

    // MARK: - The highlight primitive

    @Test func uncoveredStretchesAreDrawnPlainNotDropped() {
        let runs = ToyHighlighter().highlight(lines: ["a toy b"], theme: loudSyntax)[0]
        #expect(runs.map(\.text).joined() == "a toy b")
        #expect(runs.map(\.foreground) == [loudSyntax.plain, loudSyntax.keyword, loudSyntax.plain])
    }

    /// A block comment opened on one line colours the next, which has no
    /// opening marker of its own.
    @Test func stateCarriesFromLineToLine() {
        let runs = SwiftSyntaxHighlighter().highlight(lines: ["/* open", "still inside */"],
                                                      theme: loudSyntax)
        #expect(runs[1].allSatisfy { $0.foreground == loudSyntax.comment })
    }

    @Test func anEmptyLineIsAnEmptyRun() {
        #expect(ToyHighlighter().highlight(lines: [""], theme: loudSyntax) == [[]])
    }

    // MARK: - The registry

    @Test func swiftIsStandardAndNamesMatchAnyCase() {
        #expect(SyntaxHighlighters.standard["swift"] != nil)
        #expect(SyntaxHighlighters.standard["Swift"] != nil)
        #expect(SyntaxHighlighters.standard["json"] == nil)
        #expect(SyntaxHighlighters.standard[nil] == nil)
    }

    @Test func registeringAddsUnderEveryName() {
        var registry = SyntaxHighlighters.standard
        registry.register(ToyHighlighter(), for: "toy", "TOYLANG")
        #expect(registry["toylang"] != nil)
        #expect(registry["toy"] != nil)
        #expect(registry["swift"] != nil)
    }

    /// The modifier adds to what the subtree inherits: a fence in the new
    /// language and a Swift fence beside it both highlight.
    @Test func theModifierAddsWithoutDiscardingWhatWasInherited() {
        let source = "```toy\ntoy\n```\n\n```swift\nlet\n```"
        let buffer = render(MarkdownView(source).syntaxHighlighter(ToyHighlighter(), for: "toy"),
                            width: 20, height: 3)
        #expect(foreground(of: "t", onRow: 0, in: buffer) == loudSyntax.keyword)
        #expect(foreground(of: "l", onRow: 2, in: buffer) == loudSyntax.keyword)
    }

    @Test func nestedTransformsAccumulate() {
        let inner = CodeView("toy", language: "toy")
            .syntaxHighlighter(ToyHighlighter(), for: "toy")
        let buffer = render(VStack { inner; CodeView("let", language: "swift") }
            .syntaxHighlighter(ToyHighlighter(), for: "other"),
                            width: 10, height: 2)
        #expect(foreground(of: "t", onRow: 0, in: buffer) == loudSyntax.keyword)
        #expect(foreground(of: "l", onRow: 1, in: buffer) == loudSyntax.keyword)
    }

    // MARK: - Theme.syntax

    @Test func markdownFencesFollowTheThemesCodeColours() {
        let buffer = render(MarkdownView("```swift\nlet\n```"), width: 10, height: 1)
        #expect(foreground(of: "l", onRow: 0, in: buffer) == loudSyntax.keyword)
    }

    /// The role is a declared requirement, so a theme's own palette survives
    /// being held as `any Theme` — which is how the environment holds it.
    @Test func aStatedPaletteSurvivesTheExistential() {
        let erased: any Theme = LoudTheme()
        #expect(erased.syntax == loudSyntax)
        #expect(DefaultTheme().syntax == .defaultDark)
    }

    @Test func textAreaFollowsTheThemeUnlessToldOtherwise() {
        let source = Binding.constant("let")
        var themed = TextAreaState()
        let followed = TextArea(text: source, state: Binding(get: { themed }, set: { themed = $0 }),
                                highlighter: SwiftSyntaxHighlighter())
        // Column 0 holds the editor's cursor, drawn in its own colours.
        #expect(foreground(of: "t", onRow: 0, in: render(followed, width: 10, height: 1))
                == loudSyntax.keyword)

        var pinned = TextAreaState()
        let overridden = TextArea(text: source, state: Binding(get: { pinned }, set: { pinned = $0 }),
                                  highlighter: SwiftSyntaxHighlighter(), theme: .defaultDark)
        #expect(foreground(of: "t", onRow: 0, in: render(overridden, width: 10, height: 1))
                == SyntaxTheme.defaultDark.keyword)
    }

    // MARK: - CodeView

    @Test func numbersCountFromTheFirstLineAndAlign() {
        let buffer = render(CodeView("a\nb", lineNumbers: true, firstLineNumber: 9), width: 10, height: 2)
        #expect(buffer.text(row: 0) == " 9  a")
        #expect(buffer.text(row: 1) == "10  b")
        #expect(foreground(of: "9", onRow: 0, in: buffer) == LoudTheme().foregroundMuted)
    }

    @Test func aWrappedLineContinuesUnderItsCodeNotTheGutter() {
        let buffer = render(CodeView("aaaa bbbb", lineNumbers: true, firstLineNumber: 7), width: 8, height: 2)
        #expect(buffer.text(row: 0) == "7  aaaa")
        #expect(buffer.text(row: 1) == "   bbbb")
    }

    @Test func truncationCutsEachLineWithAnEllipsis() {
        let view = CodeView("aaaa bbbb", lineNumbers: true, firstLineNumber: 7).wrap(.truncate(.tail))
        #expect(render(view, width: 8, height: 1).text(row: 0) == "7  aaaa…")
    }

    @Test func aBlankLineKeepsItsRow() {
        let buffer = render(CodeView("a\n\nb"), width: 5, height: 3)
        #expect(buffer.text(row: 0) == "a")
        #expect(buffer.text(row: 1) == "")
        #expect(buffer.text(row: 2) == "b")
    }

    @Test func oneTrailingNewlineEndsTheLastLine() {
        let buffer = render(CodeView("a\nb\n", lineNumbers: true), width: 6, height: 3)
        #expect(buffer.text(row: 2) == "")
    }

    @Test func anUnregisteredLanguageIsDrawnPlain() {
        let buffer = render(CodeView("let", language: "nope"), width: 5, height: 1)
        #expect(foreground(of: "l", onRow: 0, in: buffer) == loudSyntax.plain)
    }

    @Test func aViewArgumentOverridesTheTheme() {
        let buffer = render(CodeView("let", language: "swift", theme: .defaultDark), width: 5, height: 1)
        #expect(foreground(of: "l", onRow: 0, in: buffer) == SyntaxTheme.defaultDark.keyword)
    }

    @Test func aCodeViewTakesNoFocus() {
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: CodeView("let x = 1", language: "swift", lineNumbers: true))
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        #expect(engine.keyboardFocusID == nil)
    }
}
