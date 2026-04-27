import Testing
@testable import TerminalUI

// HYP-213 regression: a vertical thumb-track scrollbar appeared on
// content that doesn't actually overflow. The pure helper
// `scrollbarThumb(viewport:content:offset:)` returns nil when
// `content <= viewport` — verified by `ScrollbarGeometryTests`.
// What this suite pins is the integration: GraphRenderer must NOT
// paint either the `│` track glyph or the `█` thumb glyph when the
// rendered content fits inside the viewport.
//
// The scenario that surfaced the bug: a ScrollView whose content
// genuinely fits, but somewhere upstream the measurement reports an
// overflowing height. The track + thumb paint as if there's overflow.

@Suite("HYP-213 — scrollbar must not paint when content fits")
@MainActor
struct ScrollbarNoOverflowTests {

    /// Render a vertical ScrollView whose 3-row content fits inside a
    /// 10-row viewport. Inspect the rightmost column for `│` track
    /// glyphs and `█` thumb glyphs — both must be absent.
    @Test("vertical ScrollView with content shorter than viewport has no scrollbar glyphs")
    func verticalNoOverflowNoBar() {
        let view = ScrollView(.vertical) {
            VStack {
                Text("a")
                Text("b")
                Text("c")
            }
        }
        let graph = AttributeGraph()
        graph.update(from: view)

        var buffer = CellBuffer(width: 10, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Walk the rightmost column. Neither track nor thumb glyph
        // should appear because content (3 rows) fits in viewport (10).
        var trackHits: [Int] = []
        var thumbHits: [Int] = []
        let rightCol = buffer.width - 1
        for y in 0..<buffer.height {
            let ch = buffer[rightCol, y].character
            if ch == "│" { trackHits.append(y) }
            if ch == "█" { thumbHits.append(y) }
        }
        #expect(trackHits.isEmpty,
                "track glyph │ painted at rows \(trackHits) when content fits viewport")
        #expect(thumbHits.isEmpty,
                "thumb glyph █ painted at rows \(thumbHits) when content fits viewport")
    }

    @Test("horizontal ScrollView with content shorter than viewport has no scrollbar glyphs")
    func horizontalNoOverflowNoBar() {
        let view = ScrollView(.horizontal) {
            Text("hi")  // 2 cells of content
        }
        let graph = AttributeGraph()
        graph.update(from: view)

        var buffer = CellBuffer(width: 20, height: 4)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 4))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Walk the bottom row. Neither `─` track nor `█` thumb should
        // paint because content (2 cells) fits in viewport (20).
        let bottomRow = buffer.height - 1
        var trackHits: [Int] = []
        var thumbHits: [Int] = []
        for x in 0..<buffer.width {
            let ch = buffer[x, bottomRow].character
            if ch == "─" { trackHits.append(x) }
            if ch == "█" { thumbHits.append(x) }
        }
        #expect(trackHits.isEmpty,
                "horizontal track ─ painted at cols \(trackHits) when content fits viewport")
        #expect(thumbHits.isEmpty,
                "horizontal thumb █ painted at cols \(thumbHits) when content fits viewport")
    }

    /// Sanity control: when content DOES overflow, the bar paints.
    /// Catches a future regression where someone "fixes" the no-overflow
    /// case by killing the scrollbar entirely.
    @Test("vertical ScrollView with content TALLER than viewport DOES paint scrollbar")
    func verticalOverflowPaintsBar() {
        let view = ScrollView(.vertical) {
            VStack {
                ForEachWithID(0..<20, id: \.self) { i in Text("row \(i)") }
            }
        }
        let graph = AttributeGraph()
        graph.update(from: view)

        var buffer = CellBuffer(width: 10, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        let rightCol = buffer.width - 1
        var hasBar = false
        for y in 0..<buffer.height {
            let ch = buffer[rightCol, y].character
            if ch == "│" || ch == "█" { hasBar = true; break }
        }
        #expect(hasBar,
                "vertical ScrollView with 20 content rows in a 5-row viewport must paint the scrollbar")
    }
}
