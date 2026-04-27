/// Editing state for a TextArea. Create one per editor instance and pass it
/// as a `Binding` so the state persists across re-evaluations.
///
/// Usage:
/// ```
/// @TerminalState var source = ""
/// @TerminalState var editorState = TextAreaState()
/// TextArea(text: $source, state: $editorState)
/// ```
public struct TextAreaState: Equatable, Sendable {
    /// Current cursor row/col within the document.
    public var cursor: TextAreaCursor = .zero
    /// Vertical scroll offset (first visible row).
    public var scrollOffset: Int = 0
    /// Active selection range, if any.
    public var selection: TextAreaSelection?
    /// Desired column preserved during vertical movement (sticky column).
    public var desiredCol: Int?

    public init() {}
}

/// Row/column position within a TextArea document.
public struct TextAreaCursor: Equatable, Sendable {
    public var row: Int
    public var col: Int

    public static let zero = TextAreaCursor(row: 0, col: 0)

    public init(row: Int = 0, col: Int = 0) {
        self.row = row
        self.col = col
    }
}

/// A selected range within a TextArea document.
public struct TextAreaSelection: Equatable, Sendable {
    public var start: TextAreaCursor
    public var end: TextAreaCursor

    /// Returns (first, last) in document order.
    public var ordered: (TextAreaCursor, TextAreaCursor) {
        if start.row < end.row || (start.row == end.row && start.col <= end.col) {
            return (start, end)
        }
        return (end, start)
    }

    public var isEmpty: Bool { start == end }

    public init(start: TextAreaCursor, end: TextAreaCursor) {
        self.start = start
        self.end = end
    }
}

// MARK: - TextArea View

/// A multi-line text editor with cursor positioning, selection, and scrolling.
///
/// Supports arrow key navigation (char/line), Ctrl+A/E (home/end),
/// Ctrl+Left/Right (word jump), Shift+arrow selection, insert/delete/backspace,
/// newline, vertical scrolling, and optional line numbers.
///
/// Usage:
/// ```
/// @TerminalState var source = ""
/// @TerminalState var editorState = TextAreaState()
///
/// TextArea(text: $source, state: $editorState)
///     .frame(width: 60, height: 20)
///
/// TextArea(text: $source, state: $editorState, lineNumbers: true)
/// ```
/// Arrow-key behaviour for TextArea.
///
/// Mirrors `PromptArrowMode` and SwiftUI's TextEditor convention.
/// `.logical` is the simpler model — Up/Down move between LOGICAL
/// lines, skipping wrapped chunks. `.display` walks through wrapped
/// chunks of the current logical line before crossing to the next
/// (matches SwiftUI's TextEditor).
public enum TextAreaArrowMode: Sendable, Equatable {
    /// Up/Down move between logical lines. Wrapped chunks of a long
    /// line are skipped over — pressing Down on a 3-chunk wrapped
    /// line jumps to the NEXT logical line directly. Default for
    /// backward compatibility with the original logical-row cursor
    /// model.
    case logical
    /// Up/Down walk display rows. Long wrapped lines step through
    /// each chunk before moving to the next logical line. Matches
    /// SwiftUI's TextEditor behaviour.
    case display
}

public struct TextArea: TerminalView {
    public let text: Binding<String>
    public let state: Binding<TextAreaState>
    public let lineNumbers: Bool
    /// Explicit visible height in rows. `nil` (default) fits to container.
    /// Old int-default (10) preserved as the fallback when no container
    /// height is known.
    public let visibleHeight: Int?
    /// arrow-key navigation mode. `.logical`
    /// (default) preserves backward-compat; `.display` enables
    /// SwiftUI-style display-row navigation through wrapped chunks.
    public let arrowMode: TextAreaArrowMode

    /// Boundary-feedback mode read at body-eval time. Drives the
    /// `BoundaryFeedbackEmitter.shared.emit` calls at the four
    /// buffer-edge walls in `handleKey` (Left at (0,0), Right at end,
    /// Up on row 0, Down on last row).
    @TerminalEnvironment(\.boundaryFeedback) var boundaryFeedback

    /// Optional `.onBoundaryHit { reason in ... }` callback.
    @TerminalEnvironment(\.onBoundaryHit) var onBoundaryHit

    /// Read at body-eval time. When false (a `.disabled()` ancestor
    /// has run), the editor's visible content is rendered through a
    /// `.gray` foreground modifier — the visual half of `.disabled()`.
    @TerminalEnvironment(\.isEnabled) var isEnabled

    // -- Display constants --

    /// Width of line number gutter (separator + space after digits)
    private static let gutterPadding = 2
    /// Minimum digit width for line numbers
    private static let minGutterDigits = 3
    /// Character shown at cursor position when at end of line or on empty line
    private static let cursorBlock: Character = "▏"

    // -- Colors --

    private static let lineNumberFg: Color = .gray
    private static let cursorFg: Color = .white
    private static let cursorBg: Color = .cyan
    private static let selectionBg: Color = .blue
    private static let emptyRowMarkerFg: Color = .ansi256(240)

    public init(
        text: Binding<String>,
        state: Binding<TextAreaState>,
        lineNumbers: Bool = false,
        visibleHeight: Int? = nil,
        arrowMode: TextAreaArrowMode = .logical
    ) {
        self.text = text
        self.state = state
        self.lineNumbers = lineNumbers
        self.visibleHeight = visibleHeight
        self.arrowMode = arrowMode
    }

    // MARK: - Body

    public var body: some TerminalView {
        // Capture boundary-feedback + isEnabled env at body-eval time;
        // the GR closure runs later when GraphContext.currentEnvironment
        // may be nil. Same pattern as TextInput
        // (`feedback_bindings_in_geometryreader.md`).
        let boundaryMode = boundaryFeedback
        let onBoundaryHit = self.onBoundaryHit
        let isEnabled = self.isEnabled
        return GeometryReader { size in
            self.renderEditor(
                containerWidth: size.width,
                containerHeight: size.height,
                boundaryMode: boundaryMode,
                onBoundaryHit: onBoundaryHit,
                isEnabled: isEnabled
            )
        }
    }

    /// Resolve visible height: caller-supplied > container > 10-fallback.
    private func effectiveVisibleHeight(containerHeight: Int) -> Int {
        if let explicit = visibleHeight { return max(1, explicit) }
        if containerHeight > 0 { return containerHeight }
        return 10
    }

    /// Compute the soft-wrap width for the body content: container
    /// width minus the rendered gutter prefix length (when line
    /// numbers are on). long logical lines wrap at
    /// this width via `TextLayout.wrapWords` so content stays inside
    /// the visible rect.
    ///
    /// Note: `gutterWidth(for:)` returns `digits + gutterPadding(=2)`,
    /// but the actual rendered prefix is `pad + num + " │ "` whose
    /// width is `gutterWidth + 1` (the separator-and-space costs 3
    /// cells, not 2). Pre-existing inconsistency we work around here
    /// by adding 1 — fixing `gutterPadding` would shift every
    /// existing TextArea visual.
    private func effectiveWrapWidth(containerWidth: Int, totalLines: Int) -> Int {
        let gutter = lineNumbers ? (Self.gutterWidth(for: totalLines) + 1) : 0
        return max(1, containerWidth - gutter)
    }

    private func renderEditor(containerWidth: Int,
                              containerHeight: Int,
                              boundaryMode: BoundaryFeedback,
                              onBoundaryHit: BoundaryHitCallback?,
                              isEnabled: Bool) -> some TerminalView {
        let visibleHeight = effectiveVisibleHeight(containerHeight: containerHeight)
        let content = text.get()
        let editorState = state.get()
        let lines = Self.splitLines(content)
        let cursor = Self.clampCursor(editorState.cursor, lines: lines)
        let wrapWidth = effectiveWrapWidth(containerWidth: containerWidth, totalLines: lines.count)
        // when arrow mode is `.display`, scroll is
        // display-row-keyed so wrapped chunks of an earlier line
        // count toward the scroll position. `.logical` mode keeps the
        // legacy logical-row scroll for backward-compat.
        let scrollOffset: Int
        switch arrowMode {
        case .logical:
            scrollOffset = Self.clampScroll(
                cursor: cursor,
                currentScroll: editorState.scrollOffset,
                visibleHeight: visibleHeight
            )
        case .display:
            scrollOffset = Self.clampScrollDisplayRows(
                cursorLogicalRow: cursor.row,
                cursorLogicalCol: cursor.col,
                lines: lines,
                currentScroll: editorState.scrollOffset,
                visibleHeight: visibleHeight,
                wrapWidth: wrapWidth
            )
        }
        let displaySpans = Self.buildDisplaySpans(
            lines: lines,
            cursor: cursor,
            selection: editorState.selection,
            scrollOffset: scrollOffset,
            visibleHeight: visibleHeight,
            lineNumbers: lineNumbers,
            wrapWidth: wrapWidth
        )
        return Text(spans: displaySpans)
            .foreground(isEnabled ? .default : .gray)
            .focusable()
            .onKeyPress { [text, state, arrowMode, boundaryMode, onBoundaryHit] event in
                Self.handleKey(
                    event,
                    text: text,
                    state: state,
                    visibleHeight: visibleHeight,
                    arrowMode: arrowMode,
                    wrapWidth: wrapWidth,
                    boundaryMode: boundaryMode,
                    onBoundaryHit: onBoundaryHit
                )
            }
    }

    // MARK: - Line Splitting

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        return parts.map(String.init)
    }

    // MARK: - Cursor Clamping

    static func clampCursor(_ cursor: TextAreaCursor, lines: [String]) -> TextAreaCursor {
        let row = max(0, min(cursor.row, lines.count - 1))
        let col = max(0, min(cursor.col, lines[row].count))
        return TextAreaCursor(row: row, col: col)
    }

    // MARK: - Scroll Clamping

    static func clampScroll(cursor: TextAreaCursor, currentScroll: Int, visibleHeight: Int) -> Int {
        var scroll = currentScroll
        if cursor.row < scroll {
            scroll = cursor.row
        }
        if cursor.row >= scroll + visibleHeight {
            scroll = cursor.row - visibleHeight + 1
        }
        return max(0, scroll)
    }

    // MARK: - Cursor projection (logical → display row)

    /// Project a logical column into (chunkIndex, columnInChunk) for
    /// the wrapped chunks of `logicalLine`. Used by `.display` arrow
    /// mode to walk wrapped chunks of a single logical line before
    /// crossing logical-line boundaries.
    ///
    /// Mirrors `PromptInput.projectCursor` shape but operates on a
    /// single logical line — the caller resolves logical row first
    /// and passes just the line.
    ///
    /// Reassembly contract: `wrapWords` may drop a single space at a
    /// wrap boundary; we account for that with `consumed` so the
    /// projection lands at the right column.
    static func projectCursor(logicalLine: String, logicalCol: Int, wrapWidth: Int)
        -> (chunkIndex: Int, columnInChunk: Int)
    {
        guard wrapWidth > 0 else { return (0, logicalCol) }
        let chunks = TextLayout.wrapWords(logicalLine, width: wrapWidth)
        if chunks.isEmpty { return (0, 0) }

        var consumed = 0  // logical chars accounted for so far
        for (idx, chunk) in chunks.enumerated() {
            let chunkLen = chunk.count
            let chunkEnd = consumed + chunkLen
            // Cursor is inside or at the end of this chunk?
            if logicalCol <= chunkEnd {
                return (idx, max(0, logicalCol - consumed))
            }
            // Past this chunk — advance, accounting for a possibly-
            // dropped boundary space in the source line.
            consumed = chunkEnd
            if consumed < logicalLine.count {
                let nextCharIdx = logicalLine.index(logicalLine.startIndex, offsetBy: consumed)
                if logicalLine[nextCharIdx] == " " {
                    consumed += 1
                }
            }
        }
        // Past every chunk — pin to the last chunk's end.
        let last = chunks.count - 1
        return (last, chunks[last].count)
    }

    /// Inverse of `projectCursor`: given `(chunkIndex, columnInChunk)`,
    /// return the absolute logical column. Pre-computed `chunks` is
    /// passed in so callers can reuse a single wrap call. The
    /// `logicalLine` is used to detect dropped boundary spaces so the
    /// reconstructed column lands on the correct source character.
    static func unprojectCursor(
        chunks: [String],
        chunkIndex: Int,
        columnInChunk: Int,
        logicalLine: String
    ) -> Int {
        guard !chunks.isEmpty else { return 0 }
        let safeIdx = max(0, min(chunkIndex, chunks.count - 1))
        var consumed = 0
        for i in 0..<safeIdx {
            consumed += chunks[i].count
            if consumed < logicalLine.count {
                let nextCharIdx = logicalLine.index(logicalLine.startIndex, offsetBy: consumed)
                if logicalLine[nextCharIdx] == " " {
                    consumed += 1
                }
            }
        }
        let safeCol = max(0, min(columnInChunk, chunks[safeIdx].count))
        return min(consumed + safeCol, logicalLine.count)
    }

    /// Resolve `.display` arrow Down. Returns the destination
    /// (chunkIndex, columnInChunk) within the current OR next logical
    /// line. A returned `chunkIndex == -1` is the sentinel meaning
    /// "cross to next logical line; caller manages the row jump and
    /// re-projects with `chunksOfNextLine`".
    ///
    /// `desiredCol` is the sticky column the cursor is trying to
    /// preserve across vertical movement (SwiftUI `desiredCol`).
    static func displayArrowDown(
        currentChunk: Int,
        currentCol: Int,
        chunksOfCurrentLine: [String],
        chunksOfNextLine: [String]?,
        desiredCol: Int
    ) -> (chunkIndex: Int, columnInChunk: Int) {
        // Try advancing within the current logical line's chunks.
        if currentChunk + 1 < chunksOfCurrentLine.count {
            let nextChunk = chunksOfCurrentLine[currentChunk + 1]
            let col = min(desiredCol, nextChunk.count)
            return (currentChunk + 1, col)
        }
        // Last chunk → cross logical-line boundary. Sentinel.
        if let nextChunks = chunksOfNextLine, !nextChunks.isEmpty {
            let col = min(desiredCol, nextChunks[0].count)
            return (-1, col)
        }
        // No next line — stay put.
        return (currentChunk, currentCol)
    }

    /// Symmetric for arrow Up.
    static func displayArrowUp(
        currentChunk: Int,
        currentCol: Int,
        chunksOfCurrentLine: [String],
        chunksOfPreviousLine: [String]?,
        desiredCol: Int
    ) -> (chunkIndex: Int, columnInChunk: Int) {
        if currentChunk > 0 {
            let prevChunk = chunksOfCurrentLine[currentChunk - 1]
            let col = min(desiredCol, prevChunk.count)
            return (currentChunk - 1, col)
        }
        if let prevChunks = chunksOfPreviousLine, !prevChunks.isEmpty {
            let lastIdx = prevChunks.count - 1
            let col = min(desiredCol, prevChunks[lastIdx].count)
            return (-1, col)
        }
        return (currentChunk, currentCol)
    }

    /// Compute the absolute display row index for a logical (row, col)
    /// position given the wrap width. Sums display rows above the
    /// cursor's logical line, then adds the chunk index within that
    /// line.
    static func cursorDisplayRow(
        cursorLogicalRow: Int,
        cursorLogicalCol: Int,
        lines: [String],
        wrapWidth: Int
    ) -> Int {
        var displayRow = 0
        for r in 0..<min(cursorLogicalRow, lines.count) {
            let chunks = TextLayout.wrapWords(lines[r], width: wrapWidth)
            displayRow += max(1, chunks.count)
        }
        if cursorLogicalRow < lines.count {
            let (chunkIdx, _) = projectCursor(
                logicalLine: lines[cursorLogicalRow],
                logicalCol: cursorLogicalCol,
                wrapWidth: wrapWidth
            )
            displayRow += chunkIdx
        }
        return displayRow
    }

    /// Display-row scroll clamp. Unlike `clampScroll` (logical-row),
    /// this projects the cursor's logical position to its display row
    /// then keeps THAT row in the viewport. Used when soft-wrap is
    /// active so a wrapped earlier line's chunks count toward scroll.
    static func clampScrollDisplayRows(
        cursorLogicalRow: Int,
        cursorLogicalCol: Int,
        lines: [String],
        currentScroll: Int,
        visibleHeight: Int,
        wrapWidth: Int
    ) -> Int {
        let cursorDisplay = cursorDisplayRow(
            cursorLogicalRow: cursorLogicalRow,
            cursorLogicalCol: cursorLogicalCol,
            lines: lines,
            wrapWidth: wrapWidth
        )
        var scroll = currentScroll
        if cursorDisplay < scroll {
            scroll = cursorDisplay
        }
        if cursorDisplay >= scroll + visibleHeight {
            scroll = cursorDisplay - visibleHeight + 1
        }
        return max(0, scroll)
    }

    // MARK: - Display Span Building

    static func buildDisplaySpans(
        lines: [String],
        cursor: TextAreaCursor,
        selection: TextAreaSelection?,
        scrollOffset: Int,
        visibleHeight: Int,
        lineNumbers: Bool,
        wrapWidth: Int = 0
    ) -> [TextSpan] {
        var spans: [TextSpan] = []
        let totalLines = lines.count
        let gutter = lineNumbers ? gutterWidth(for: totalLines) : 0
        let endRow = min(scrollOffset + visibleHeight, totalLines)

        // soft-wrap each visible logical line via
        // TextLayout. `wrapWidth == 0` keeps the legacy 1:1 logical→
        // display rendering — used by older test paths that don't
        // pass a width through.
        let softWrap = wrapWidth > 0

        // Display-row counter — increments per emitted display row,
        // including wrapped chunks. We stop emitting content when we
        // hit `visibleHeight` so a single very long logical line
        // can't overflow the viewport.
        var emittedRows = 0

        outer: for row in scrollOffset..<endRow {
            let line = lines[row]

            // Compute wrapped chunks for this logical line. When
            // soft-wrap is off we treat the line as a single chunk.
            let chunks: [String]
            if softWrap && line.count > wrapWidth && !line.isEmpty {
                chunks = TextLayout.wrapWords(line, width: wrapWidth)
            } else {
                chunks = [line]
            }

            // For each wrapped chunk produce one display row. Track
            // the column offset into the LOGICAL line so cursor /
            // selection positions resolve correctly across chunks.
            var chunkColStart = 0
            for (chunkIdx, chunk) in chunks.enumerated() {
                if emittedRows >= visibleHeight { break outer }

                if emittedRows > 0 {
                    spans.append(TextSpan("\n"))
                }

                // Line number gutter — only on the FIRST chunk of a
                // logical line; continuation chunks indent in the
                // gutter column with whitespace so the body aligns.
                if lineNumbers {
                    if chunkIdx == 0 {
                        let num = String(row + 1)
                        let pad = String(repeating: " ", count: max(0, gutter - gutterPadding - num.count))
                        spans.append(TextSpan(pad + num + " \u{2502} ", foreground: lineNumberFg))
                    } else {
                        let pad = String(repeating: " ", count: max(0, gutter))
                        spans.append(TextSpan(pad, foreground: lineNumberFg))
                    }
                }

                let chunkColEnd = chunkColStart + chunk.count
                // Empty chunk on an empty logical line
                if chunk.isEmpty {
                    if row == cursor.row && cursor.col >= chunkColStart && cursor.col <= chunkColEnd {
                        spans.append(TextSpan(String(cursorBlock), foreground: cursorFg, background: cursorBg))
                    }
                } else {
                    enum CharStyle { case normal, cursor, selected }
                    var currentStyle: CharStyle = .normal
                    var runStart = 0

                    func flushRun(upTo end: Int) {
                        guard end > runStart else { return }
                        let text = String(chunk[chunk.index(chunk.startIndex, offsetBy: runStart)..<chunk.index(chunk.startIndex, offsetBy: end)])
                        switch currentStyle {
                        case .cursor:
                            spans.append(TextSpan(text, foreground: cursorFg, background: cursorBg, bold: true))
                        case .selected:
                            spans.append(TextSpan(text, background: selectionBg))
                        case .normal:
                            spans.append(TextSpan(text))
                        }
                    }

                    for col in 0..<chunk.count {
                        let logicalCol = chunkColStart + col
                        let atCursor = row == cursor.row && logicalCol == cursor.col
                        let selected = isPositionSelected(row: row, col: logicalCol, selection: selection)
                        let style: CharStyle = atCursor ? .cursor : selected ? .selected : .normal

                        if col == 0 {
                            currentStyle = style
                        } else if style != currentStyle {
                            flushRun(upTo: col)
                            currentStyle = style
                            runStart = col
                        }
                    }
                    flushRun(upTo: chunk.count)

                    // Cursor past last character of this chunk —
                    // only when this is the LAST chunk of the
                    // logical line (otherwise cursor lives on the
                    // next chunk).
                    if row == cursor.row && cursor.col >= chunkColEnd
                        && chunkIdx == chunks.count - 1
                    {
                        spans.append(TextSpan(String(cursorBlock), foreground: cursorFg, background: cursorBg))
                    }
                }

                chunkColStart = chunkColEnd
                // Advance past the boundary space dropped by
                // wrapWords when the chunk transition happened on a
                // whitespace token. Reassembly contract: at most one
                // space per wrap point may be dropped.
                if chunkIdx < chunks.count - 1 {
                    // Look ahead: if the next chunk in the source
                    // line starts after a space, account for it.
                    let nextStart = chunkColEnd
                    if nextStart < line.count {
                        let idx = line.index(line.startIndex, offsetBy: nextStart)
                        if line[idx] == " " {
                            chunkColStart += 1
                        }
                    }
                }

                emittedRows += 1
            }
        }

        // Fill remaining rows with tilde markers.
        let remaining = visibleHeight - emittedRows
        if remaining > 0 {
            for _ in 0..<remaining {
                spans.append(TextSpan("\n"))
                if lineNumbers {
                    let pad = String(repeating: " ", count: max(0, gutter - gutterPadding - 1))
                    spans.append(TextSpan(pad + "~ \u{2502} ", foreground: emptyRowMarkerFg))
                } else {
                    spans.append(TextSpan("~", foreground: emptyRowMarkerFg))
                }
            }
        }

        return spans
    }

    static func gutterWidth(for totalLines: Int) -> Int {
        let digits = max(minGutterDigits, String(totalLines).count)
        return digits + gutterPadding
    }

    static func isPositionSelected(row: Int, col: Int, selection: TextAreaSelection?) -> Bool {
        guard let sel = selection, !sel.isEmpty else { return false }
        let (first, last) = sel.ordered
        if row < first.row || row > last.row { return false }
        if row == first.row && row == last.row {
            return col >= first.col && col < last.col
        }
        if row == first.row { return col >= first.col }
        if row == last.row { return col < last.col }
        return true
    }

    // MARK: - Key Handling

    static func handleKey(
        _ event: KeyEvent,
        text: Binding<String>,
        state: Binding<TextAreaState>,
        visibleHeight: Int,
        arrowMode: TextAreaArrowMode = .logical,
        wrapWidth: Int = 0,
        boundaryMode: BoundaryFeedback = .bounce,
        onBoundaryHit: BoundaryHitCallback? = nil
    ) -> KeyEventResult {
        var editorState = state.get()
        let content = text.get()
        var lines = splitLines(content)
        var cursor = clampCursor(editorState.cursor, lines: lines)
        let hasShift = event.modifiers.contains(.shift)
        let hasCtrl = event.modifiers.contains(.ctrl)

        // Synthesize the env slice the emitter consults so emit call
        // sites stay terse — same pattern as TextInput.handleKey.
        var emitEnv = EnvironmentValues()
        emitEnv.boundaryFeedback = boundaryMode
        emitEnv.onBoundaryHit = onBoundaryHit

        // Capture anchor for selection before any movement
        let anchorBeforeMove = cursor

        func commitCursorMove() {
            if hasShift {
                if editorState.selection == nil {
                    editorState.selection = TextAreaSelection(start: anchorBeforeMove, end: cursor)
                } else {
                    editorState.selection?.end = cursor
                }
            } else {
                editorState.selection = nil
            }
            editorState.cursor = cursor
            editorState.scrollOffset = clampScroll(
                cursor: cursor,
                currentScroll: editorState.scrollOffset,
                visibleHeight: visibleHeight
            )
            state.set(editorState)
        }

        func commitTextEdit() {
            editorState.cursor = cursor
            editorState.desiredCol = nil
            editorState.selection = nil
            editorState.scrollOffset = clampScroll(
                cursor: cursor,
                currentScroll: editorState.scrollOffset,
                visibleHeight: visibleHeight
            )
            text.set(joinLines(lines))
            state.set(editorState)
        }

        switch event.key {

        // MARK: Character Input

        case .character(let c):
            if hasCtrl {
                switch c {
                case "a":
                    cursor.col = 0
                    editorState.desiredCol = nil
                    commitCursorMove()
                    return .handled
                case "e":
                    cursor.col = lines[cursor.row].count
                    editorState.desiredCol = nil
                    commitCursorMove()
                    return .handled
                default:
                    return .ignored
                }
            }

            guard !event.modifiers.contains(.alt) else { return .ignored }

            // Replace selection with typed character
            if let sel = editorState.selection, !sel.isEmpty {
                deleteSelection(lines: &lines, selection: sel, cursor: &cursor)
            }

            insertCharacter(c, at: &cursor, in: &lines)
            commitTextEdit()
            return .handled

        // MARK: Enter

        case .enter:
            if let sel = editorState.selection, !sel.isEmpty {
                deleteSelection(lines: &lines, selection: sel, cursor: &cursor)
            }
            insertNewline(at: &cursor, in: &lines)
            commitTextEdit()
            return .handled

        // MARK: Backspace

        case .backspace:
            if let sel = editorState.selection, !sel.isEmpty {
                deleteSelection(lines: &lines, selection: sel, cursor: &cursor)
                commitTextEdit()
                return .handled
            }
            guard performBackspace(at: &cursor, in: &lines) else { return .handled }
            commitTextEdit()
            return .handled

        // MARK: Delete

        case .delete:
            if let sel = editorState.selection, !sel.isEmpty {
                deleteSelection(lines: &lines, selection: sel, cursor: &cursor)
                commitTextEdit()
                return .handled
            }
            guard performDeleteForward(at: &cursor, in: &lines) else { return .handled }
            commitTextEdit()
            return .handled

        // MARK: Arrow Left

        case .left:
            if hasCtrl {
                cursor = wordLeft(from: cursor, in: lines)
            } else if cursor.col > 0 {
                cursor.col -= 1
            } else if cursor.row > 0 {
                cursor.row -= 1
                cursor.col = lines[cursor.row].count
            } else {
                // Wall: cursor is at (0, 0). Emit and stay put.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .leftEdge, env: emitEnv, callback: onBoundaryHit)
            }
            editorState.desiredCol = nil
            commitCursorMove()
            return .handled

        // MARK: Arrow Right

        case .right:
            let lineLen = lines[cursor.row].count
            if hasCtrl {
                cursor = wordRight(from: cursor, in: lines)
            } else if cursor.col < lineLen {
                cursor.col += 1
            } else if cursor.row < lines.count - 1 {
                cursor.row += 1
                cursor.col = 0
            } else {
                // Wall: cursor at end of last row. Emit and stay put.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .rightEdge, env: emitEnv, callback: onBoundaryHit)
            }
            editorState.desiredCol = nil
            commitCursorMove()
            return .handled

        // MARK: Arrow Up

        case .up:
            if arrowMode == .display && wrapWidth > 0 {
                // Project current cursor to (chunk, col) within the
                // current logical line, ask displayArrowUp for the
                // destination, and translate back to (row, col).
                let currentChunks = TextLayout.wrapWords(lines[cursor.row], width: wrapWidth)
                let (curChunk, _) = projectCursor(
                    logicalLine: lines[cursor.row],
                    logicalCol: cursor.col,
                    wrapWidth: wrapWidth
                )
                let desired = editorState.desiredCol ?? cursor.col
                let prevChunks: [String]? = cursor.row > 0
                    ? TextLayout.wrapWords(lines[cursor.row - 1], width: wrapWidth)
                    : nil
                let (newChunk, newCol) = displayArrowUp(
                    currentChunk: curChunk,
                    currentCol: cursor.col,
                    chunksOfCurrentLine: currentChunks,
                    chunksOfPreviousLine: prevChunks,
                    desiredCol: desired
                )
                if newChunk == -1 {
                    // Cross to previous logical line, last chunk.
                    cursor.row -= 1
                    let prev = prevChunks ?? []
                    cursor.col = unprojectCursor(
                        chunks: prev,
                        chunkIndex: prev.count - 1,
                        columnInChunk: newCol,
                        logicalLine: lines[cursor.row]
                    )
                } else if newChunk != curChunk {
                    // Move within current logical line — translate
                    // (chunk, col) back to logical col.
                    cursor.col = unprojectCursor(
                        chunks: currentChunks,
                        chunkIndex: newChunk,
                        columnInChunk: newCol,
                        logicalLine: lines[cursor.row]
                    )
                } else {
                    // Wall: row 0 + chunk 0, displayArrowUp returned
                    // (curChunk, currentCol) — no destination.
                    BoundaryFeedbackEmitter.shared.emit(
                        reason: .topEdge, env: emitEnv, callback: onBoundaryHit)
                }
                editorState.desiredCol = desired
            } else if cursor.row > 0 {
                let desired = editorState.desiredCol ?? cursor.col
                cursor.row -= 1
                cursor.col = min(desired, lines[cursor.row].count)
                editorState.desiredCol = desired
            } else {
                // .logical mode at row 0 — buffer-top wall.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .topEdge, env: emitEnv, callback: onBoundaryHit)
            }
            commitCursorMove()
            return .handled

        // MARK: Arrow Down

        case .down:
            if arrowMode == .display && wrapWidth > 0 {
                let currentChunks = TextLayout.wrapWords(lines[cursor.row], width: wrapWidth)
                let (curChunk, _) = projectCursor(
                    logicalLine: lines[cursor.row],
                    logicalCol: cursor.col,
                    wrapWidth: wrapWidth
                )
                let desired = editorState.desiredCol ?? cursor.col
                let nextChunks: [String]? = cursor.row + 1 < lines.count
                    ? TextLayout.wrapWords(lines[cursor.row + 1], width: wrapWidth)
                    : nil
                let (newChunk, newCol) = displayArrowDown(
                    currentChunk: curChunk,
                    currentCol: cursor.col,
                    chunksOfCurrentLine: currentChunks,
                    chunksOfNextLine: nextChunks,
                    desiredCol: desired
                )
                if newChunk == -1 {
                    // Cross to next logical line, chunk 0.
                    cursor.row += 1
                    let next = nextChunks ?? []
                    cursor.col = unprojectCursor(
                        chunks: next,
                        chunkIndex: 0,
                        columnInChunk: newCol,
                        logicalLine: lines[cursor.row]
                    )
                } else if newChunk != curChunk {
                    cursor.col = unprojectCursor(
                        chunks: currentChunks,
                        chunkIndex: newChunk,
                        columnInChunk: newCol,
                        logicalLine: lines[cursor.row]
                    )
                } else {
                    // Wall: last row + last chunk — no destination.
                    BoundaryFeedbackEmitter.shared.emit(
                        reason: .bottomEdge, env: emitEnv, callback: onBoundaryHit)
                }
                editorState.desiredCol = desired
            } else if cursor.row < lines.count - 1 {
                let desired = editorState.desiredCol ?? cursor.col
                cursor.row += 1
                cursor.col = min(desired, lines[cursor.row].count)
                editorState.desiredCol = desired
            } else {
                // .logical mode at last row — buffer-bottom wall.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .bottomEdge, env: emitEnv, callback: onBoundaryHit)
            }
            commitCursorMove()
            return .handled

        // MARK: Home / End

        case .home:
            cursor.col = 0
            editorState.desiredCol = nil
            commitCursorMove()
            return .handled

        case .end:
            cursor.col = lines[cursor.row].count
            editorState.desiredCol = nil
            commitCursorMove()
            return .handled

        // MARK: Page Up / Down

        case .pageUp:
            let jump = max(1, visibleHeight)
            cursor.row = max(0, cursor.row - jump)
            cursor.col = min(cursor.col, lines[cursor.row].count)
            commitCursorMove()
            return .handled

        case .pageDown:
            let jump = max(1, visibleHeight)
            cursor.row = min(lines.count - 1, cursor.row + jump)
            cursor.col = min(cursor.col, lines[cursor.row].count)
            commitCursorMove()
            return .handled

        default:
            return .ignored
        }
    }

    // MARK: - Text Mutation

    static func insertCharacter(_ ch: Character, at cursor: inout TextAreaCursor, in lines: inout [String]) {
        var line = lines[cursor.row]
        let idx = line.index(line.startIndex, offsetBy: min(cursor.col, line.count))
        line.insert(ch, at: idx)
        lines[cursor.row] = line
        cursor.col += 1
    }

    static func insertNewline(at cursor: inout TextAreaCursor, in lines: inout [String]) {
        let line = lines[cursor.row]
        let splitAt = line.index(line.startIndex, offsetBy: min(cursor.col, line.count))
        let before = String(line[line.startIndex..<splitAt])
        let after = String(line[splitAt..<line.endIndex])
        lines[cursor.row] = before
        lines.insert(after, at: cursor.row + 1)
        cursor.row += 1
        cursor.col = 0
    }

    /// Delete one character before the cursor. Returns `true` if a deletion occurred.
    static func performBackspace(at cursor: inout TextAreaCursor, in lines: inout [String]) -> Bool {
        if cursor.col > 0 {
            var line = lines[cursor.row]
            let removeAt = line.index(line.startIndex, offsetBy: cursor.col - 1)
            line.remove(at: removeAt)
            lines[cursor.row] = line
            cursor.col -= 1
            return true
        } else if cursor.row > 0 {
            let prevLen = lines[cursor.row - 1].count
            lines[cursor.row - 1] += lines[cursor.row]
            lines.remove(at: cursor.row)
            cursor.row -= 1
            cursor.col = prevLen
            return true
        }
        return false
    }

    /// Delete one character at the cursor. Returns `true` if a deletion occurred.
    static func performDeleteForward(at cursor: inout TextAreaCursor, in lines: inout [String]) -> Bool {
        let lineLen = lines[cursor.row].count
        if cursor.col < lineLen {
            var line = lines[cursor.row]
            let removeAt = line.index(line.startIndex, offsetBy: cursor.col)
            line.remove(at: removeAt)
            lines[cursor.row] = line
            return true
        } else if cursor.row < lines.count - 1 {
            lines[cursor.row] += lines[cursor.row + 1]
            lines.remove(at: cursor.row + 1)
            return true
        }
        return false
    }

    /// Delete a selection range. Sets cursor to the selection start.
    static func deleteSelection(
        lines: inout [String],
        selection: TextAreaSelection,
        cursor: inout TextAreaCursor
    ) {
        let (first, last) = selection.ordered

        if first.row == last.row {
            var line = lines[first.row]
            let startIdx = line.index(line.startIndex, offsetBy: min(first.col, line.count))
            let endIdx = line.index(line.startIndex, offsetBy: min(last.col, line.count))
            line.removeSubrange(startIdx..<endIdx)
            lines[first.row] = line
        } else {
            let firstLine = lines[first.row]
            let lastLine = lines[last.row]
            let keepBefore = String(firstLine.prefix(first.col))
            let keepAfter = String(lastLine.dropFirst(min(last.col, lastLine.count)))
            lines[first.row] = keepBefore + keepAfter
            if last.row > first.row {
                lines.removeSubrange((first.row + 1)...last.row)
            }
        }
        cursor = first
    }

    static func joinLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - Word Navigation

    static func wordLeft(from pos: TextAreaCursor, in lines: [String]) -> TextAreaCursor {
        var row = pos.row
        var col = pos.col

        if col == 0 {
            if row > 0 {
                row -= 1
                col = lines[row].count
            }
            return TextAreaCursor(row: row, col: col)
        }

        let chars = Array(lines[row])
        while col > 0 && chars[col - 1].isWhitespace { col -= 1 }
        while col > 0 && !chars[col - 1].isWhitespace { col -= 1 }
        return TextAreaCursor(row: row, col: col)
    }

    static func wordRight(from pos: TextAreaCursor, in lines: [String]) -> TextAreaCursor {
        var row = pos.row
        var col = pos.col
        let lineLen = lines[row].count

        if col >= lineLen {
            if row < lines.count - 1 {
                row += 1
                col = 0
            }
            return TextAreaCursor(row: row, col: col)
        }

        let chars = Array(lines[row])
        while col < chars.count && !chars[col].isWhitespace { col += 1 }
        while col < chars.count && chars[col].isWhitespace { col += 1 }
        return TextAreaCursor(row: row, col: col)
    }
}
