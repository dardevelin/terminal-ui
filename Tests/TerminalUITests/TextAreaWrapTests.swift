import Testing
@testable import TerminalUI

// TextArea soft-wrap rendering.
//
// Per HIG `apple-hig/components/text-fields.md`: TextArea is the
// "text view" for "larger amounts of text", and wrap-at-word is the
// readable default.
//
// Logical lines soft-wrap into ≤width chunks at render time via
// `TextLayout.wrapWords`. Cursor stays logical-row-indexed; the
// `.logical` arrow mode keeps Down on the next logical line (even
// when the current line wraps to multiple display rows). The
// `.display` arrow-mode that walks wrapped chunks lives in
// `TextAreaDisplayRowNavigationTests`.

@Suite("TextArea — soft-wrap")
@MainActor
struct TextAreaWrapTests {

    @Test("a long single logical line renders to multiple display rows")
    func longLineWrapsToMultipleRows() {
        let long = "type a very long line and see if it will properly wrap and do the right thing"
        var content = long
        var state = TextAreaState()
        let textBinding = Binding(get: { content }, set: { content = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = TextArea(text: textBinding, state: stateBinding, visibleHeight: 8)

        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Read rendered rows; trim trailing whitespace + tilde-fillers
        // from empty rows.
        var rows: [String] = []
        for r in 0..<8 {
            var line = ""
            for c in 0..<20 { line.append(buffer[c, r].character) }
            rows.append(line.trimmingCharacters(in: .whitespaces))
        }
        let contentRows = rows.filter { !$0.isEmpty && $0 != "~" }

        #expect(contentRows.count >= 2,
                "long logical line must wrap to multiple display rows; got \(contentRows.count): \(rows)")
    }

    @Test("wrapped TextArea breaks at word boundaries, not mid-word")
    func wrappedRowsRespectWordBoundaries() {
        let sentence = "type a very long line and see if it will properly wrap and do the right thing"
        var content = sentence
        var state = TextAreaState()
        let textBinding = Binding(get: { content }, set: { content = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = TextArea(text: textBinding, state: stateBinding, visibleHeight: 8)

        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        var rows: [String] = []
        for r in 0..<8 {
            var line = ""
            for c in 0..<20 { line.append(buffer[c, r].character) }
            rows.append(line.trimmingCharacters(in: .whitespaces))
        }
        let contentRows = rows.filter { !$0.isEmpty && $0 != "~" }

        for i in 0..<contentRows.count - 1 {
            let a = contentRows[i]
            let b = contentRows[i + 1]
            if let last = a.last, let first = b.first,
               last.isLetter, first.isLetter
            {
                let pair = "\(last)\(first)"
                #expect(!sentence.contains(pair),
                        "TextArea split a word: row \(i)='\(a)' + row \(i+1)='\(b)' contiguous in source")
            }
        }
    }

    @Test("multi-line content with one long line preserves line count")
    func multiLineWithLongLine() {
        // Two logical lines: one short, one that needs to wrap.
        let content = "short\nthis is a fairly long second line that should wrap to two rows"
        var contentVar = content
        var state = TextAreaState()
        let textBinding = Binding(get: { contentVar }, set: { contentVar = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = TextArea(text: textBinding, state: stateBinding, visibleHeight: 10)

        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Row 0 = "short". Rows 1..N = wrapped second line. Row N+1
        // onwards = empty/tilde.
        var firstRow = ""
        for c in 0..<20 { firstRow.append(buffer[c, 0].character) }
        #expect(firstRow.trimmingCharacters(in: .whitespaces) == "short",
                "first logical line must render unchanged on row 0; got '\(firstRow)'")

        // At least one row beyond row 0 contains content from the
        // second line — confirms it wrapped.
        var secondLineRowCount = 0
        for r in 1..<10 {
            var line = ""
            for c in 0..<20 { line.append(buffer[c, r].character) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed != "~" {
                secondLineRowCount += 1
            }
        }
        #expect(secondLineRowCount >= 2,
                "second long logical line must wrap to ≥2 display rows; got \(secondLineRowCount)")
    }

    @Test("short content fits on one row unchanged")
    func shortContentFitsOnOneRow() {
        let short = "hello world"
        var content = short
        var state = TextAreaState()
        let textBinding = Binding(get: { content }, set: { content = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = TextArea(text: textBinding, state: stateBinding, visibleHeight: 5)

        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        var firstRow = ""
        for c in 0..<20 { firstRow.append(buffer[c, 0].character) }
        #expect(firstRow.contains("hello world"),
                "short content must render on row 0; got '\(firstRow)'")
    }

    @Test("buildDisplaySpans wraps each visible logical line via TextLayout")
    func buildDisplaySpansUsesTextLayout() {
        // Direct unit test on the static helper. The output spans
        // should produce the same row count as TextLayout.wrapWords
        // when given a single long logical line.
        let long = "type a very long line and see if it will properly wrap"
        let lines = TextLines.split(long)
        let cursor = TextAreaCursor(row: 0, col: 0)
        let spans = TextArea.buildDisplaySpans(
            lines: lines,
            cursor: cursor,
            selection: nil,
            scrollOffset: 0,
            visibleHeight: 10,
            lineNumbers: false,
            wrapWidth: 20
        )
        // Count newlines in joined span text — newlines == row breaks.
        let joined: String = spans.map { $0.text }.joined()
        let newlineCount = joined.filter { $0 == "\n" }.count
        let expectedRows = TextLayout.wrapWords(long, width: 20).count
        // Visible rows = expectedRows; newlines between rows =
        // expectedRows - 1 (no trailing newline) PLUS empty-row
        // tildes appended below content. Just check the visible
        // content rows is right.
        #expect(newlineCount + 1 >= expectedRows,
                "expected at least \(expectedRows) display rows; spans had \(newlineCount + 1)")
    }
}
