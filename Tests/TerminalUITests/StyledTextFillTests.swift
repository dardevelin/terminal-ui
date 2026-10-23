import Testing
@testable import TerminalUI

// `Text` renders on two paths: one for a single unstyled run, one for styled
// runs. The unstyled path pads every line it writes to the width of its frame
// in the inherited style; the styled path wrote only its glyphs. So
// `.background(c)` behind `Text("a")` filled the frame, and behind the same
// word in a colour it stopped at the word — a code block in markdown, where
// every run is coloured, could never fill its column. Both paths now own the
// rows they write, edge to edge.

private let fill = Color.rgb(0, 0, 200)

@MainActor
private func filledColumns(_ text: Text, mode: TextWrapMode, width: Int = 10) -> [[Bool]] {
    let view = text.wrap(mode).frame(maxWidth: .infinity).background(fill)
    let buffer = renderedBuffer(view, width: width, height: 2)
    return (0..<2).map { y in (0..<width).map { buffer[$0, y].style.background == fill } }
}

@Suite("Styled text fills its frame the way plain text does")
@MainActor
struct StyledTextFillTests {

    private let plain = Text("ab")
    private let styled = Text(spans: [TextSpan("ab", foreground: .red)])

    @Test(arguments: [TextWrapMode.wrap, .none, .truncate(.tail)])
    func aBackgroundBehindStyledTextFillsTheRow(mode: TextWrapMode) {
        let rows = filledColumns(styled, mode: mode)
        #expect(rows[0].allSatisfy { $0 }, "row 0 filled edge to edge in \(mode)")
    }

    @Test(arguments: [TextWrapMode.wrap, .none, .truncate(.tail)])
    func styledAndPlainTextFillAlike(mode: TextWrapMode) {
        #expect(filledColumns(styled, mode: mode) == filledColumns(plain, mode: mode))
    }

    /// Each row a wrapped or multi-line styled text writes is owned to the
    /// edge, not only the first.
    @Test func everyRowTheTextWritesIsFilled() {
        let twoLines = Text(spans: [TextSpan("ab\ncd", foreground: .red)])
        let rows = filledColumns(twoLines, mode: .none)
        #expect(rows.allSatisfy { $0.allSatisfy { $0 } })
    }
}
