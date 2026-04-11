/// A chat-style multi-line input that grows with content.
/// Designed for CLI tool prompts — Claude Code, Codex, OpenCode style.
///
/// Features:
/// - Full-width, multi-line with word wrapping
/// - `>` prompt indicator on the left
/// - Visible block cursor
/// - Enter submits, Shift+Enter inserts newline
/// - Up arrow recalls previous prompts (history)
/// - Optional context badge on the right (project name, mode)
/// - Grows vertically as content expands
///
/// Usage:
/// ```
/// @TerminalState var input = ""
/// @TerminalState var promptState = PromptInputState()
///
/// PromptInput(
///     text: $input,
///     state: $promptState,
///     prompt: ">",
///     onSubmit: { text in print("Submitted: \(text)") }
/// )
/// ```
public struct PromptInputState: Equatable, Sendable {
    /// Cursor column within the current text
    public var cursorCol: Int = 0
    /// Cursor row (for multi-line input)
    public var cursorRow: Int = 0
    /// Scroll offset for long text
    public var scrollRow: Int = 0
    /// Command history
    public var history: [String] = []
    /// Current history navigation index (-1 = current input, 0 = most recent)
    public var historyIndex: Int = -1
    /// Text saved when navigating history (so we can return to it)
    public var savedInput: String = ""

    public init() {}
}

public struct PromptInput: TerminalView {
    public let text: Binding<String>
    public let state: Binding<PromptInputState>
    public let prompt: String
    public let badge: String?
    public let maxVisibleLines: Int
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
        maxVisibleLines: Int = 8,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.state = state
        self.prompt = prompt
        self.badge = badge
        self.maxVisibleLines = maxVisibleLines
        self.onSubmit = onSubmit
    }

    public var body: some TerminalView {
        let spans = buildDisplay()
        Text(spans: spans)
            .focusable()
            .onKeyPress { [text, state, onSubmit, prompt, maxVisibleLines] event in
                Self.handleKey(
                    event, text: text, state: state,
                    onSubmit: onSubmit, promptWidth: prompt.count + 1,
                    maxVisibleLines: maxVisibleLines
                )
            }
    }

    // MARK: - Display

    private func buildDisplay() -> [TextSpan] {
        let content = text.get()
        let st = state.get()
        let lines = Self.splitLines(content)
        let cursorRow = min(st.cursorRow, lines.count - 1)
        let cursorCol = min(st.cursorCol, lines[cursorRow].count)

        var spans: [TextSpan] = []

        // Badge on the right of the first line (if provided)
        // We'll render it after the prompt line

        let lineCount = lines.count
        let startRow = max(0, min(st.scrollRow, lineCount - maxVisibleLines))
        let endRow = min(lineCount, startRow + maxVisibleLines)

        for row in startRow..<endRow {
            if row > startRow {
                spans.append(TextSpan("\n"))
            }

            let line = lines[row]

            // Prompt indicator on first visible line, continuation indent on others
            if row == 0 {
                spans.append(TextSpan("\(prompt) ", foreground: Self.promptColor, bold: true))
            } else {
                // Indent continuation lines to align with text after prompt
                let indent = String(repeating: " ", count: prompt.count + 1)
                spans.append(TextSpan(indent, foreground: Self.dimColor))
            }

            // Render line content with cursor
            if row == cursorRow {
                // Before cursor
                if cursorCol > 0 {
                    let before = String(line.prefix(cursorCol))
                    spans.append(TextSpan(before, foreground: Self.textColor))
                }
                // Cursor
                if cursorCol < line.count {
                    let cursorChar = line[line.index(line.startIndex, offsetBy: cursorCol)]
                    spans.append(TextSpan(String(cursorChar), foreground: Self.cursorColor, background: Self.promptColor, bold: true))
                    // After cursor
                    if cursorCol + 1 < line.count {
                        let after = String(line.suffix(from: line.index(line.startIndex, offsetBy: cursorCol + 1)))
                        spans.append(TextSpan(after, foreground: Self.textColor))
                    }
                } else {
                    // Cursor at end of line
                    spans.append(TextSpan(String(Self.cursorChar), foreground: Self.promptColor))
                }
            } else {
                spans.append(TextSpan(line, foreground: Self.textColor))
            }
        }

        // Badge on the right side (rendered as a separate span on the first line)
        if let badge, !badge.isEmpty {
            // Add badge info — we put it on the first line's right side
            // For simplicity, add it as a note after all content
            if lines.count <= 1 {
                spans.append(TextSpan("  "))
                spans.append(TextSpan(" \(badge) ", foreground: Self.badgeColor, background: Self.badgeBgColor))
            }
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
        maxVisibleLines: Int
    ) -> KeyEventResult {
        let content = text.get()
        var st = state.get()
        var lines = splitLines(content)
        let lineCount = lines.count

        // Clamp cursor
        st.cursorRow = min(st.cursorRow, lineCount - 1)
        st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)

        switch event.key {
        // MARK: Submit (Enter) / Newline (Shift+Enter)
        case .enter:
            if event.modifiers.contains(.shift) {
                // Insert newline
                let line = lines[st.cursorRow]
                let idx = line.index(line.startIndex, offsetBy: st.cursorCol)
                let before = String(line[..<idx])
                let after = String(line[idx...])
                lines[st.cursorRow] = before
                lines.insert(after, at: st.cursorRow + 1)
                st.cursorRow += 1
                st.cursorCol = 0
                text.set(lines.joined(separator: "\n"))
                adjustScroll(&st, maxVisibleLines: maxVisibleLines)
                state.set(st)
                return .handled
            } else {
                // Submit
                let submitted = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !submitted.isEmpty {
                    st.history.insert(submitted, at: 0)
                    st.historyIndex = -1
                    st.savedInput = ""
                    state.set(st)
                    onSubmit?(submitted)
                    text.set("")
                    st.cursorRow = 0
                    st.cursorCol = 0
                    st.scrollRow = 0
                    state.set(st)
                }
                return .handled
            }

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
            adjustScroll(&st, maxVisibleLines: maxVisibleLines)
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
            adjustScroll(&st, maxVisibleLines: maxVisibleLines)
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
            adjustScroll(&st, maxVisibleLines: maxVisibleLines)
            state.set(st)
            return .handled

        case .up:
            if st.cursorRow > 0 {
                st.cursorRow -= 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
            } else if !st.history.isEmpty {
                // Navigate history
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
            adjustScroll(&st, maxVisibleLines: maxVisibleLines)
            state.set(st)
            return .handled

        case .down:
            if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
            } else if st.historyIndex >= 0 {
                // Navigate history back
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
            adjustScroll(&st, maxVisibleLines: maxVisibleLines)
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

    private static func adjustScroll(_ st: inout PromptInputState, maxVisibleLines: Int) {
        if st.cursorRow < st.scrollRow {
            st.scrollRow = st.cursorRow
        } else if st.cursorRow >= st.scrollRow + maxVisibleLines {
            st.scrollRow = st.cursorRow - maxVisibleLines + 1
        }
    }
}
