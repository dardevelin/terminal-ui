/// One undo-stack snapshot — captures everything the editor needs to
/// restore the pre-edit state.
///
/// ``TextArea`` pushes one of these onto ``TextAreaState/undoStack`` before
/// every text mutation; Ctrl+Z pops it back. Apps only meet this type when
/// inspecting or persisting an editor's history.
public struct TextAreaSnapshot: Equatable, Sendable {
    /// The full document at snapshot time.
    public let text: String
    /// Where the cursor sat.
    public let cursor: TextAreaCursor
    /// The active selection, if any.
    public let selection: TextAreaSelection?

    /// Captures a restorable editor moment: document, cursor, and
    /// selection (`nil` when nothing was selected).
    public init(text: String, cursor: TextAreaCursor, selection: TextAreaSelection?) {
        self.text = text
        self.cursor = cursor
        self.selection = selection
    }
}

/// Editing state for a ``TextArea``: cursor, scroll, selection, and undo
/// history.
///
/// Create one per editor instance and pass it as a `Binding` so the state
/// persists across re-evaluations. The document itself lives in the
/// separate `text` binding — keeping the two apart is what lets an app
/// swap documents while preserving editor state, or reset the editor
/// without touching the text.
///
/// Usage:
/// ```swift
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
    /// The caret the view last moved to show. The view follows the caret
    /// only when it moves, so the wheel can scroll the text away from it
    /// without the next frame pulling the view back. Not part of `==`.
    var followedCursor: TextAreaCursor?
    /// Bounded undo/redo history. Each text-mutating key path pushes
    /// a snapshot of (text, cursor, selection) BEFORE the mutation.
    /// Ctrl+Z restores from `undoStack.undo()`; Ctrl+Shift+Z restores
    /// from `undoStack.redo()`. Default 100 entries.
    /// Equatable conformance ignores the
    /// internal stack contents to keep state-equality cheap on hot
    /// paths — the public-facing edit position is what `==` checks.
    public var undoStack: UndoStack<TextAreaSnapshot> = UndoStack(maxSize: 100)

    /// Creates fresh editor state: cursor at the origin, no scroll, no
    /// selection, empty 100-entry undo stack.
    public init() {}

    /// Compares the editor's visible position — cursor, scroll offset,
    /// selection and sticky column — and ignores ``undoStack``, so two
    /// states that differ only in history are equal.
    public static func == (lhs: TextAreaState, rhs: TextAreaState) -> Bool {
        lhs.cursor == rhs.cursor
            && lhs.scrollOffset == rhs.scrollOffset
            && lhs.selection == rhs.selection
            && lhs.desiredCol == rhs.desiredCol
        // undoStack intentionally excluded — equality compares the
        // visible editor state, not the history depth.
    }
}

/// Row/column position within a TextArea document.
///
/// Coordinates are *logical*: `row` indexes the `\n`-split lines and `col`
/// counts characters into that line — soft-wrap display rows are a
/// rendering concern and never appear here. `col == line.count` is the
/// valid "after the last character" insertion point.
public struct TextAreaCursor: Equatable, Sendable {
    /// Index into the document's `\n`-split lines.
    public var row: Int
    /// Character offset within the line, `0...line.count`.
    public var col: Int

    /// The document origin — row 0, column 0.
    public static let zero = TextAreaCursor(row: 0, col: 0)

    /// Creates a cursor position; both coordinates default to 0.
    public init(row: Int = 0, col: Int = 0) {
        self.row = row
        self.col = col
    }
}

/// A selected range within a TextArea document.
///
/// `start` is the anchor where Shift+arrow selection began; `end` follows
/// the cursor, so `end` may precede `start` in document order — use
/// ``TextAreaSelection/ordered`` when consuming the range.
public struct TextAreaSelection: Equatable, Sendable {
    /// The anchor — where selection began.
    public var start: TextAreaCursor
    /// The moving edge — follows the cursor.
    public var end: TextAreaCursor

    /// Returns (first, last) in document order.
    public var ordered: (TextAreaCursor, TextAreaCursor) {
        if start.row < end.row || (start.row == end.row && start.col <= end.col) {
            return (start, end)
        }
        return (end, start)
    }

    /// `true` when anchor and moving edge coincide — zero characters
    /// selected.
    public var isEmpty: Bool { start == end }

    /// Creates a selection from anchor to moving edge; `end` may precede
    /// `start` in document order.
    public init(start: TextAreaCursor, end: TextAreaCursor) {
        self.start = start
        self.end = end
    }
}

// MARK: - TextArea View

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

/// A multi-line text editor with cursor positioning, selection, scrolling,
/// and bounded undo.
///
/// Renders a viewport over a `\n`-delimited document: a block cursor while
/// the editor holds focus, the selection on a highlighted background,
/// vim-style `~` markers past the last line, and an optional line-number
/// gutter, all in ``Theme`` roles. Long logical lines soft-wrap at the
/// container width. Edits with the environment's ``TextKeymap``,
/// ``TextKeymap/standard`` unless a subtree sets one, with Shift+arrow
/// selection, undo and redo, and bracketed paste.
///
/// This is the *editor* of the text-entry trio: Enter inserts a newline and
/// never submits. Reach for ``TextInput`` for a one-line form field, or
/// ``PromptInput`` for a command prompt where Enter means "send" and Up
/// recalls history. The editor joins the Tab order via the framework's
/// `.focusable` machinery; while focused, printable keys edit the document,
/// so they must not be claimed by global chords.
///
/// The document lives in the `text` binding; everything else — cursor,
/// scroll, selection, undo history — lives in a ``TextAreaState`` the app
/// owns:
///
/// Usage:
/// ```swift
/// @TerminalState var source = ""
/// @TerminalState var editorState = TextAreaState()
///
/// TextArea(text: $source, state: $editorState)
///     .frame(width: 60, height: 20)
///
/// TextArea(text: $source, state: $editorState,
///          lineNumbers: true, visibleHeight: 6)
/// ```
public struct TextArea: TerminalView {
    /// The document, joined with `\n`. Every edit writes back through this
    /// binding, so external mutation (load a file, apply a patch) is just a
    /// set — the editor re-clamps its cursor to the new content.
    public let text: Binding<String>
    /// Cursor, scroll, selection, and undo state — see ``TextAreaState``.
    public let state: Binding<TextAreaState>
    /// Draws a right-aligned line-number gutter (`  1 │ `) when true.
    public let lineNumbers: Bool
    /// Explicit visible height in rows. `nil` (default) fits to container.
    /// Old int-default (10) preserved as the fallback when no container
    /// height is known.
    public let visibleHeight: Int?
    /// arrow-key navigation mode. `.logical`
    /// (default) preserves backward-compat; `.display` enables
    /// SwiftUI-style display-row navigation through wrapped chunks.
    public let arrowMode: TextAreaArrowMode
    /// Optional syntax highlighter. When non-nil, each rendered line
    /// is tokenised through this highlighter and the matching
    /// `SyntaxTheme` color is applied as the FOREGROUND of plain
    /// (non-cursor, non-selection) characters. Default `nil` keeps
    /// the legacy plain-text rendering — non-breaking.
    public let highlighter: (any SyntaxHighlighter)?
    /// Colours for `highlighter`'s tokens, or `nil` to follow the app
    /// ``Theme``'s ``Theme/syntax`` like every other view that draws code.
    /// Ignored when `highlighter` is nil.
    public let theme: SyntaxTheme?

    /// Supplies ``Theme/syntax`` when no `theme` was passed.
    @TerminalEnvironment(\.theme) private var appTheme

    /// The keymap, kill ring and boundary feedback the editor edits with.
    /// Read at body-eval time for the handlers, which run when no
    /// environment is bound. Set with `.textKeymap(_:)` and
    /// `.boundaryFeedback(_:)`.
    @TerminalEnvironment(\.textEditing) var textEditing

    /// Read at body-eval time. When false (a `.disabled()` ancestor
    /// has run), the editor's visible content is rendered in the theme's
    /// ``Theme/foregroundMuted`` — the visual half of `.disabled()`.
    @TerminalEnvironment(\.isEnabled) var isEnabled

    // -- Display constants --

    /// Width of line number gutter (separator + space after digits)
    private static let gutterPadding = 2
    /// Minimum digit width for line numbers
    private static let minGutterDigits = 3
    /// Character shown at cursor position when at end of line or on empty line
    private static let cursorBlock: Character = "▏"

    /// Creates an editor bound to its document and state.
    ///
    /// `text` is the document; `state` (cursor/scroll/selection/undo) must
    /// outlive re-evaluations. `lineNumbers` adds a gutter;
    /// `visibleHeight` caps the viewport in rows (`nil` sizes to content);
    /// `highlighter` `nil` renders plain text; `theme` colours its spans,
    /// and `nil` takes the colours from the app ``Theme``.
    public init(
        text: Binding<String>,
        state: Binding<TextAreaState>,
        lineNumbers: Bool = false,
        visibleHeight: Int? = nil,
        arrowMode: TextAreaArrowMode = .logical,
        highlighter: (any SyntaxHighlighter)? = nil,
        theme: SyntaxTheme? = nil
    ) {
        self.text = text
        self.state = state
        self.lineNumbers = lineNumbers
        self.visibleHeight = visibleHeight
        self.arrowMode = arrowMode
        self.highlighter = highlighter
        self.theme = theme
    }

    // MARK: - Body

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Capture boundary-feedback + isEnabled env at body-eval time;
        // the GR closure runs later when GraphContext.currentEnvironment
        // may be nil. Same pattern as TextInput
        // (`feedback_bindings_in_geometryreader.md`).
        let textEditing = self.textEditing
        let isEnabled = self.isEnabled
        return GeometryReader { size in
            self.renderEditor(
                containerWidth: size.width,
                containerHeight: size.height,
                textEditing: textEditing,
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
                              textEditing: TextEditingContext,
                              isEnabled: Bool) -> some TerminalView {
        let visibleHeight = effectiveVisibleHeight(containerHeight: containerHeight)
        let content = text.get()
        let editorState = state.get()
        let lines = TextLines.split(content)
        let cursor = Self.clampCursor(editorState.cursor, lines: lines)
        let wrapWidth = effectiveWrapWidth(containerWidth: containerWidth, totalLines: lines.count)
        // when arrow mode is `.display`, scroll is
        // display-row-keyed so wrapped chunks of an earlier line
        // count toward the scroll position. `.logical` mode keeps the
        // legacy logical-row scroll for backward-compat.
        let rowCount: Int
        switch arrowMode {
        case .logical:
            rowCount = lines.count
        case .display:
            rowCount = Self.cursorDisplayRow(cursorLogicalRow: max(0, lines.count - 1),
                                             cursorLogicalCol: lines.last?.count ?? 0,
                                             lines: lines, wrapWidth: wrapWidth) + 1
        }
        // The farthest the wheel takes the view: the last row at the bottom.
        let maxScroll = max(0, rowCount - visibleHeight)
        var scrollOffset = min(max(0, editorState.scrollOffset), maxScroll)
        // A caret that moved brings the view to it; one that did not leaves
        // the view wherever the wheel put it.
        if editorState.followedCursor != cursor {
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
            var followed = editorState
            followed.followedCursor = cursor
            followed.scrollOffset = scrollOffset
            state.set(followed)
        }
        let rows = TextAreaRows(
            lines: lines,
            cursor: cursor,
            selection: editorState.selection,
            scrollOffset: scrollOffset,
            visibleHeight: visibleHeight,
            lineNumbers: lineNumbers,
            wrapWidth: wrapWidth,
            highlighter: highlighter,
            theme: theme ?? appTheme.syntax
        )
        // The wheel scrolls the text and leaves the caret and the selection
        // alone; as arrows it moved the caret and cleared the selection.
        return rows.onScrollWheel { [state] key in
            var editor = state.get()
            let current = min(max(0, editor.scrollOffset), maxScroll)
            let next: Int
            switch key {
            case .up: next = max(0, current - 1)
            case .down: next = min(maxScroll, current + 1)
            default: return false
            }
            guard next != current else { return false }
            editor.scrollOffset = next
            state.set(editor)
            return true
        }
            .labelForeground(enabled: isEnabled, theme: appTheme)
            .focusable()
            // A click puts the caret where it lands, and drops the selection.
            .onClick { [state, lineNumbers] x, y in
                var editor = state.get()
                editor.cursor = Self.cursor(atColumn: x, row: y, lines: lines, scrollOffset: scrollOffset,
                                            lineNumbers: lineNumbers, wrapWidth: wrapWidth)
                editor.selection = nil
                // The column the next ↑/↓ aims for is the one clicked.
                editor.desiredCol = nil
                state.set(editor)
            }
            .onKeyPress { [text, state, arrowMode, textEditing] event in
                Self.handleKey(
                    event,
                    text: text,
                    state: state,
                    visibleHeight: visibleHeight,
                    arrowMode: arrowMode,
                    wrapWidth: wrapWidth,
                    textEditing: textEditing
                )
            }
            .onPaste { [text, state, visibleHeight] payload in
                Self.handlePaste(
                    payload,
                    text: text,
                    state: state,
                    visibleHeight: visibleHeight
                )
            }
    }

    /// Insert a bracketed-paste payload at the cursor, splitting on
    /// `\n` so embedded newlines become real logical-row breaks.
    /// Selection (if any) is replaced first, matching the type-a-char
    /// path. Cursor lands at the end of the last inserted segment.
    /// Scroll is re-clamped so the new cursor row is in view.
    static func handlePaste(_ payload: String,
                            text: Binding<String>,
                            state: Binding<TextAreaState>,
                            visibleHeight: Int) {
        guard !payload.isEmpty else { return }

        // Normalise CRLF / lone CR so paste from Windows or classic-Mac
        // sources splits on the same `\n` boundary as native input.
        let normalised = payload.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let segments = normalised.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var editorState = state.get()
        var lines = TextLines.split(text.get())
        var cursor = clampCursor(editorState.cursor, lines: lines)

        // Snapshot pre-paste state for undo. Pastes are atomic edits —
        // a single Ctrl+Z reverts the whole inserted block.
        editorState.undoStack.push(TextAreaSnapshot(
            text: text.get(),
            cursor: editorState.cursor,
            selection: editorState.selection
        ))

        if let sel = editorState.selection, !sel.isEmpty {
            deleteSelection(lines: &lines, selection: sel, cursor: &cursor)
            editorState.selection = nil
        }

        // Splice: first segment merges into current row at the cursor;
        // remaining segments become new rows below. Tail of the
        // original row latches onto the LAST inserted segment so the
        // post-cursor content stays contiguous after paste.
        let row = lines[cursor.row]
        let splitAt = row.index(row.startIndex, offsetBy: min(cursor.col, row.count))
        let before = String(row[row.startIndex..<splitAt])
        let after = String(row[splitAt..<row.endIndex])

        if segments.count == 1 {
            lines[cursor.row] = before + segments[0] + after
            cursor.col = before.count + segments[0].count
        } else {
            // Multi-segment paste: replace current row with `before +
            // first`, then insert middle segments as standalone rows,
            // then a final row of `last + after`.
            lines[cursor.row] = before + segments[0]
            var insertAt = cursor.row + 1
            for segment in segments[1..<(segments.count - 1)] {
                lines.insert(segment, at: insertAt)
                insertAt += 1
            }
            let lastSegment = segments[segments.count - 1]
            lines.insert(lastSegment + after, at: insertAt)
            cursor.row = insertAt
            cursor.col = lastSegment.count
        }

        editorState.cursor = cursor
        editorState.desiredCol = nil
        editorState.scrollOffset = clampScroll(
            cursor: cursor,
            currentScroll: editorState.scrollOffset,
            visibleHeight: visibleHeight
        )
        text.set(TextLines.join(lines))
        state.set(editorState)
    }

    // MARK: - Undo / Redo dispatch

    /// Apply the next undo snapshot. Builds a "current" snapshot from
    /// the live binding so the stack can preserve it for a subsequent
    /// Ctrl+Shift+Z redo. Restores text + cursor + selection from the
    /// popped pre-mutation snapshot. No-op when the stack has nothing
    /// to undo.
    static func applyUndo(text: Binding<String>,
                          state: Binding<TextAreaState>,
                          visibleHeight: Int) {
        var editorState = state.get()
        let now = TextAreaSnapshot(
            text: text.get(),
            cursor: editorState.cursor,
            selection: editorState.selection
        )
        guard let snap = editorState.undoStack.undo(now: now) else { return }
        text.set(snap.text)
        editorState.cursor = snap.cursor
        editorState.selection = snap.selection
        editorState.scrollOffset = clampScroll(
            cursor: snap.cursor,
            currentScroll: editorState.scrollOffset,
            visibleHeight: visibleHeight
        )
        state.set(editorState)
    }

    /// Apply the next redo snapshot. Mirror of `applyUndo`.
    static func applyRedo(text: Binding<String>,
                          state: Binding<TextAreaState>,
                          visibleHeight: Int) {
        var editorState = state.get()
        let now = TextAreaSnapshot(
            text: text.get(),
            cursor: editorState.cursor,
            selection: editorState.selection
        )
        guard let snap = editorState.undoStack.redo(now: now) else { return }
        text.set(snap.text)
        editorState.cursor = snap.cursor
        editorState.selection = snap.selection
        editorState.scrollOffset = clampScroll(
            cursor: snap.cursor,
            currentScroll: editorState.scrollOffset,
            visibleHeight: visibleHeight
        )
        state.set(editorState)
    }

    // MARK: - Line Splitting

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
        wrapWidth: Int = 0,
        highlighter: (any SyntaxHighlighter)? = nil,
        theme: SyntaxTheme = .defaultDark,
        showsCursor: Bool = true,
        cursorLit: Bool = false,
        chrome: any Theme = DefaultTheme()
    ) -> [TextSpan] {
        // The editor's own marks take theme roles, as `PromptInput`'s do: the
        // cursor is the accent with the character under it in emphasis, a
        // selection is the selected background, the gutter is chrome and the
        // rows past the end are the quietest step.
        let cursorFg = chrome.foregroundEmphasis
        let cursorBg = chrome.cursorColor(lit: cursorLit)
        let selectionBg = chrome.backgroundSelected
        let lineNumberFg = chrome.foregroundMuted
        let emptyRowMarkerFg = chrome.foregroundFaint
        var spans: [TextSpan] = []
        let totalLines = lines.count
        let gutter = lineNumbers ? gutterWidth(for: totalLines) : 0
        let endRow = min(scrollOffset + visibleHeight, totalLines)

        // Display-row counter — increments per emitted display row,
        // including wrapped chunks. We stop emitting content when we
        // hit `visibleHeight` so a single very long logical line
        // can't overflow the viewport.
        var emittedRows = 0

        // Pre-compute per-row syntax token colors with stateful carry
        // so `/* … */` and `"""…"""` spanning multiple lines colour
        // every continuation line correctly. We seed state by
        // scanning rows 0..<scrollOffset (lines above the viewport)
        // — this is O(scrollOffset) per render but keeps the
        // visible-row loop linear in width, not in scroll position.
        let perRowColors: [Int: [Color]] = perRowTokenColors(
            lines: lines, highlighter: highlighter, theme: theme,
            scrollOffset: scrollOffset, endRow: endRow
        )

        outer: for row in scrollOffset..<endRow {
            let line = lines[row]

            let chunks = displayChunks(of: line, wrapWidth: wrapWidth)

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
                        // As wide as the first chunk's `pad + num + " │ "`,
                        // so a wrapped line's text lines up under its start.
                        let pad = String(repeating: " ", count: max(0, gutter + 1))
                        spans.append(TextSpan(pad, foreground: lineNumberFg))
                    }
                }

                let chunkColEnd = chunkColStart + chunk.count
                // Empty chunk on an empty logical line
                if chunk.isEmpty {
                    if showsCursor && row == cursor.row
                        && cursor.col >= chunkColStart && cursor.col <= chunkColEnd {
                        spans.append(TextSpan(String(cursorBlock), foreground: cursorFg, background: cursorBg))
                    }
                } else {
                    enum CharStyle { case normal, cursor, selected }
                    var currentStyle: CharStyle = .normal
                    var currentColor: Color = theme.plain
                    var runStart = 0

                    // Slice this chunk's token-color window out of
                    // the per-row pre-computed array (built with
                    // stateful carry up at the top of buildDisplaySpans).
                    let tokenColors: [Color]
                    if highlighter != nil, let rowColors = perRowColors[row] {
                        let lo = min(chunkColStart, rowColors.count)
                        let hi = min(chunkColStart + chunk.count, rowColors.count)
                        tokenColors = lo < hi ? Array(rowColors[lo..<hi]) : []
                    } else {
                        tokenColors = []  // no highlighter → flushRun uses default fg
                    }

                    func flushRun(upTo end: Int) {
                        guard end > runStart else { return }
                        let text = String(chunk[chunk.index(chunk.startIndex, offsetBy: runStart)..<chunk.index(chunk.startIndex, offsetBy: end)])
                        switch currentStyle {
                        case .cursor:
                            // Cursor styling overrides syntax color — the
                            // cursor cell needs to be visible against the
                            // editor's bg regardless of token kind.
                            spans.append(TextSpan(text, foreground: cursorFg, background: cursorBg, bold: true))
                        case .selected:
                            // Selection keeps its background; foreground
                            // honours syntax color so highlighted code
                            // stays readable inside a selection.
                            if highlighter != nil {
                                spans.append(TextSpan(text, foreground: currentColor, background: selectionBg))
                            } else {
                                spans.append(TextSpan(text, background: selectionBg))
                            }
                        case .normal:
                            if highlighter != nil {
                                spans.append(TextSpan(text, foreground: currentColor))
                            } else {
                                spans.append(TextSpan(text))
                            }
                        }
                    }

                    for col in 0..<chunk.count {
                        let logicalCol = chunkColStart + col
                        let atCursor = showsCursor && row == cursor.row && logicalCol == cursor.col
                        let selected = isPositionSelected(row: row, col: logicalCol, selection: selection)
                        let style: CharStyle = atCursor ? .cursor : selected ? .selected : .normal
                        let charColor: Color = tokenColors.isEmpty ? theme.plain : tokenColors[col]

                        if col == 0 {
                            currentStyle = style
                            currentColor = charColor
                        } else if style != currentStyle || charColor != currentColor {
                            flushRun(upTo: col)
                            currentStyle = style
                            currentColor = charColor
                            runStart = col
                        }
                    }
                    flushRun(upTo: chunk.count)

                    // Cursor past last character of this chunk —
                    // only when this is the LAST chunk of the
                    // logical line (otherwise cursor lives on the
                    // next chunk).
                    if showsCursor && row == cursor.row && cursor.col >= chunkColEnd
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

    /// The caret position drawn at column `x`, row `y` of the rows
    /// `buildDisplaySpans` lays out from `scrollOffset`: what a click there
    /// places the caret at. Past the end of a line it is the line's end;
    /// below the last line, the end of the last; on the gutter, the start
    /// of the line.
    static func cursor(atColumn x: Int, row y: Int, lines: [String], scrollOffset: Int,
                       lineNumbers: Bool, wrapWidth: Int) -> TextAreaCursor {
        let textStart = lineNumbers ? gutterWidth(for: lines.count) + 1 : 0
        var displayRow = 0
        for row in max(0, scrollOffset)..<lines.count {
            let line = lines[row]
            let chunks = displayChunks(of: line, wrapWidth: wrapWidth)
            if y < displayRow + chunks.count {
                let col = unprojectCursor(chunks: chunks, chunkIndex: y - displayRow,
                                          columnInChunk: max(0, x - textStart), logicalLine: line)
                return TextAreaCursor(row: row, col: col)
            }
            displayRow += chunks.count
        }
        let last = max(0, lines.count - 1)
        return TextAreaCursor(row: last, col: lines.indices.contains(last) ? lines[last].count : 0)
    }

    /// The rows `line` is drawn in: wrapped at `wrapWidth` when it is
    /// longer, whole otherwise — and whole when `wrapWidth` is 0, the 1:1
    /// rendering older callers ask for.
    static func displayChunks(of line: String, wrapWidth: Int) -> [String] {
        wrapWidth > 0 && line.count > wrapWidth ? TextLayout.wrapWords(line, width: wrapWidth) : [line]
    }

    static func gutterWidth(for totalLines: Int) -> Int {
        let digits = max(minGutterDigits, String(totalLines).count)
        return digits + gutterPadding
    }

    /// For one wrapped chunk of `line`, return the per-character
    /// foreground colors derived by tokenising the FULL logical
    /// line through `highlighter` and looking up each token's
    /// theme color. Indices map back to the chunk's local cols
    /// (`chunkColStart` is the chunk's offset in the line; the
    /// returned array has `chunkLength` entries).
    static func lineTokenColors(
        line: String,
        highlighter: any SyntaxHighlighter,
        theme: SyntaxTheme,
        chunkColStart: Int,
        chunkLength: Int
    ) -> [Color] {
        guard chunkLength > 0 else { return [] }
        var colors = Array(repeating: theme.plain, count: chunkLength)
        let spans = highlighter.tokenize(line: line)
        let chunkEnd = chunkColStart + chunkLength
        for span in spans {
            // Convert the span's String.Index range back to integer
            // offsets into `line`.
            let start = line.distance(from: line.startIndex, to: span.range.lowerBound)
            let end = line.distance(from: line.startIndex, to: span.range.upperBound)
            // Intersect with this chunk's [chunkColStart, chunkEnd).
            let lo = max(start, chunkColStart)
            let hi = min(end, chunkEnd)
            guard lo < hi else { continue }
            let color = theme.color(for: span.token)
            for c in lo..<hi {
                colors[c - chunkColStart] = color
            }
        }
        return colors
    }

    /// Build per-row token-color arrays for every row in the visible
    /// window, with multi-line carry-state threaded through. We seed
    /// `TokenizerState` by tokenising rows 0..<scrollOffset (lines
    /// above the viewport) so a `/* … */` opened above the visible
    /// area still colours its continuation rows correctly. Returns
    /// an empty dict when `highlighter` is nil — caller falls back
    /// to default fg.
    static func perRowTokenColors(
        lines: [String],
        highlighter: (any SyntaxHighlighter)?,
        theme: SyntaxTheme,
        scrollOffset: Int,
        endRow: Int
    ) -> [Int: [Color]] {
        guard let highlighter else { return [:] }
        var result: [Int: [Color]] = [:]
        // Seed state by scanning above-viewport rows, discarding
        // their spans (we only want the carry).
        var state = TokenizerState()
        let preEnd = min(scrollOffset, lines.count)
        for row in 0..<preEnd {
            _ = highlighter.tokenize(line: lines[row], state: &state)
        }
        // Tokenise visible rows and build per-row color arrays.
        let visibleEnd = min(endRow, lines.count)
        for row in scrollOffset..<visibleEnd {
            let line = lines[row]
            let spans = highlighter.tokenize(line: line, state: &state)
            var colors = Array(repeating: theme.plain, count: line.count)
            for span in spans {
                let start = line.distance(from: line.startIndex, to: span.range.lowerBound)
                let end = line.distance(from: line.startIndex, to: span.range.upperBound)
                let color = theme.color(for: span.token)
                let lo = max(0, start)
                let hi = min(line.count, end)
                guard lo < hi else { continue }
                for c in lo..<hi {
                    colors[c] = color
                }
            }
            result[row] = colors
        }
        return result
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
        textEditing: TextEditingContext = EnvironmentValues().textEditing
    ) -> KeyEventResult {
        var editorState = state.get()
        let content = text.get()
        var lines = TextLines.split(content)
        var cursor = clampCursor(editorState.cursor, lines: lines)
        let hasShift = event.modifiers.contains(.shift)

        // Capture anchor for selection before any movement
        let anchorBeforeMove = cursor

        /// Snapshot the pre-edit (text, cursor, selection) and push
        /// onto the undo stack. Called from each text-mutating key
        /// path so Ctrl+Z restores the prior state. Bounded — old
        /// snapshots dropped on overflow.
        func pushUndoSnapshot() {
            let snap = TextAreaSnapshot(
                text: content,
                cursor: editorState.cursor,
                selection: editorState.selection
            )
            editorState.undoStack.push(snap)
        }

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
            text.set(TextLines.join(lines))
            state.set(editorState)
        }

        /// What the editor does with `command`, or nil to pass it over.
        func perform(_ command: TextEditCommand) -> KeyEventResult? {
            switch command {
            case .undo:
                applyUndo(text: text, state: state, visibleHeight: visibleHeight)
                return .handled
            case .redo:
                applyRedo(text: text, state: state, visibleHeight: visibleHeight)
                return .handled
            case .moveUp:
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
                        textEditing.boundaryHit(.topEdge)
                    }
                    editorState.desiredCol = desired
                } else if cursor.row > 0 {
                    let desired = editorState.desiredCol ?? cursor.col
                    cursor.row -= 1
                    cursor.col = min(desired, lines[cursor.row].count)
                    editorState.desiredCol = desired
                } else {
                    // .logical mode at row 0 — buffer-top wall.
                    textEditing.boundaryHit(.topEdge)
                }
                commitCursorMove()
                return .handled

            case .moveDown:
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
                        textEditing.boundaryHit(.bottomEdge)
                    }
                    editorState.desiredCol = desired
                } else if cursor.row < lines.count - 1 {
                    let desired = editorState.desiredCol ?? cursor.col
                    cursor.row += 1
                    cursor.col = min(desired, lines[cursor.row].count)
                    editorState.desiredCol = desired
                } else {
                    // .logical mode at last row — buffer-bottom wall.
                    textEditing.boundaryHit(.bottomEdge)
                }
                commitCursorMove()
                return .handled

            case .pageUp, .pageDown:
                let jump = max(1, visibleHeight) * (command == .pageUp ? -1 : 1)
                cursor.row = min(lines.count - 1, max(0, cursor.row + jump))
                cursor.col = min(cursor.col, lines[cursor.row].count)
                commitCursorMove()
                return .handled
            default:
                break
            }
            guard command.isBufferCommand else { return nil }
            // With text selected, a deletion takes the selection, and a line
            // break or a yank replaces it.
            let selection = editorState.selection.flatMap { $0.isEmpty ? nil : $0 }
            if let selection, command.isDeletion {
                pushUndoSnapshot()
                deleteSelection(lines: &lines, selection: selection, cursor: &cursor)
                commitTextEdit()
                return .handled
            }
            let before = (lines: lines, cursor: cursor)
            if let selection, command == .insertNewline || command == .yank {
                deleteSelection(lines: &lines, selection: selection, cursor: &cursor)
            }
            var buffer = TextEditingBuffer(text: Array(TextLines.join(lines)),
                                           cursor: TextLines.offset(row: cursor.row, col: cursor.col, in: lines))
            let result = textEditing.perform(command, on: &buffer)
            switch result {
            case .unsupported, .unchanged:
                (lines, cursor) = before
                return nil
            case .edited:
                pushUndoSnapshot()
                lines = TextLines.split(String(buffer.text))
            case .moved, .hitWall:
                editorState.desiredCol = nil
            }
            let position = TextLines.position(of: buffer.cursor, in: lines)
            cursor = TextAreaCursor(row: position.row, col: position.col)
            if case .edited = result {
                commitTextEdit()
            } else {
                commitCursorMove()
            }
            return .handled
        }

        let commands = textEditing.keymap.commands(for: event)
        if !commands.isEmpty {
            // The first command that applies wins; each runs at most once.
            for command in commands {
                if let result = perform(command) { return result }
            }
            return .ignored
        }

        // Chords no command claims bubble to the parent.
        guard case .character(let c) = event.key,
              !event.modifiers.contains(.ctrl), !event.modifiers.contains(.alt) else {
            return .ignored
        }
        // Snapshot BEFORE mutating so Ctrl+Z restores this state.
        pushUndoSnapshot()
        if let selection = editorState.selection, !selection.isEmpty {
            deleteSelection(lines: &lines, selection: selection, cursor: &cursor)
        }
        insertCharacter(c, at: &cursor, in: &lines)
        commitTextEdit()
        return .handled
    }

    // MARK: - Text Mutation

    static func insertCharacter(_ ch: Character, at cursor: inout TextAreaCursor, in lines: inout [String]) {
        var line = lines[cursor.row]
        let idx = line.index(line.startIndex, offsetBy: min(cursor.col, line.count))
        line.insert(ch, at: idx)
        lines[cursor.row] = line
        cursor.col += 1
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

}

/// A text area's visible rows, drawn as a view of their own under the
/// editor's focusable so they can ask whether it holds focus — `isFocused`
/// reports to the content below the focusable — and draw the cursor only
/// while it does. Handed values, not the bindings, for the reason
/// `PromptRows` gives.
struct TextAreaRows: TerminalView {
    let lines: [String]
    let cursor: TextAreaCursor
    let selection: TextAreaSelection?
    let scrollOffset: Int
    let visibleHeight: Int
    let lineNumbers: Bool
    let wrapWidth: Int
    let highlighter: (any SyntaxHighlighter)?
    let theme: SyntaxTheme

    @TerminalEnvironment(\.isFocused) var isFocused
    @TerminalEnvironment(\.theme) var chrome
    @TerminalEnvironment(\.cursorFlash) var cursorFlash

    var body: some TerminalView {
        Text(spans: TextArea.buildDisplaySpans(
            lines: lines,
            cursor: cursor,
            selection: selection,
            scrollOffset: scrollOffset,
            visibleHeight: visibleHeight,
            lineNumbers: lineNumbers,
            wrapWidth: wrapWidth,
            highlighter: highlighter,
            theme: theme,
            showsCursor: isFocused,
            // Only while focused: a read is a subscription, and an unfocused
            // editor would rebuild its rows at each hit for nothing.
            cursorLit: isFocused && cursorFlash?.isLit == true,
            chrome: chrome
        ))
    }
}
