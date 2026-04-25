import Testing
@testable import TerminalUI

// HYP-122 — TextArea Phase 2: display-row arrow mode + scroll + cross-wrap selection.
//
// Phase 1 (HYP-120) shipped soft-wrap rendering with cursor staying
// logical-row-indexed. Arrow keys jumped to the next LOGICAL line
// even when the current line wrapped to multiple display rows.
//
// Phase 2 (this ticket):
//   - `TextAreaArrowMode` enum (`.logical` default, `.display` opt-in)
//   - `.display` mode: Down advances to next chunk of same logical
//     line before crossing logical-line boundary
//   - selection drawing across wrap boundaries highlights both chunks
//
// Cursor (logical row, col) ↔ (display row, col within chunk)
// projection is the heart of the change. Mirrors PromptInput's
// `projectCursor` shape.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite("HYP-122 — TextArea Phase 2 arrow modes + selection")
@MainActor
struct TextAreaPhase2Tests {

    // MARK: - Cursor projection (logical → display)

    @Test("cursor at logical (0, 25) on a wrapped line projects to chunk 1")
    func cursorProjectsToCorrectChunk() {
        // "type a very long line and see if it will properly wrap" wraps
        // at width 20 to: ["type a very long", "line and see if it", "will properly wrap"]
        // (or similar — TextLayout.wrapWords picks word boundaries).
        // Cursor at logical col 25 should land on chunk[1].
        let line = "type a very long line and see if it will properly wrap"
        let (chunkIdx, colInChunk) = TextArea.projectCursor(
            logicalLine: line, logicalCol: 25, wrapWidth: 20
        )
        #expect(chunkIdx >= 1, "logical col 25 should land past chunk 0; got chunk \(chunkIdx)")
        #expect(colInChunk >= 0)
    }

    @Test("cursor at logical col 0 projects to chunk 0 col 0")
    func cursorAtStart() {
        let line = "type a very long line"
        let (chunkIdx, colInChunk) = TextArea.projectCursor(
            logicalLine: line, logicalCol: 0, wrapWidth: 10
        )
        #expect(chunkIdx == 0)
        #expect(colInChunk == 0)
    }

    @Test("cursor at end of logical line projects to last chunk's end")
    func cursorAtEnd() {
        let line = "type a very long line"
        let (chunkIdx, colInChunk) = TextArea.projectCursor(
            logicalLine: line, logicalCol: line.count, wrapWidth: 10
        )
        let chunks = TextLayout.wrapWords(line, width: 10)
        #expect(chunkIdx == chunks.count - 1)
        #expect(colInChunk == chunks.last?.count ?? 0)
    }

    // MARK: - Arrow mode .display

    @Test(".display arrow Down on wrapped line advances to next chunk of same logical line")
    func displayArrowDownAdvancesChunk() {
        let line = "type a very long line and see if it will properly wrap"
        let chunks = TextLayout.wrapWords(line, width: 15)
        guard chunks.count >= 2 else {
            Issue.record("test setup needs ≥2 chunks; got \(chunks.count)")
            return
        }
        // Cursor on chunk 0 col 5. Down in .display mode should land
        // on chunk 1 at col 5 (or chunk 1's last col if shorter).
        let (newChunk, newCol) = TextArea.displayArrowDown(
            currentChunk: 0, currentCol: 5,
            chunksOfCurrentLine: chunks,
            chunksOfNextLine: nil,
            desiredCol: 5
        )
        #expect(newChunk == 1, "Down on chunk 0 should land on chunk 1; got \(newChunk)")
        #expect(newCol <= chunks[1].count, "col must be within chunk 1; got \(newCol)")
    }

    @Test(".display Down on last chunk crosses to next logical line's chunk 0")
    func displayArrowDownCrossesLogicalBoundary() {
        let lineA = "short"
        let lineB = "another short"
        let chunksA = TextLayout.wrapWords(lineA, width: 20)
        let chunksB = TextLayout.wrapWords(lineB, width: 20)
        let (newChunk, newCol) = TextArea.displayArrowDown(
            currentChunk: chunksA.count - 1, currentCol: 3,
            chunksOfCurrentLine: chunksA,
            chunksOfNextLine: chunksB,
            desiredCol: 3
        )
        // crossing logical → returns sentinel (-1, _) meaning "advance
        // logical row, project at col" OR returns (0, 3) and the
        // caller manages the row jump. We document the contract via
        // sentinel: chunk == -1 signals "cross boundary".
        #expect(newChunk == -1 || newChunk == 0,
                "expected sentinel or chunk 0 of next line; got \(newChunk)")
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
        resetGraphContext()
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
