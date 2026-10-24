import Testing
@testable import TerminalUI

@Suite("DotMatrixText — dot-matrix glyphs render across 7 rows")
@MainActor
struct DotMatrixTextTests {

    @Test("DotMatrixText(\"H\") renders ● shapes across rows 0..6")
    func dotMatrixHeight() {
        let buffer = rendered(DotMatrixText("H"), width: 10, height: 10)
        // Row 0 of H: "#...#" → ● at col 0 and col 4
        #expect(buffer[0, 0].character == "\u{25CF}",
                "row 0 col 0 should be ● — got '\(buffer[0, 0].character)'")
        #expect(buffer[4, 0].character == "\u{25CF}",
                "row 0 col 4 should be ● — got '\(buffer[4, 0].character)'")
        // Row 3 of H: "#####" → all 5 cols should be ●
        for col in 0..<5 {
            #expect(buffer[col, 3].character == "\u{25CF}",
                    "row 3 col \(col) should be ● — got '\(buffer[col, 3].character)'")
        }
        // Row 6 of H: "#...#" — at least col 0 must be ●
        #expect(buffer[0, 6].character == "\u{25CF}",
                "row 6 col 0 should be ● — got '\(buffer[0, 6].character)'")
    }

    @Test("DotMatrixText measurement at narrow proposed width stays at 7 rows")
    func dotMatrixNarrowMeasure() {
        let graph = AttributeGraph()
        graph.update(from: DotMatrixText("HELLO"))
        // "HELLO" is 5 letters × 5 glyph cols + 4 letter-gaps = 29 chars wide.
        // At proposedWidth = 20, wrap-mode measurement would inflate height
        // to ~14 rows (each row wraps). Under `.wrap(.none)` the measurer
        // should report exactly `DotFont.glyphHeight` (7).
        let h = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 20)
        #expect(h == DotFont.glyphHeight,
                "expected 7 rows under .wrap(.none), got \(h)")
    }

    @Test("DotMatrixText inside a VStack preserves its 7-row height")
    func dotMatrixInVStack() {
        let buffer = rendered(VStack {
            DotMatrixText("H")
            Text("below")
        }, width: 10, height: 10)
        // DotMatrix H's row 3 is all ●s, should still be at y=3
        for col in 0..<5 {
            #expect(buffer[col, 3].character == "\u{25CF}",
                    "VStack-child H row 3 col \(col) should be ● — got '\(buffer[col, 3].character)'")
        }
        // "below" should be at y=7
        #expect(buffer[0, 7].character == "b",
                "\"below\" should start at y=7 — got '\(buffer[0, 7].character)'")
    }

    // MARK: - Half blocks

    @Test("Half blocks pack two dot rows into each cell")
    func halfBlockShapes() {
        let rows = rendered(DotMatrixText("H", mode: .halfBlock), width: 5, height: 5).rowTexts
        #expect(rows[0] == "█   █")
        #expect(rows[1] == "█▄▄▄█")
        #expect(rows[2] == "█   █")
        #expect(rows[3] == "▀   ▀")
        #expect(rows[4].isEmpty)
    }

    @Test("Half-block letters stand four rows tall, however narrow the offer")
    func halfBlockHeight() {
        let graph = AttributeGraph()
        graph.update(from: DotMatrixText("HELLO", mode: .halfBlock))
        #expect(GraphMeasurer.measureHeight(graph.root!, proposedWidth: 20) == 4)
    }

    /// Captions and rules sized by `columns` line up with the letters.
    @Test("Columns counts the cells the letters span", arguments: [
        (DotMatrixText.RenderMode.halfBlock, 11), (.default, 11), (.braille, 6),
    ])
    func columnsMatchTheDrawing(mode: DotMatrixText.RenderMode, expected: Int) {
        #expect(DotMatrixText("HI", mode: mode).columns == expected)
    }

    /// `(` is four dots wide, two braille cells exactly; the gap that once
    /// followed the last letter too spilled into a third, blank cell.
    @Test("Braille ends at the last letter's last dot")
    func brailleHasNoTrailingCell() {
        let buffer = rendered(DotMatrixText("(", mode: .braille), width: 5, height: 2)
        #expect(buffer[1, 0].character != " ")
        #expect(buffer[2, 0].character == " ")
    }

    // MARK: - Gradients

    /// A wordmark's ramp runs across the letters, so each column is one
    /// colour from top to bottom, the first column the start colour and the
    /// last the end.
    @Test("A gradient steps once per column, the same colour all the way down", arguments: [
        DotMatrixText.RenderMode.halfBlock, .default, .braille,
    ])
    func gradientRunsAcrossColumns(mode: DotMatrixText.RenderMode) {
        let start = Color.rgb(200, 40, 40)
        let end = Color.rgb(40, 40, 200)
        let buffer = rendered(DotMatrixText("HI", mode: mode).gradient(from: start, to: end),
                              width: 20, height: 8)
        let columns = (0..<20).filter { x in (0..<8).contains { buffer[x, $0].character != " " } }
        let first = columns.first!, last = columns.last!
        let ramp = Color.ramp(through: [start, end], count: last - first + 1)
        for x in columns {
            for y in 0..<8 where buffer[x, y].character != " " {
                #expect(buffer[x, y].style.foreground == ramp[x - first], "column \(x) row \(y)")
            }
        }
        #expect(buffer[first, 0].style.foreground == start)
    }

    @Test("A gradient leaves the letterforms as they were")
    func gradientKeepsTheShapes() {
        let plain = rendered(DotMatrixText("HI", mode: .halfBlock), width: 12, height: 4).rowTexts
        let swept = rendered(
            DotMatrixText("HI", mode: .halfBlock).gradient(through: [.red, .green, .blue]),
            width: 12, height: 4).rowTexts
        #expect(swept == plain)
    }

    @Test("One stop paints one colour; none leaves the text to its surroundings")
    func gradientWithFewStops() {
        let one = rendered(DotMatrixText("H", mode: .halfBlock).gradient(through: [.green]),
                           width: 5, height: 4)
        #expect(one[0, 0].style.foreground == .green && one[4, 3].style.foreground == .green)
        let none = rendered(DotMatrixText("H", mode: .halfBlock).gradient(through: []).foreground(.red),
                            width: 5, height: 4)
        #expect(none[0, 0].style.foreground == .red)
    }

    private func rendered(_ view: some TerminalView, width: Int, height: Int) -> CellBuffer {
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: width, height: height)
        GraphRenderer.render(graph.root!, into: &buffer,
                             context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height)))
        return buffer
    }
}
