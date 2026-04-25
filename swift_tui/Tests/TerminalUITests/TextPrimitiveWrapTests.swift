import Testing
@testable import TerminalUI

// Text-primitive word-wrap (HIG: "wrap at character or word level"
// — word level is the readable default for long content).
//
// Today the framework's Text rendering breaks mid-word — the fast
// path (single unstyled span) clips with `prefix(maxWidth)` and the
// styled path soft-wraps char-by-char. The measurer
// (`GraphMeasurer.countWrappedLines`) splits at character boundaries.
//
// These tests pin the contract: a long sentence in a narrow Text rect
// must NOT split words across rows. Failing on main; switch the
// renderer + measurer to consult `TextLayout.wrapWords` to make them
// pass.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite("Text primitive — word-aware wrap")
@MainActor
struct TextPrimitiveWrapTests {

    @Test("rendering a long sentence in a narrow rect breaks on word boundaries")
    func longSentenceWrapsAtWordBoundaries() {
        resetGraphContext()
        let sentence = "type a very long line and see if it will properly wrap and do the right thing"
        let view = Text(sentence)
        let graph = AttributeGraph()
        graph.update(from: view)

        // Narrow rect: 20 cells wide, 8 rows tall.
        var buffer = CellBuffer(width: 20, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Read back rows and check no row's last char + next row's
        // first char form a word that's contiguous in the source.
        var rows: [String] = []
        for r in 0..<8 {
            var line = ""
            for c in 0..<20 {
                line.append(buffer[c, r].character)
            }
            rows.append(line.trimmingCharacters(in: .whitespaces))
        }
        // Drop trailing empty rows.
        while rows.last == "" { rows.removeLast() }

        // First requirement: there must be MORE than one rendered row
        // (otherwise we know the renderer just clipped — wrap never
        // happened, and the row-pair check below would vacuously
        // pass).
        #expect(rows.count >= 2,
                "long sentence in narrow rect must wrap to multiple rows; got \(rows.count): \(rows)")

        for i in 0..<rows.count - 1 {
            let a = rows[i]
            let b = rows[i + 1]
            if let last = a.last, let first = b.first,
               last.isLetter, first.isLetter
            {
                let pair = "\(last)\(first)"
                #expect(!sentence.contains(pair),
                        "row \(i)='\(a)' + row \(i+1)='\(b)' splits a word: '\(pair)' is contiguous in source")
            }
        }
    }

    @Test("countWrappedLines reports the same row count as TextLayout.wrapWords")
    func measurerAgreesWithTextLayout() {
        let s = "type a very long line and see if it will properly wrap"
        let width = 20
        let measured = GraphMeasurer.countWrappedLines(s, width: width)
        let wrapped = TextLayout.wrapWords(s, width: width).count
        #expect(measured == wrapped,
                "measurer reported \(measured) rows but TextLayout produces \(wrapped) chunks")
    }
}
