/// A chat-style multi-line input that grows with content.
/// Designed for CLI tool prompts — Claude Code, Codex, OpenCode style.
///
/// Features:
/// - Soft-wraps content at the container width; input grows downward.
/// - `❯` prompt indicator on the left, continuation rows indent to match.
/// - Visible block cursor with per-display-row projection.
/// - Enter submits; Shift+Enter / Option+Enter / Ctrl+Enter insert a newline.
///   (Shift+Enter detection requires a terminal with kitty keyboard or similar;
///    Option+Enter is the universal fallback — sent as `ESC\r`.)
/// - Up arrow from the top display row recalls history.
/// - Optional context badge on the right (project name, mode).
///
/// Usage:
/// ```
/// @TerminalState var input = ""
/// @TerminalState var promptState = PromptInputState()
///
/// PromptInput(
///     text: $input,
///     state: $promptState,
///     prompt: "❯",
///     onSubmit: { text in print("Submitted: \(text)") }
/// )
/// ```

/// Which axis arrow Up/Down navigates on.
///
/// `.display` matches editors (vim visual lines, VS Code, Claude Code):
/// one arrow step = one terminal row, so a soft-wrapped logical line splits
/// into several navigable rows. `.logical` treats each `\n`-delimited line
/// as a single step; soft-wrapped rows are skipped.
public enum PromptArrowMode: Sendable, Equatable {
    case display
    case logical
}

/// How the prompt picks its rendered height.
///
/// Default `.fixed(8)` grows with content up to 8 display rows and scrolls
/// once content exceeds the cap — matches Claude Code / Codex. Use
/// `.unbounded` when the parent layout can absorb arbitrary growth (chat
/// panel in a ScrollView). `.container` and `.containerCapped` honour the
/// container's reported height, which is only reliable when the parent
/// explicitly sizes the prompt via `.frame()`.
public enum PromptHeightPolicy: Sendable, Equatable {
    /// Fixed ceiling in display rows. Recommended for VStack layouts.
    /// Content beyond the ceiling scrolls vertically to keep the cursor
    /// visible.
    case fixed(Int)
    /// Grow with content without any cap. The prompt's height equals the
    /// wrapped display-row count. Pair with an outer `ScrollView` if the
    /// parent cannot absorb arbitrary growth.
    case unbounded
    /// Grow to the container's reported height, with no hard ceiling. Use
    /// when the parent explicitly sizes the prompt with `.frame()`.
    case container
    /// Grow up to `min(cap, container.height)`. Use inside fixed-frame
    /// parents only.
    case containerCapped(Int)
}

public struct PromptInputState: Equatable, Sendable {
    /// Cursor column within the current text (logical, counts characters
    /// left of the cursor in `lines[cursorRow]`).
    public var cursorCol: Int = 0
    /// Cursor row within the logical `\n`-split `lines` array.
    public var cursorRow: Int = 0
    /// Top visible display row (post-wrap). Unit is display rows, not
    /// logical lines, so scrolling inside a single long wrapped line works.
    public var scrollDisplayRow: Int = 0
    /// Command history — index 0 is most recent.
    public var history: [String] = []
    /// Current history navigation index (-1 = live input, 0 = most recent).
    public var historyIndex: Int = -1
    /// Text saved when entering history so arrow-down can restore it.
    public var savedInput: String = ""

    public init() {}
}

public struct PromptInput: TerminalView {
    public let text: Binding<String>
    public let state: Binding<PromptInputState>
    public let prompt: String
    public let badge: String?
    /// Legacy cap kept for source compatibility. When non-nil, overrides
    /// `heightPolicy` with `.fixed(n)` — matches the pre-HYP-84 constructor.
    public let maxVisibleLines: Int?
    public let heightPolicy: PromptHeightPolicy
    public let arrowMode: PromptArrowMode
    public let onSubmit: ((String) -> Void)?

    private static let cursorChar: Character = "\u{2588}"  // █
    private static let promptColor: Color = .cyan
    private static let cursorColor: Color = .white
    private static let textColor: Color = .default
    private static let badgeColor: Color = .ansi256(245)
    private static let badgeBgColor: Color = .ansi256(237)
    private static let dimColor: Color = .ansi256(242)

    public init(
        text: Binding<String>,
        state: Binding<PromptInputState>,
        prompt: String = "\u{276F}",
        badge: String? = nil,
        maxVisibleLines: Int? = nil,
        heightPolicy: PromptHeightPolicy = .fixed(8),
        arrowMode: PromptArrowMode = .display,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.state = state
        self.prompt = prompt
        self.badge = badge
        self.maxVisibleLines = maxVisibleLines
        self.heightPolicy = heightPolicy
        self.arrowMode = arrowMode
        self.onSubmit = onSubmit
    }

    public var body: some TerminalView {
        // Soft-wrap needs the container width; `GeometryReader` supplies it.
        // We do NOT apply `.frame(height:)` — the spans emitted by
        // `buildDisplay` already contain exactly `renderedHeight` newline-
        // separated display rows, and `Text` sizes itself from span
        // newlines (TextArea uses the same trick). Wrapping in `.frame`
        // would force VStack to give us a fixed allocation on the FIRST
        // frame and then lock that size in, because GR reports last
        // frame's height.
        GeometryReader { size in
            let contentWidth = max(1, size.width - Self.promptReservedWidth(self.prompt))
            let lines = Self.splitLines(self.text.get())
            let wraps = Self.wrapPerLine(lines: lines, width: contentWidth)
            let totalDisplayRows = wraps.reduce(0) { $0 + $1.count }
            let ceiling = Self.resolveCeiling(
                policy: self.heightPolicy,
                legacy: self.maxVisibleLines,
                containerHeight: size.height,
                contentRows: totalDisplayRows
            )
            let renderedHeight = min(max(1, ceiling), max(1, totalDisplayRows))
            let spans = self.buildDisplay(
                lines: lines,
                wraps: wraps,
                totalDisplayRows: totalDisplayRows,
                wrapWidth: contentWidth,
                visibleLines: renderedHeight
            )
            return Text(spans: spans)
                .focusable()
                .onKeyPress { [text, state, onSubmit, prompt, arrowMode] event in
                    Self.handleKey(
                        event, text: text, state: state,
                        onSubmit: onSubmit, promptWidth: prompt.count + 1,
                        maxVisibleLines: renderedHeight,
                        wrapWidth: contentWidth,
                        arrowMode: arrowMode
                    )
                }
        }
    }

    /// Cells reserved at the start of each display row for the prompt glyph
    /// and its trailing space. Wrap width for content is `container.width - this`.
    static func promptReservedWidth(_ prompt: String) -> Int {
        prompt.count + 1
    }

    /// Picks the display-row ceiling. Legacy `maxVisibleLines` wins for
    /// source compatibility, then the policy.
    private static func resolveCeiling(
        policy: PromptHeightPolicy,
        legacy: Int?,
        containerHeight: Int,
        contentRows: Int
    ) -> Int {
        if let legacy { return max(1, legacy) }
        switch policy {
        case .fixed(let n): return max(1, n)
        case .unbounded: return max(1, contentRows)
        case .container: return max(1, containerHeight > 0 ? containerHeight : 8)
        case .containerCapped(let cap):
            let container = containerHeight > 0 ? containerHeight : cap
            return max(1, min(cap, container))
        }
    }

    // MARK: - Soft wrap

    /// Splits a logical line into ≤`width`-character chunks, breaking
    /// on whitespace boundaries when possible. Words longer than
    /// `width` (URLs, identifiers) fall back to a character-level
    /// break. Empty input yields one empty chunk so the row is
    /// navigable.
    ///
    /// Word-aware wrapping mirrors how chat clients (Claude Code,
    /// Codex) lay out long input. Pre-2026-04-25 this was a simple
    /// char-stride wrap that split mid-word — visible as "righ"+"t"
    /// in the user's screenshot.
    static func wrapLine(_ line: String, width: Int) -> [String] {
        guard width > 0 else { return [line] }
        if line.isEmpty { return [""] }
        // Pure-character path for lines containing no spaces (URLs,
        // identifiers, paste-bombed tokens). Falls through to char-
        // stride; matches pre-existing behaviour for those inputs.
        if !line.contains(" ") {
            return charStrideChunks(line, width: width)
        }

        var chunks: [String] = []
        var current = ""
        var i = line.startIndex
        while i < line.endIndex {
            // Find the next break point: end of word OR end of line.
            // A "word" here is a maximal run of non-space chars; a
            // "gap" is a maximal run of spaces. Both are emitted as
            // single tokens so trailing spaces inside the line are
            // preserved across word boundaries.
            let isSpace = line[i] == " "
            var j = i
            while j < line.endIndex && (line[j] == " ") == isSpace {
                j = line.index(after: j)
            }
            let token = String(line[i..<j])
            i = j

            // Token longer than `width`: this is a long word that
            // must be hard-broken. Flush current chunk first, then
            // emit the token in width-sized slices.
            if token.count > width {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: charStrideChunks(token, width: width))
                continue
            }

            // Token fits within `width`. Append to current chunk if
            // there's room; otherwise start a new chunk.
            if current.count + token.count <= width {
                current += token
            } else {
                // Flush current and start a new chunk with the token.
                // Drop a leading space on the new chunk so wrapped
                // lines don't start with a stray space — we preserve
                // it logically but visually we want clean lefts.
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                if token.first == " " {
                    // Pure-whitespace token at chunk boundary: drop it.
                    // Reassembly tests tolerate one space lost per wrap
                    // point, matching SwiftUI's behaviour.
                    continue
                }
                current = token
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        if chunks.isEmpty {
            chunks.append("")
        }
        return chunks
    }

    /// Char-stride helper used by `wrapLine` for spaceless inputs and
    /// for slicing long words.
    private static func charStrideChunks(_ s: String, width: Int) -> [String] {
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            idx = end
        }
        return out.isEmpty ? [""] : out
    }

    /// Pre-computes wrapped chunks for every logical line. Used by both the
    /// renderer and the scroll/navigation math so they agree on display rows.
    static func wrapPerLine(lines: [String], width: Int) -> [[String]] {
        lines.map { wrapLine($0, width: width) }
    }

    /// Maps a logical cursor to its (displayRow, displayCol) in the flattened
    /// post-wrap grid. `displayRow` is summed across all preceding logical
    /// lines' chunk counts plus the wrap-index within the current line.
    /// `displayCol` is the cursor's column within that chunk.
    static func projectCursor(
        logicalRow: Int,
        logicalCol: Int,
        wraps: [[String]]
    ) -> (displayRow: Int, displayCol: Int) {
        var displayRow = 0
        for row in 0..<min(logicalRow, wraps.count) {
            displayRow += max(1, wraps[row].count)
        }
        let chunks = wraps[min(logicalRow, wraps.count - 1)]
        // `chunks[i]` covers logical columns [i*W, (i+1)*W). The cursor's
        // position inside the chunk is `logicalCol - i*W`. When the cursor
        // sits at the boundary (`logicalCol == chunkLen` and another chunk
        // follows), prefer the start of the next chunk — matches how editors
        // position a trailing cursor after a word-wrap.
        var remaining = logicalCol
        for (i, chunk) in chunks.enumerated() {
            if remaining < chunk.count {
                return (displayRow + i, remaining)
            }
            if remaining == chunk.count {
                // End of a chunk: if another chunk follows, move to its start;
                // otherwise render at the end of this chunk (cursor block
                // drawn to the right of the last character).
                if i + 1 < chunks.count {
                    return (displayRow + i + 1, 0)
                }
                return (displayRow + i, remaining)
            }
            remaining -= chunk.count
        }
        // Defensive: cursor past end — pin at end of last chunk.
        let lastIdx = max(0, chunks.count - 1)
        return (displayRow + lastIdx, chunks[lastIdx].count)
    }

    // MARK: - Display

    private func buildDisplay(
        lines: [String],
        wraps: [[String]],
        totalDisplayRows: Int,
        wrapWidth: Int,
        visibleLines: Int
    ) -> [TextSpan] {
        let st = state.get()
        let cursorRow = min(st.cursorRow, max(0, lines.count - 1))
        let cursorCol = min(st.cursorCol, lines[cursorRow].count)
        let (cursorDisplayRow, cursorDisplayCol) = Self.projectCursor(
            logicalRow: cursorRow, logicalCol: cursorCol, wraps: wraps
        )

        // Flatten (logicalRow, chunkIndex) pairs for the visible window.
        let startDisplayRow = max(0, min(st.scrollDisplayRow, max(0, totalDisplayRows - visibleLines)))
        let endDisplayRow = min(totalDisplayRows, startDisplayRow + visibleLines)

        var spans: [TextSpan] = []
        var currentDisplayRow = 0
        var emittedRows = 0

        outer: for (logicalIdx, chunks) in wraps.enumerated() {
            for (chunkIdx, chunk) in chunks.enumerated() {
                defer { currentDisplayRow += 1 }
                if currentDisplayRow < startDisplayRow { continue }
                if currentDisplayRow >= endDisplayRow { break outer }

                if emittedRows > 0 {
                    spans.append(TextSpan("\n"))
                }
                emittedRows += 1

                // Prompt on the first chunk of the first logical line,
                // dim continuation indent everywhere else.
                if logicalIdx == 0 && chunkIdx == 0 {
                    spans.append(TextSpan("\(prompt) ", foreground: Self.promptColor, bold: true))
                } else {
                    let indent = String(repeating: " ", count: prompt.count + 1)
                    spans.append(TextSpan(indent, foreground: Self.dimColor))
                }

                let isCursorRow = (currentDisplayRow == cursorDisplayRow)
                if isCursorRow {
                    // Split the chunk around the cursor column.
                    let col = min(cursorDisplayCol, chunk.count)
                    if col > 0 {
                        let before = String(chunk.prefix(col))
                        spans.append(TextSpan(before, foreground: Self.textColor))
                    }
                    if col < chunk.count {
                        let idx = chunk.index(chunk.startIndex, offsetBy: col)
                        let cursorGlyph = chunk[idx]
                        spans.append(TextSpan(
                            String(cursorGlyph),
                            foreground: Self.cursorColor,
                            background: Self.promptColor,
                            bold: true
                        ))
                        if col + 1 < chunk.count {
                            let after = String(chunk.suffix(from: chunk.index(after: idx)))
                            spans.append(TextSpan(after, foreground: Self.textColor))
                        }
                    } else {
                        // Cursor sits past the last character of this chunk —
                        // render the block glyph. `projectCursor` only lands
                        // here for the last chunk of the last logical line
                        // (otherwise it rolls to the next chunk's col 0).
                        spans.append(TextSpan(String(Self.cursorChar), foreground: Self.promptColor))
                    }
                } else {
                    spans.append(TextSpan(chunk, foreground: Self.textColor))
                }
            }
        }

        // Badge only fits cleanly on single-row empty input; otherwise the
        // render would overlap wrapped content. Wide-screen callers can use
        // an explicit HStack instead.
        if let badge, !badge.isEmpty, totalDisplayRows == 1 {
            spans.append(TextSpan("  "))
            spans.append(TextSpan(" \(badge) ", foreground: Self.badgeColor, background: Self.badgeBgColor))
        }

        return spans
    }

    // MARK: - Key Handling

    static func handleKey(
        _ event: KeyEvent,
        text: Binding<String>,
        state: Binding<PromptInputState>,
        onSubmit: ((String) -> Void)?,
        promptWidth: Int,
        maxVisibleLines: Int,
        wrapWidth: Int = .max,
        arrowMode: PromptArrowMode = .display
    ) -> KeyEventResult {
        let content = text.get()
        var st = state.get()
        var lines = splitLines(content)
        let lineCount = lines.count

        // Clamp cursor
        st.cursorRow = min(st.cursorRow, lineCount - 1)
        st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)

        switch event.key {
        // MARK: Submit (Enter) / Newline (Shift+Enter, Alt+Enter, Ctrl+Enter)
        case .enter where !event.modifiers.isEmpty:
            // Any modified Enter = insert newline (expand the input box).
            // Option+Enter is the universal fallback — Terminal.app cannot
            // distinguish Shift+Enter from plain Enter without kitty keyboard.
            let line = lines[st.cursorRow]
            let idx = line.index(line.startIndex, offsetBy: st.cursorCol)
            let before = String(line[..<idx])
            let after = String(line[idx...])
            lines[st.cursorRow] = before
            lines.insert(after, at: st.cursorRow + 1)
            st.cursorRow += 1
            st.cursorCol = 0
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .enter:
            // Plain Enter = submit
            let submitted = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !submitted.isEmpty {
                st.history.insert(submitted, at: 0)
                st.historyIndex = -1
                st.savedInput = ""
                onSubmit?(submitted)
                text.set("")
                st.cursorRow = 0
                st.cursorCol = 0
                st.scrollDisplayRow = 0
            }
            state.set(st)
            return .handled

        // MARK: Character input
        case .character(let c):
            guard !event.modifiers.contains(.ctrl) && !event.modifiers.contains(.alt) else {
                return .ignored
            }
            let line = lines[st.cursorRow]
            let idx = line.index(line.startIndex, offsetBy: st.cursorCol)
            lines[st.cursorRow] = String(line[..<idx]) + String(c) + String(line[idx...])
            st.cursorCol += 1
            st.historyIndex = -1
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        // MARK: Backspace
        case .backspace:
            if st.cursorCol > 0 {
                let line = lines[st.cursorRow]
                let delIdx = line.index(line.startIndex, offsetBy: st.cursorCol - 1)
                let endIdx = line.index(line.startIndex, offsetBy: st.cursorCol)
                lines[st.cursorRow] = String(line[..<delIdx]) + String(line[endIdx...])
                st.cursorCol -= 1
            } else if st.cursorRow > 0 {
                // Merge with previous line
                let prevLen = lines[st.cursorRow - 1].count
                lines[st.cursorRow - 1] += lines[st.cursorRow]
                lines.remove(at: st.cursorRow)
                st.cursorRow -= 1
                st.cursorCol = prevLen
            }
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        // MARK: Delete
        case .delete:
            let line = lines[st.cursorRow]
            if st.cursorCol < line.count {
                let delIdx = line.index(line.startIndex, offsetBy: st.cursorCol)
                let endIdx = line.index(after: delIdx)
                lines[st.cursorRow] = String(line[..<delIdx]) + String(line[endIdx...])
            } else if st.cursorRow < lineCount - 1 {
                lines[st.cursorRow] += lines[st.cursorRow + 1]
                lines.remove(at: st.cursorRow + 1)
            }
            text.set(lines.joined(separator: "\n"))
            state.set(st)
            return .handled

        // MARK: Cursor movement
        case .left:
            if st.cursorCol > 0 {
                st.cursorCol -= 1
            } else if st.cursorRow > 0 {
                st.cursorRow -= 1
                st.cursorCol = lines[st.cursorRow].count
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .right:
            let lineLen = lines[st.cursorRow].count
            if st.cursorCol < lineLen {
                st.cursorCol += 1
            } else if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                st.cursorCol = 0
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .up:
            let moved = moveCursorUp(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode)
            if !moved {
                // At the visual top of the current input → recall history.
                if !st.history.isEmpty {
                    if st.historyIndex == -1 {
                        st.savedInput = text.get()
                    }
                    let nextIdx = min(st.historyIndex + 1, st.history.count - 1)
                    if nextIdx != st.historyIndex {
                        st.historyIndex = nextIdx
                        text.set(st.history[nextIdx])
                        let newLines = splitLines(st.history[nextIdx])
                        st.cursorRow = newLines.count - 1
                        st.cursorCol = newLines.last?.count ?? 0
                    }
                }
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .down:
            let moved = moveCursorDown(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode)
            if !moved && st.historyIndex >= 0 {
                st.historyIndex -= 1
                if st.historyIndex < 0 {
                    text.set(st.savedInput)
                    let newLines = splitLines(st.savedInput)
                    st.cursorRow = newLines.count - 1
                    st.cursorCol = newLines.last?.count ?? 0
                } else {
                    text.set(st.history[st.historyIndex])
                    let newLines = splitLines(st.history[st.historyIndex])
                    st.cursorRow = newLines.count - 1
                    st.cursorCol = newLines.last?.count ?? 0
                }
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .home:
            st.cursorCol = 0
            state.set(st)
            return .handled

        case .end:
            st.cursorCol = lines[st.cursorRow].count
            state.set(st)
            return .handled

        default:
            return .ignored
        }
    }

    // MARK: - Helpers

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Moves the cursor up one step under the selected arrow mode. Returns
    /// false if it could not move (already at top) so the caller can fall
    /// through to history recall.
    private static func moveCursorUp(
        _ st: inout PromptInputState,
        lines: [String],
        wrapWidth: Int,
        arrowMode: PromptArrowMode
    ) -> Bool {
        switch arrowMode {
        case .logical:
            if st.cursorRow > 0 {
                st.cursorRow -= 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                return true
            }
            return false
        case .display:
            guard wrapWidth > 0, wrapWidth != .max else {
                // No wrap info → fall back to logical.
                if st.cursorRow > 0 {
                    st.cursorRow -= 1
                    st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                    return true
                }
                return false
            }
            // Inside a soft-wrapped logical line: step back by `wrapWidth`.
            if st.cursorCol >= wrapWidth {
                st.cursorCol -= wrapWidth
                return true
            }
            // At the top display row of this logical line → jump to the
            // bottom display row of the previous logical line, preserving
            // the desired column as closely as possible.
            if st.cursorRow > 0 {
                st.cursorRow -= 1
                let prevLine = lines[st.cursorRow]
                let prevLen = prevLine.count
                let lastChunkStart = (prevLen / wrapWidth) * wrapWidth
                // If prevLen is an exact multiple of wrapWidth, `lastChunkStart`
                // lands on the empty trailing chunk; back up one row.
                let adjustedStart: Int
                if prevLen > 0 && prevLen % wrapWidth == 0 {
                    adjustedStart = prevLen - wrapWidth
                } else {
                    adjustedStart = lastChunkStart
                }
                let desiredCol = st.cursorCol  // carry column intent
                let chunkLen = prevLen - adjustedStart
                st.cursorCol = min(adjustedStart + desiredCol, adjustedStart + chunkLen)
                return true
            }
            return false
        }
    }

    private static func moveCursorDown(
        _ st: inout PromptInputState,
        lines: [String],
        wrapWidth: Int,
        arrowMode: PromptArrowMode
    ) -> Bool {
        let lineCount = lines.count
        switch arrowMode {
        case .logical:
            if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                return true
            }
            return false
        case .display:
            guard wrapWidth > 0, wrapWidth != .max else {
                if st.cursorRow < lineCount - 1 {
                    st.cursorRow += 1
                    st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                    return true
                }
                return false
            }
            let line = lines[st.cursorRow]
            let remainingInLine = line.count - st.cursorCol
            if remainingInLine >= wrapWidth {
                // Another wrapped chunk exists in this logical line.
                st.cursorCol += wrapWidth
                return true
            }
            // Bottom chunk of current line → jump to first chunk of next line.
            if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                let colInChunk = st.cursorCol % wrapWidth
                st.cursorCol = min(colInChunk, lines[st.cursorRow].count)
                return true
            }
            return false
        }
    }

    /// Scrolls so the cursor's display row is visible. Works on DISPLAY rows
    /// throughout: a single long soft-wrapped line scrolls row-by-row, a
    /// short line with lots of `\n`s still scrolls correctly.
    private static func adjustScroll(
        _ st: inout PromptInputState,
        maxVisibleLines: Int,
        wrapWidth: Int,
        lines: [String]
    ) {
        let wraps: [[String]]
        if wrapWidth <= 0 || wrapWidth == .max {
            wraps = lines.map { [$0] }
        } else {
            wraps = wrapPerLine(lines: lines, width: wrapWidth)
        }
        let (cursorDisplayRow, _) = projectCursor(
            logicalRow: min(st.cursorRow, max(0, lines.count - 1)),
            logicalCol: min(st.cursorCol, lines[min(st.cursorRow, max(0, lines.count - 1))].count),
            wraps: wraps
        )
        let totalDisplayRows = wraps.reduce(0) { $0 + $1.count }
        let maxScroll = max(0, totalDisplayRows - maxVisibleLines)

        if cursorDisplayRow < st.scrollDisplayRow {
            st.scrollDisplayRow = cursorDisplayRow
        } else if cursorDisplayRow >= st.scrollDisplayRow + maxVisibleLines {
            st.scrollDisplayRow = cursorDisplayRow - maxVisibleLines + 1
        }
        st.scrollDisplayRow = max(0, min(st.scrollDisplayRow, maxScroll))
    }
}
