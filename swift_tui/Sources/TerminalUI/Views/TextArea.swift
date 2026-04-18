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
public struct TextArea: TerminalView {
    public let text: Binding<String>
    public let state: Binding<TextAreaState>
    public let lineNumbers: Bool
    /// Explicit visible height in rows. `nil` (default) fits to container.
    /// Old int-default (10) preserved as the fallback when no container
    /// height is known.
    public let visibleHeight: Int?

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
        visibleHeight: Int? = nil
    ) {
        self.text = text
        self.state = state
        self.lineNumbers = lineNumbers
        self.visibleHeight = visibleHeight
    }

    // MARK: - Body

    public var body: some TerminalView {
        GeometryReader { size in
            self.renderEditor(containerHeight: size.height)
        }
    }

    /// Resolve visible height: caller-supplied > container > 10-fallback.
    private func effectiveVisibleHeight(containerHeight: Int) -> Int {
        if let explicit = visibleHeight { return max(1, explicit) }
        if containerHeight > 0 { return containerHeight }
        return 10
    }

    private func renderEditor(containerHeight: Int) -> some TerminalView {
        let visibleHeight = effectiveVisibleHeight(containerHeight: containerHeight)
        let content = text.get()
        let editorState = state.get()
        let lines = Self.splitLines(content)
        let cursor = Self.clampCursor(editorState.cursor, lines: lines)
        let scrollOffset = Self.clampScroll(
            cursor: cursor,
            currentScroll: editorState.scrollOffset,
            visibleHeight: visibleHeight
        )
        let displaySpans = Self.buildDisplaySpans(
            lines: lines,
            cursor: cursor,
            selection: editorState.selection,
            scrollOffset: scrollOffset,
            visibleHeight: visibleHeight,
            lineNumbers: lineNumbers
        )
        return Text(spans: displaySpans)
            .focusable()
            .onKeyPress { [text, state] event in
                Self.handleKey(event, text: text, state: state, visibleHeight: visibleHeight)
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

    // MARK: - Display Span Building

    static func buildDisplaySpans(
        lines: [String],
        cursor: TextAreaCursor,
        selection: TextAreaSelection?,
        scrollOffset: Int,
        visibleHeight: Int,
        lineNumbers: Bool
    ) -> [TextSpan] {
        var spans: [TextSpan] = []
        let totalLines = lines.count
        let gutter = lineNumbers ? gutterWidth(for: totalLines) : 0
        let endRow = min(scrollOffset + visibleHeight, totalLines)

        for row in scrollOffset..<endRow {
            let line = lines[row]

            // Line number gutter
            if lineNumbers {
                let num = String(row + 1)
                let pad = String(repeating: " ", count: max(0, gutter - gutterPadding - num.count))
                spans.append(TextSpan(pad + num + " \u{2502} ", foreground: lineNumberFg))
            }

            // Render line content — batch consecutive characters with same style
            if line.isEmpty {
                if row == cursor.row {
                    spans.append(TextSpan(String(cursorBlock), foreground: cursorFg, background: cursorBg))
                }
            } else {
                enum CharStyle { case normal, cursor, selected }
                var currentStyle: CharStyle = .normal
                var runStart = 0

                func flushRun(upTo end: Int) {
                    guard end > runStart else { return }
                    let text = String(line[line.index(line.startIndex, offsetBy: runStart)..<line.index(line.startIndex, offsetBy: end)])
                    switch currentStyle {
                    case .cursor:
                        spans.append(TextSpan(text, foreground: cursorFg, background: cursorBg, bold: true))
                    case .selected:
                        spans.append(TextSpan(text, background: selectionBg))
                    case .normal:
                        spans.append(TextSpan(text))
                    }
                }

                for col in 0..<line.count {
                    let atCursor = row == cursor.row && col == cursor.col
                    let selected = isPositionSelected(row: row, col: col, selection: selection)
                    let style: CharStyle = atCursor ? .cursor : selected ? .selected : .normal

                    if col == 0 {
                        currentStyle = style
                    } else if style != currentStyle {
                        flushRun(upTo: col)
                        currentStyle = style
                        runStart = col
                    }
                }
                flushRun(upTo: line.count)

                // Cursor past last character (end of line position)
                if row == cursor.row && cursor.col >= line.count {
                    spans.append(TextSpan(String(cursorBlock), foreground: cursorFg, background: cursorBg))
                }
            }

            // Newline between visible rows
            if row < endRow - 1 {
                spans.append(TextSpan("\n"))
            }
        }

        // Fill empty rows below content with tilde markers.
        //
        // Alignment contract: the ▏ gutter separator must land in the SAME
        // column on every row. Real rows emit `<pad><num> │ ` where
        // `pad.count = gutter - gutterPadding - num.count`. For an empty
        // row the glyph is `~` (1 char) so pad must be `gutter - gutterPadding - 1`.
        let renderedRows = endRow - scrollOffset
        if renderedRows < visibleHeight {
            for _ in 0..<(visibleHeight - renderedRows) {
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
        visibleHeight: Int
    ) -> KeyEventResult {
        var editorState = state.get()
        let content = text.get()
        var lines = splitLines(content)
        var cursor = clampCursor(editorState.cursor, lines: lines)
        let hasShift = event.modifiers.contains(.shift)
        let hasCtrl = event.modifiers.contains(.ctrl)

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
            }
            editorState.desiredCol = nil
            commitCursorMove()
            return .handled

        // MARK: Arrow Up

        case .up:
            if cursor.row > 0 {
                let desired = editorState.desiredCol ?? cursor.col
                cursor.row -= 1
                cursor.col = min(desired, lines[cursor.row].count)
                editorState.desiredCol = desired
            }
            commitCursorMove()
            return .handled

        // MARK: Arrow Down

        case .down:
            if cursor.row < lines.count - 1 {
                let desired = editorState.desiredCol ?? cursor.col
                cursor.row += 1
                cursor.col = min(desired, lines[cursor.row].count)
                editorState.desiredCol = desired
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
