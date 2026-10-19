import TerminalUI

// MARK: - Sidebar

/// Right rail: identity, then session, model, and what the session touches.
/// Laid out the way Crush's is — a fixed wordmark over one quiet column, each
/// part separated by a blank row rather than boxed.
struct Sidebar: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    /// Crush's sidebar width.
    static let width = 32

    var body: some TerminalView {
        VStack(spacing: 1) {
            Wordmark(width: Self.width, theme: theme)
            Text(state.sessionTitle)
                .foreground(theme.foregroundMuted)
            Text(state.workingDirectory)
                .foreground(theme.foregroundMuted)
                .wrap(.truncate(.head))
            modelBlock
            filesBlock
            resourceBlock("LSPs", kind: .lsp)
            resourceBlock("MCPs", kind: .mcp)
            Spacer()
        }
    }

    private var modelBlock: some TerminalView {
        VStack(spacing: 0) {
            Text(spans: [
                TextSpan(Glyph.diamond, foreground: theme.primary),
                TextSpan(" \(state.modelName)", foreground: theme.foregroundSubtle),
                TextSpan(" via \(state.providerName)", foreground: theme.foregroundFaint),
            ])
            // Indented under the model name, as Crush sets its usage line.
            Text(spans: [
                TextSpan("  \(state.contextPercent)%", foreground: theme.foregroundMuted),
                TextSpan(" (\(state.contextLabel))", foreground: theme.foregroundFaint),
                TextSpan("  $\(String(format: "%.2f", state.cost))", foreground: theme.foregroundMuted),
            ])
        }
    }

    private var filesBlock: some TerminalView {
        VStack(spacing: 0) {
            SectionRule(title: "Modified Files", trailing: "\(state.files.count)", theme: theme)
            ForEach(state.files) { file in
                // Head truncation: the basename is what identifies the file,
                // so the directory prefix is the part that gives way.
                Text(spans: [
                    TextSpan(file.path, foreground: theme.foregroundMuted),
                    TextSpan("  +\(file.added)", foreground: theme.success),
                    TextSpan(" −\(file.removed)", foreground: theme.error),
                ])
                .wrap(.truncate(.head))
            }
        }
    }

    private func resourceBlock(_ title: String, kind: Resource.Kind) -> some TerminalView {
        let resources = state.resources.filter { $0.kind == kind }
        return VStack(spacing: 0) {
            SectionRule(title: title, trailing: "\(resources.count)", theme: theme)
            ForEach(resources) { resource in
                let badge = resource.health.icon(theme)
                StatusRow(
                    icon: badge.glyph,
                    iconColor: badge.color,
                    name: resource.name,
                    detail: resource.detail,
                    theme: theme
                )
            }
        }
    }
}

// MARK: - Transcript

/// The chat log. Each entry is framed by a left accent bar whose color
/// encodes author and state — the workhorse device of this whole look.
struct Transcript: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    /// Crush's `maxTextWidth`: past this, lines get too long to read.
    static let maxTextWidth = 120

    var body: some TerminalView {
        // The scroll view spans the column, so its bar sits at the column's
        // edge; the entries inside stop at a readable width.
        ScrollView {
            VStack(spacing: 1) {
                ForEach(state.entries) { entry in
                    switch entry {
                    case .message(let message):
                        MessageRow(message: message, theme: theme)
                    case .tool(let call):
                        ToolCard(call: call, theme: theme)
                    }
                }
            }
            .frame(maxWidth: .fixed(Self.maxTextWidth))
        }
    }
}

/// One chat message: an author line and the body, framed the way Crush
/// frames them. What the user said carries a rail; what the agent said does
/// not, and is indented to start where the user's text starts — the rail
/// marks the turns that came from outside.
struct MessageRow: TerminalView {
    let message: Message
    var theme = CoderTheme.dark

    @TerminalViewBuilder
    var body: some TerminalView {
        switch message.author {
        case .user:
            // A border edge, so the rail runs the full height of the entry —
            // the rows a long body wraps onto included — with a column of
            // room before the text on every one of them.
            content
                .padding(.leading, 1)
                .border(.rounded, color: theme.primary, edges: .leading)
        case .assistant:
            content
                .padding(.leading, 2)
        }
    }

    private var content: some TerminalView {
        VStack(spacing: 0) {
            Text(spans: [
                TextSpan(authorLabel, foreground: authorColor, bold: true),
                TextSpan("  \(message.timestamp)", foreground: theme.foregroundFaint),
            ])
            MarkdownView(message.body)
        }
    }

    private var authorLabel: String {
        switch message.author {
        case .user: "You"
        case .assistant: "Coder"
        }
    }

    private var authorColor: Color {
        switch message.author {
        case .user: theme.primary
        case .assistant: theme.secondary
        }
    }
}

/// A tool invocation card: status icon, name, argument summary, and an
/// indented result body.
struct ToolCard: TerminalView {
    let call: ToolCall
    var theme = CoderTheme.dark

    var body: some TerminalView {
        // No rail: a tool call is subordinate to the message that caused it.
        // It sits two columns in, level with message text, as Crush sets it.
        VStack(spacing: 0) {
            Text(spans: [
                TextSpan(badge.glyph, foreground: badge.color),
                TextSpan(" \(call.name)", foreground: theme.secondary, bold: true),
                TextSpan("  \(call.summary)", foreground: theme.foregroundMuted),
            ])
            if let diff = call.diff {
                DiffView(lines: diff, visibleHeight: diff.count)
            } else if let excerpt = call.excerpt {
                ToolExcerpt(excerpt: excerpt, theme: theme)
            } else if let output = call.output {
                ToolOutput(text: output, theme: theme)
            } else if call.state == .pending {
                Text("Waiting for tool response...")
                    .foreground(theme.foregroundFaint)
            }
        }
        .padding(.leading, 2)
    }

    private var badge: (glyph: String, color: Color) {
        switch call.state {
        case .pending: (Glyph.dot, theme.warning)
        case .success: (Glyph.check, theme.success)
        case .failure: (Glyph.cross, theme.error)
        }
    }
}

/// How much of a tool's result the transcript gives it — Crush's
/// `responseContextHeight`.
enum ResultCap {
    static let maxLines = 10

    /// Lines to show of `count`. Hiding one line would spend a line saying
    /// so, so a result one over the cap is shown whole.
    static func shown(of count: Int) -> Int {
        count <= maxLines + 1 ? count : maxLines
    }
}

/// The note under a capped result, counting what it held back.
struct HiddenLines: TerminalView {
    let count: Int
    var theme = CoderTheme.dark

    var body: some TerminalView {
        Text(" … (\(count) lines hidden)")
            .foreground(theme.foregroundFaint)
    }
}

/// A tool's plain-text result, the way Crush shows it: a raised block the
/// width of the card, each line cut to fit rather than wrapped, and capped.
struct ToolOutput: TerminalView {
    let text: String
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = ResultCap.shown(of: lines.count)

        VStack(spacing: 0) {
            Text(lines.prefix(shown).map { " " + $0 }.joined(separator: "\n"))
                .wrap(.truncate(.tail))
                .foreground(theme.foregroundMuted)
            if lines.count > shown {
                HiddenLines(count: lines.count - shown, theme: theme)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.backgroundRaised)
    }
}

/// File text a reading tool returned: highlighted by the file's language,
/// numbered from where the read started, cut to the card's width, capped.
struct ToolExcerpt: TerminalView {
    let excerpt: FileExcerpt
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let lines = excerpt.code.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = ResultCap.shown(of: lines.count)

        VStack(spacing: 0) {
            CodeView(lines.prefix(shown).joined(separator: "\n"), language: excerpt.language,
                     lineNumbers: true, firstLineNumber: excerpt.firstLine)
                .wrap(.truncate(.tail))
            if lines.count > shown {
                HiddenLines(count: lines.count - shown, theme: theme)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.backgroundRaised)
    }
}

// MARK: - Prompt

/// The composer: Crush's borderless editor. Three rows, each led by its
/// prompt column — `>` on the first while focused, `:::` everywhere else —
/// with the draft or a placeholder beside the first.
struct Prompt: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    /// Crush's `TextareaMinHeight`.
    static let rows = 3

    var body: some TerminalView {
        let focused = state.focus == .prompt
        let draftLines = state.draft.isEmpty ? [] : state.draft.split(separator: "\n").map(String.init)
        return VStack(spacing: 0) {
            ForEach(Array(0..<max(Self.rows, draftLines.count)).map(PromptLine.init)) { line in
                Text(spans: spans(row: line.id, draft: draftLines, focused: focused))
            }
        }
    }

    private func spans(row: Int, draft: [String], focused: Bool) -> [TextSpan] {
        let prompt: TextSpan
        switch (row, focused) {
        case (0, true): prompt = TextSpan("  > ", foreground: theme.success, bold: true)
        case (0, false): prompt = TextSpan("::: ", foreground: theme.foregroundMuted)
        case (_, true): prompt = TextSpan("::: ", foreground: theme.successSubtle)
        case (_, false): prompt = TextSpan("::: ", foreground: theme.foregroundMuted)
        }
        if draft.isEmpty {
            return row == 0
                ? [prompt, TextSpan("Ask anything, or / for commands", foreground: theme.foregroundFaint)]
                : [prompt]
        }
        return [prompt, TextSpan(row < draft.count ? draft[row] : "", foreground: theme.foreground)]
    }
}

private struct PromptLine: Identifiable {
    let id: Int
}

/// Progress chip for the active task list.
struct TodoPill: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let current = state.todos.first { if case .inProgress = $0.status { true } else { false } }
        return Text(spans: [
            TextSpan("To-Do", foreground: theme.foregroundMuted),
            TextSpan(" \(state.doneTodoCount)/\(state.todos.count)", foreground: theme.accent),
            TextSpan("  \(current?.title ?? "")", foreground: theme.foregroundFaint),
        ])
    }
}

// MARK: - Root

/// The whole window, on Crush's layout: a margin all round, the transcript
/// and composer in a column beside a fixed sidebar, the help line beneath.
/// One flat ground — parts are told apart by space and type, not boxes.
struct CoderApp: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                VStack(spacing: 1) {
                    Transcript(state: state, theme: theme)
                        .flexible(.vertical)
                    TodoPill(state: state, theme: theme)
                    Prompt(state: state, theme: theme)
                }
                .flexible(.horizontal)
                Sidebar(state: state, theme: theme)
                    .frame(width: Sidebar.width)
            }
            .flexible(.vertical)
            .padding(1)
            Text(spans: [TextSpan(" ")] + HelpLine.spans([
                ("tab", "focus"),
                ("^p", "palette"),
                ("q", "quit"),
            ], theme: theme))
        }
        .background(theme.background)
        // Published so the framework's own components resolve the same
        // palette the demo's views were handed directly. Without this a
        // Button dropped into the transcript would still be drawing the
        // stock cyan-on-gray.
        .environment(\.theme, theme)
        // A hairline bar with no arrows: the transcript's position is read
        // from a violet thumb on a graphite track, as Crush draws it.
        .scrollbarStyle(.hairline)
        .markdownStyle(.coder(theme))
    }
}
