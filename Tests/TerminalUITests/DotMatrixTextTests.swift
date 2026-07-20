import Testing
@testable import TerminalUI

@Suite("DotMatrixText — dot-matrix glyphs render across 7 rows")
@MainActor
struct DotMatrixTextTests {

    @Test("DotMatrixText(\"H\") renders ● shapes across rows 0..6")
    func dotMatrixHeight() {
        let graph = AttributeGraph()
        graph.update(from: DotMatrixText("H"))
        // Render into a buffer tall enough for all 7 dot rows.
        var buffer = CellBuffer(width: 10, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
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
        let graph = AttributeGraph()
        graph.update(from: VStack {
            DotMatrixText("H")
            Text("below")
        })
        var buffer = CellBuffer(width: 10, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // DotMatrix H's row 3 is all ●s, should still be at y=3
        for col in 0..<5 {
            #expect(buffer[col, 3].character == "\u{25CF}",
                    "VStack-child H row 3 col \(col) should be ● — got '\(buffer[col, 3].character)'")
        }
        // "below" should be at y=7
        #expect(buffer[0, 7].character == "b",
                "\"below\" should start at y=7 — got '\(buffer[0, 7].character)'")
    }
}
