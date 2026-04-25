import Testing
@testable import TerminalUI

// HYP-123 — TextInput axis: .vertical
//
// Mirrors SwiftUI's `TextField(_:axis:.vertical)` shape introduced in
// iOS 16. WWDC22 verbatim:
//
//   "Text fields can be configured to expand vertically using the
//    new axis parameter, growing their height to fit the text and,
//    if specified, capping their height to the line limit."
//
// Default axis stays `.horizontal` (current single-line behaviour
// byte-for-byte). When `axis: .vertical` is set, the field grows
// vertically based on the env-driven `LineBreakMode`:
//   .byClipping       → still single-row, clip horizontally
//   .byCharWrapping   → multi-row via TextLayout.charStrideChunks
//   .byWordWrapping   → multi-row via TextLayout.wrapWords
//   .byTruncating*    → still single-row with ellipsis
//
// Cursor stays pinned at the right edge of the LAST visible chunk.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite("HYP-123 — TextInput axis:.vertical")
@MainActor
struct TextInputAxisTests {

    @Test("default horizontal axis byte-for-byte preserves single-line behaviour")
    func defaultHorizontalUnchanged() {
        // Long value, narrow rect — without axis param, the legacy
        // tail-clip behaviour must fire (cursor pinned right). This
        // is the no-regression contract for every existing call site.
        resetGraphContext()
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row0 = ""
        for c in 0..<12 { row0.append(buffer[c, 0].character) }
        var row1 = ""
        for c in 0..<12 { row1.append(buffer[c, 1].character) }
        #expect(row0.contains("value"),
                "horizontal axis must show tail of value on row 0; got '\(row0)'")
        #expect(row1.trimmingCharacters(in: .whitespaces).isEmpty,
                "horizontal axis must NOT use row 1 (single-line); row 1='\(row1)'")
    }

    @Test("vertical axis + byCharWrapping grows to multiple rows with hard breaks")
    func verticalCharWrapMultiRow() {
        resetGraphContext()
        var value = "abcdefghijklmnopqrstuvwxyz"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding, axis: .vertical)
            .lineBreakMode(.byCharWrapping)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 10, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var rowsWithLetters = 0
        for r in 0..<5 {
            var line = ""
            for c in 0..<10 { line.append(buffer[c, r].character) }
            if line.contains(where: { $0.isLetter }) { rowsWithLetters += 1 }
        }
        #expect(rowsWithLetters >= 2,
                "vertical+byCharWrapping must use ≥2 rows for 26 chars at width 10; got \(rowsWithLetters)")
    }

    @Test("vertical axis + byWordWrapping breaks on spaces, not mid-word")
    func verticalWordWrapNoMidWordBreaks() {
        resetGraphContext()
        let sentence = "type a very long line and see if it will properly wrap"
        var value = sentence
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding, axis: .vertical)
            .lineBreakMode(.byWordWrapping)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 6)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 6))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        var rows: [String] = []
        for r in 0..<6 {
            var line = ""
            for c in 0..<20 { line.append(buffer[c, r].character) }
            rows.append(line.trimmingCharacters(in: .whitespaces))
        }
        let contentRows = rows.filter { !$0.isEmpty }
        #expect(contentRows.count >= 2,
                "vertical+byWordWrapping must wrap to ≥2 rows; got \(contentRows.count): \(rows)")
        for i in 0..<contentRows.count - 1 {
            let a = contentRows[i]
            let b = contentRows[i + 1]
            if let last = a.last, let first = b.first,
               last.isLetter, first.isLetter
            {
                let pair = "\(last)\(first)"
                #expect(!sentence.contains(pair),
                        "split word at row \(i)='\(a)' / row \(i+1)='\(b)' (pair '\(pair)' contiguous in source)")
            }
        }
    }

    @Test("vertical axis + byClipping stays single row (clipping wins regardless of axis)")
    func verticalClippingStillSingleRow() {
        resetGraphContext()
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding, axis: .vertical)
            // env defaults to .byClipping, but spell it out for the test
            .lineBreakMode(.byClipping)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 4)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 4))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row1 = ""
        for c in 0..<12 { row1.append(buffer[c, 1].character) }
        #expect(row1.trimmingCharacters(in: .whitespaces).isEmpty,
                "vertical+byClipping must not use row 1 (clipping is single-line); row 1='\(row1)'")
    }

    @Test("vertical axis + byTruncatingTail stays single row with ellipsis")
    func verticalTruncatingTailSingleRow() {
        resetGraphContext()
        var value = "this is a very long input value"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding, axis: .vertical)
            .lineBreakMode(.byTruncatingTail)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 12, height: 4)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 12, height: 4))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row0 = ""
        for c in 0..<12 { row0.append(buffer[c, 0].character) }
        var row1 = ""
        for c in 0..<12 { row1.append(buffer[c, 1].character) }
        #expect(row0.contains("…"),
                "byTruncatingTail must show ellipsis on row 0; got '\(row0)'")
        #expect(row1.trimmingCharacters(in: .whitespaces).isEmpty,
                "truncation modes must not use row 1; got '\(row1)'")
    }

    @Test("short value fits on one row in either axis")
    func shortValueFitsOneRow() {
        resetGraphContext()
        var value = "hello"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let view = TextInput(text: textBinding, axis: .vertical)
            .lineBreakMode(.byWordWrapping)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 4)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 4))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        var row0 = ""
        for c in 0..<20 { row0.append(buffer[c, 0].character) }
        var row1 = ""
        for c in 0..<20 { row1.append(buffer[c, 1].character) }
        #expect(row0.contains("hello"),
                "short value must render on row 0; got '\(row0)'")
        #expect(row1.trimmingCharacters(in: .whitespaces).isEmpty,
                "short value must not use row 1; got '\(row1)'")
    }
}
