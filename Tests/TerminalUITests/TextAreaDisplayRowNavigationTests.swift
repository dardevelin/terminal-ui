import Testing
@testable import TerminalUI

// TextArea display-row navigation — when arrowMode is `.display`,
// Up/Down step through wrapped chunks of the current logical line
// before crossing to the next logical line. The companion
// `TextAreaArrowMode.logical` (the simpler model where Down jumps to
// the next LOGICAL line, skipping wrapped chunks) is covered in
// `TextAreaWrapTests`.
//
// Cursor projection (logical row, col) ↔ (display row, column) is the
// heart of the navigation logic — `WrappedLine`, which PromptInput draws
// and moves through too. Selection drawing across wrap boundaries reuses
// the same projection so highlights span chunks correctly.

@Suite("TextArea — display-row arrow mode + scroll + selection across wraps")
@MainActor
struct TextAreaDisplayRowNavigationTests {

    // MARK: - Cursor projection (logical → display)

    @Test("cursor at logical (0, 25) on a wrapped line projects to chunk 1")
    func cursorProjectsToCorrectChunk() {
        // "type a very long line and see if it will properly wrap" wraps
        // at width 20 to: ["type a very long ", "line and see if it ", "will properly wrap"].
        let line = "type a very long line and see if it will properly wrap"
        let caret = WrappedLine(line, width: 20).caret(at: 25)
        #expect(caret.row == 1)
        #expect(caret.column == 8)
    }

    @Test("cursor at logical col 0 projects to chunk 0 col 0")
    func cursorAtStart() {
        let caret = WrappedLine("type a very long line", width: 10).caret(at: 0)
        #expect(caret.row == 0)
        #expect(caret.column == 0)
    }

    @Test("cursor at end of logical line projects to last chunk's end")
    func cursorAtEnd() {
        let line = "type a very long line"
        let caret = WrappedLine(line, width: 10).caret(at: line.count)
        let chunks = TextLayout.wrapWords(line, width: 10)
        #expect(caret.row == chunks.count - 1)
        #expect(caret.column == chunks.last?.count ?? 0)
    }

    // MARK: - Arrow mode .display

    @Test(".display arrow Down on wrapped line advances to next chunk of same logical line")
    func displayArrowDownAdvancesChunk() {
        let line = "type a very long line and see if it will properly wrap"
        let text = WrappedText(lines: [line], width: 15)
        let moved = text.caret(movedBy: 1, from: 5, line: 0, column: 5)
        let start = text.line(0).rows[1].lowerBound
        #expect(moved?.line == 0)
        #expect(moved?.index == start + 5, "Down from column 5 lands on column 5 of the next row")
    }

    @Test(".display Down on last chunk crosses to next logical line's chunk 0")
    func displayArrowDownCrossesLogicalBoundary() {
        let text = WrappedText(lines: ["short", "another short"], width: 20)
        let moved = text.caret(movedBy: 1, from: 3, line: 0, column: 3)
        #expect(moved?.line == 1)
        #expect(moved?.index == 3)
        #expect(text.caret(movedBy: 1, from: 3, line: 1, column: 3) == nil, "no row below the last")
    }

    // MARK: - Display-row scrolling

    @Test("clampScrollDisplayRows keeps cursor's display row in viewport")
    func clampScrollKeepsDisplayRowVisible() {
        // 5 logical lines, line 0 wraps to 3 chunks, others single
        // row. Total = 7 display rows. visibleHeight = 4. Cursor on
        // logical line 4 (= display row 6). scrollOffset must adjust
        // so display row 6 is in [scroll, scroll+4).
        let lines = [
            "this is a long first line that wraps multiple times here",  // 3 chunks at width 20
            "two", "three", "four", "five",
        ]
        let scroll = TextArea.clampScrollDisplayRows(
            cursorLogicalRow: 4, cursorLogicalCol: 0,
            lines: lines, currentScroll: 0,
            visibleHeight: 4, wrapWidth: 20
        )
        // Cursor's display row for logical (4, 0): wrap(0)=3, +1+1+1+1 = 7 → display row 6.
        // visibleHeight=4 → scroll must be at least 6-4+1 = 3.
        #expect(scroll >= 3, "scroll must show display row 6 in 4-row viewport; got \(scroll)")
    }

    @Test("clampScrollDisplayRows scrolls UP when cursor is above viewport")
    func clampScrollScrollsUp() {
        let lines = ["a", "b", "c", "d", "e"]
        let scroll = TextArea.clampScrollDisplayRows(
            cursorLogicalRow: 0, cursorLogicalCol: 0,
            lines: lines, currentScroll: 3,
            visibleHeight: 2, wrapWidth: 80
        )
        #expect(scroll == 0, "scroll must reach 0 to show cursor on row 0; got \(scroll)")
    }

    // MARK: - Selection across wrap boundaries

    // MARK: - End-to-end arrow-mode integration

    @Test(".logical arrow Down jumps from chunk-1-of-3 directly to next logical line")
    func endToEndLogicalArrowDown() {
        // logical line 0 wraps to ~3 chunks at width 20; logical line
        // 1 is short. With arrowMode=.logical (default), pressing
        // Down from cursor on line 0 must land on line 1.
        var content = "type a very long line and see if it will properly wrap\nshort"
        var editorState = TextAreaState()
        editorState.cursor = TextAreaCursor(row: 0, col: 5)
        let textBinding = Binding(get: { content }, set: { content = $0 })
        let stateBinding = Binding(
            get: { editorState },
            set: { editorState = $0 }
        )
        let result = TextArea.handleKey(
            KeyEvent(key: .down),
            text: textBinding,
            state: stateBinding,
            visibleHeight: 8,
            arrowMode: .logical,
            wrapWidth: 20
        )
        #expect(result == .handled)
        #expect(editorState.cursor.row == 1,
                ".logical Down must jump to next LOGICAL line; got row \(editorState.cursor.row)")
    }

    @Test(".display arrow Down stays within wrapped logical line")
    func endToEndDisplayArrowDown() {
        // Same content, but arrowMode=.display: Down from cursor on
        // chunk 0 of line 0 must STAY on logical line 0 (now on
        // chunk 1).
        var content = "type a very long line and see if it will properly wrap\nshort"
        var editorState = TextAreaState()
        editorState.cursor = TextAreaCursor(row: 0, col: 5)
        let textBinding = Binding(get: { content }, set: { content = $0 })
        let stateBinding = Binding(
            get: { editorState },
            set: { editorState = $0 }
        )
        let result = TextArea.handleKey(
            KeyEvent(key: .down),
            text: textBinding,
            state: stateBinding,
            visibleHeight: 8,
            arrowMode: .display,
            wrapWidth: 20
        )
        #expect(result == .handled)
        #expect(editorState.cursor.row == 0,
                ".display Down on wrapped line must stay on logical row 0; got row \(editorState.cursor.row)")
        #expect(editorState.cursor.col > 5,
                ".display Down should advance col into the next chunk; got col \(editorState.cursor.col)")
    }

    @Test("selection range that crosses chunk boundary highlights both chunks")
    func selectionCrossesChunkBoundary() {
        // Single logical line wrapping to 2+ chunks. Selection spans
        // a region that straddles a chunk boundary. Render and read
        // back cells; check both chunks have selection highlight on
        // the corresponding columns.
        let content = "type a very long line and see if it will properly wrap"
        var contentVar = content
        var state = TextAreaState()
        state.cursor = TextAreaCursor(row: 0, col: 30)
        // Select cols 10..40 (covers across the chunk boundary)
        state.selection = TextAreaSelection(
            start: TextAreaCursor(row: 0, col: 10),
            end: TextAreaCursor(row: 0, col: 40)
        )
        let textBinding = Binding(get: { contentVar }, set: { contentVar = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = TextArea(text: textBinding, state: stateBinding, visibleHeight: 8)

        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 20, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Count cells with the selection background colour across all
        // rendered rows. Selection range covers 30 logical cols
        // (40-10=30), spanning at least two display rows when wrap
        // splits the line.
        var cellsWithSelectionBg = 0
        for r in 0..<8 {
            for c in 0..<20 {
                if buffer[c, r].style.background == .blue {
                    cellsWithSelectionBg += 1
                }
            }
        }
        #expect(cellsWithSelectionBg >= 20,
                "selection of 30 cols must highlight ≥20 cells across chunks; got \(cellsWithSelectionBg)")
    }
}
