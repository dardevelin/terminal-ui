/// A GitHub PR review-style hunk diff viewer with visual selection,
/// keyboard navigation, and locked ranges for inline review comments.
///
/// Usage:
/// ```
/// HunkDiffView(
///     hunks: hunks,
///     fileName: "src/auth/handler.swift",
///     onLineSelect: { lineIndex in print("selected \(lineIndex)") },
///     onRangeSelect: { start, end in print("range \(start)...\(end)") }
/// )
///
/// // With locked range (for committed review comments)
/// HunkDiffView(
///     hunks: hunks,
///     fileName: "handler.swift",
///     lockedRange: (5, 12)
/// )
/// ```

// MARK: - HunkDiff namespace

/// Namespace for hunk diff data types, avoiding collision with DiffView's DiffLine.
public enum HunkDiff {

    /// The type of a diff line within a hunk.
    public enum LineType: Sendable {
        case add
        case remove
        case context
    }

    /// A single line within a diff hunk.
    public struct Line: Sendable {
        public let type: LineType
        public let content: String
        public let oldLineNo: Int?
        public let newLineNo: Int?

        public init(type: LineType, content: String, oldLineNo: Int? = nil, newLineNo: Int? = nil) {
            self.type = type
            self.content = content
            self.oldLineNo = oldLineNo
            self.newLineNo = newLineNo
        }
    }

    /// A hunk of contiguous diff lines, as produced by `git diff`.
    public struct Hunk: Sendable {
        public let oldStart: Int
        public let newStart: Int
        public let lines: [Line]

        public init(oldStart: Int, newStart: Int, lines: [Line]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }

        /// Count of lines present in the old file (context + remove).
        public var oldCount: Int {
            lines.filter { $0.type != .add }.count
        }

        /// Count of lines present in the new file (context + add).
        public var newCount: Int {
            lines.filter { $0.type != .remove }.count
        }
    }

    /// Map a global line index range to the actual source line numbers from the hunk data.
    /// Returns (startLine, endLine) using new line numbers when available, falling back to old.
    public static func resolveLineNumbers(
        hunks: [Hunk],
        globalStart: Int,
        globalEnd: Int
    ) -> (Int, Int) {
        var idx = 0
        var startLine = globalStart
        var endLine = globalEnd
        for hunk in hunks {
            for line in hunk.lines {
                if idx == globalStart {
                    startLine = line.newLineNo ?? line.oldLineNo ?? globalStart
                }
                if idx == globalEnd {
                    endLine = line.newLineNo ?? line.oldLineNo ?? globalEnd
                }
                idx += 1
            }
        }
        return (startLine, endLine)
    }
}

// MARK: - HunkDiffView

/// A hunk-based diff viewer with cursor navigation, visual selection mode,
/// and locked ranges — modeled after GitHub PR review inline diff panels.
public struct HunkDiffView: TerminalView {
    public let hunks: [HunkDiff.Hunk]
    public let fileName: String
    public let lockedRange: (Int, Int)?
    public let visibleCount: Int
    private let onLineSelect: ((Int) -> Void)?
    private let onRangeSelect: ((Int, Int) -> Void)?

    @TerminalState private var cursor: Int = 0
    @TerminalState private var visualMode: Bool = false
    @TerminalState private var visualAnchor: Int = 0
    @TerminalState private var scrollOffset: Int = 0

    public init(
        hunks: [HunkDiff.Hunk],
        fileName: String,
        lockedRange: (Int, Int)? = nil,
        visibleCount: Int = 40,
        onLineSelect: ((Int) -> Void)? = nil,
        onRangeSelect: ((Int, Int) -> Void)? = nil
    ) {
        self.hunks = hunks
        self.fileName = fileName
        self.lockedRange = lockedRange
        self.visibleCount = visibleCount
        self.onLineSelect = onLineSelect
        self.onRangeSelect = onRangeSelect
    }

    public var body: some TerminalView {
        let totalLines = hunks.reduce(0) { $0 + $1.lines.count }
        let cursorBinding = $cursor
        let visualModeBinding = $visualMode
        let visualAnchorBinding = $visualAnchor
        let scrollBinding = $scrollOffset

        // Compute selection range from visual mode
        let selectionRange: (Int, Int)? = visualMode
            ? (min(visualAnchor, cursor), max(visualAnchor, cursor))
            : nil

        // Build all display rows: hunk headers + content lines
        let rows = buildRows(
            scroll: scrollOffset,
            cursor: cursor,
            selectionRange: selectionRange
        )

        VStack {
            // File name header
            Text(spans: renderFileHeader())

            // Diff content
            Text(spans: rows)
        }
        .focusable()
        .onKeyPress { [cursorBinding, visualModeBinding, visualAnchorBinding, scrollBinding, onLineSelect, onRangeSelect, visibleCount, totalLines] event in
            guard totalLines > 0 else { return .ignored }

            let cur = cursorBinding.get()
            let isVisual = visualModeBinding.get()

            func moveCursor(to next: Int) {
                cursorBinding.set(next)
                // Adjust scroll to keep cursor visible
                let scroll = scrollBinding.get()
                if next < scroll {
                    scrollBinding.set(next)
                } else if next >= scroll + visibleCount {
                    scrollBinding.set(next - visibleCount + 1)
                }
                if !isVisual {
                    onLineSelect?(next)
                } else {
                    let anchor = visualAnchorBinding.get()
                    onRangeSelect?(min(anchor, next), max(anchor, next))
                }
            }

            switch event.key {
            case .character("j"), .down:
                moveCursor(to: min(totalLines - 1, cur + 1))
                return .handled

            case .character("k"), .up:
                moveCursor(to: max(0, cur - 1))
                return .handled

            case .character("v"):
                if isVisual {
                    let anchor = visualAnchorBinding.get()
                    onRangeSelect?(min(anchor, cur), max(anchor, cur))
                    visualModeBinding.set(false)
                } else {
                    visualAnchorBinding.set(cur)
                    visualModeBinding.set(true)
                }
                return .handled

            case .escape:
                if isVisual {
                    visualModeBinding.set(false)
                    return .handled
                }
                return .ignored

            case .pageDown:
                moveCursor(to: min(totalLines - 1, cur + visibleCount))
                return .handled

            case .pageUp:
                moveCursor(to: max(0, cur - visibleCount))
                return .handled

            case .home:
                moveCursor(to: 0)
                return .handled

            case .end:
                moveCursor(to: max(0, totalLines - 1))
                return .handled

            default:
                return .ignored
            }
        }
    }

    // MARK: - File Header

    private func renderFileHeader() -> [TextSpan] {
        var spans: [TextSpan] = []
        spans.append(TextSpan(fileName, foreground: .white, bold: true))
        if visualMode {
            spans.append(TextSpan(" [VISUAL]", foreground: .cyan))
        }
        return spans
    }

    // MARK: - Row Building

    /// Build the visible portion of the diff as TextSpan array.
    /// Includes hunk headers (purple @@ lines) interleaved with content lines.
    private func buildRows(
        scroll: Int,
        cursor: Int,
        selectionRange: (Int, Int)?
    ) -> [TextSpan] {
        // First, build all display rows (headers + lines) with global line indices
        var allRows: [RowData] = []
        var globalIndex = 0

        for hunk in hunks {
            // Hunk header row
            allRows.append(.hunkHeader(hunk))

            // Content lines
            for line in hunk.lines {
                allRows.append(.line(line, globalIndex: globalIndex))
                globalIndex += 1
            }
        }

        // Apply scroll window
        let visibleRows = allRows.dropFirst(scroll).prefix(visibleCount)

        // Render each row
        var spans: [TextSpan] = []
        var isFirst = true

        for row in visibleRows {
            if !isFirst {
                spans.append(TextSpan("\n"))
            }
            isFirst = false

            switch row {
            case .hunkHeader(let hunk):
                spans.append(contentsOf: renderHunkHeader(hunk))

            case .line(let line, let globalIdx):
                let isCursor = globalIdx == cursor
                let inSelection = isInRange(globalIdx, selectionRange: selectionRange)
                let locked = isLocked(globalIdx)

                spans.append(contentsOf: renderLine(
                    line,
                    isCursor: isCursor,
                    inSelection: inSelection,
                    isLocked: locked
                ))
            }
        }

        if spans.isEmpty {
            return [TextSpan("(no hunks)")]
        }

        return spans
    }

    /// Intermediate representation for display rows.
    private enum RowData {
        case hunkHeader(HunkDiff.Hunk)
        case line(HunkDiff.Line, globalIndex: Int)
    }

    // MARK: - Hunk Header

    private func renderHunkHeader(_ hunk: HunkDiff.Hunk) -> [TextSpan] {
        let header = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        return [TextSpan(header, foreground: .magenta)]
    }

    // MARK: - Line Rendering

    private func renderLine(
        _ line: HunkDiff.Line,
        isCursor: Bool,
        inSelection: Bool,
        isLocked: Bool
    ) -> [TextSpan] {
        var spans: [TextSpan] = []

        // Selection gutter (2 chars)
        let gutterColor: Color = isLocked ? .yellow : .cyan
        let gutterText: String
        if isLocked {
            gutterText = "\u{2503} "  // ┃ (locked indicator)
        } else if inSelection && visualMode {
            gutterText = "\u{2503} "  // ┃ (visual selection bar)
        } else if isCursor {
            gutterText = "\u{25B8} "  // ▸ (cursor)
        } else {
            gutterText = "  "
        }
        spans.append(TextSpan(gutterText, foreground: gutterColor))

        // Old line number (3 chars + 1 space = 4 chars)
        let oldNum: String
        if line.type != .add, let n = line.oldLineNo {
            oldNum = padLeft(n, width: 3)
        } else {
            oldNum = "   "
        }
        spans.append(TextSpan(oldNum + " ", foreground: .gray))

        // New line number (3 chars + 1 space = 4 chars)
        let newNum: String
        if line.type != .remove, let n = line.newLineNo {
            newNum = padLeft(n, width: 3)
        } else {
            newNum = "   "
        }
        spans.append(TextSpan(newNum + " ", foreground: .gray))

        // Line prefix and content
        let prefix: String
        let contentColor: Color

        switch line.type {
        case .add:
            prefix = "+"
            contentColor = inSelection ? .white : .green
        case .remove:
            prefix = "-"
            contentColor = inSelection ? .white : .red
        case .context:
            prefix = " "
            contentColor = inSelection ? .white : .gray
        }

        spans.append(TextSpan(prefix + line.content, foreground: contentColor))

        return spans
    }

    // MARK: - Range Checks

    private func isInRange(_ idx: Int, selectionRange: (Int, Int)?) -> Bool {
        if let range = selectionRange {
            return idx >= range.0 && idx <= range.1
        }
        if let locked = lockedRange {
            return idx >= locked.0 && idx <= locked.1
        }
        return idx == cursor
    }

    private func isLocked(_ idx: Int) -> Bool {
        guard let locked = lockedRange else { return false }
        return idx >= locked.0 && idx <= locked.1
    }

    // MARK: - Scroll Adjustment

    /// Keep cursor visible within the scroll window.
    /// Only moves the window when cursor goes outside it.
    private func adjustScroll(scrollOffset: Int, cursor: Int, totalLines: Int) -> Int {
        // Total display rows = hunk headers + content lines
        let hunkHeaderCount = hunks.count
        let totalRows = totalLines + hunkHeaderCount

        guard totalRows > visibleCount else { return 0 }

        // Map cursor (global line index) to its display row position
        let cursorRow = cursorDisplayRow(cursor)

        var offset = scrollOffset

        // Cursor below visible window
        if cursorRow >= offset + visibleCount {
            offset = cursorRow - visibleCount + 1
        }

        // Cursor above visible window
        if cursorRow < offset {
            offset = cursorRow
        }

        // Clamp
        let maxOffset = max(0, totalRows - visibleCount)
        offset = max(0, min(maxOffset, offset))
        return offset
    }

    /// Convert a global line index to its position in the display row list
    /// (accounting for hunk headers inserted before each hunk's lines).
    private func cursorDisplayRow(_ globalIndex: Int) -> Int {
        var row = 0
        var lineIdx = 0
        for hunk in hunks {
            row += 1  // hunk header
            for _ in hunk.lines {
                if lineIdx == globalIndex {
                    return row
                }
                row += 1
                lineIdx += 1
            }
        }
        return row
    }

    // MARK: - Helpers

    /// Right-align an integer to the given width.
    private func padLeft(_ value: Int, width: Int) -> String {
        let s = String(value)
        let padding = max(0, width - s.count)
        return String(repeating: " ", count: padding) + s
    }
}
