import TerminalUI

// MARK: - Sidebar

/// Right rail: identity, then session, model, and what the session touches.
/// Laid out the way Crush's is — a fixed wordmark over one quiet column, each
/// part separated by a blank row rather than boxed.
struct Sidebar: TerminalView {
    let state: CoderState

    /// The rows the sidebar is laid out in.
    let height: Int
    var theme = CoderTheme.dark

    /// Crush's sidebar width.
    static let width = 32
    /// Height below which the wordmark's letterforms would crowd out the
    /// sections under them, and it takes one row instead — Crush's
    /// breakpoint.
    static let letterformHeight = 30

    var body: some TerminalView {
        VStack(spacing: 1) {
            Wordmark(width: Self.width, compact: height < Self.letterformHeight, theme: theme)
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
                // A click opens that file's change in the review.
                .onClick { _, _ in coderState.openReview(on: file) }
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

/// The chat log. Tab reaches it from the composer, as in Crush: the arrows
/// then scroll it, Shift+↑/↓ (or K/J) step the selected entry, and Space or
/// a click opens a capped result. The selected entry's rail thickens while
/// the log holds focus.
struct Transcript: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    /// Crush's `maxTextWidth`: past this, lines get too long to read.
    static let maxTextWidth = 120

    var body: some TerminalView {
        let state = state
        let selection = state.selection
        // The scroll view spans the column, so its bar sits at the column's
        // edge; the entries inside stop at a readable width. Like Crush's, it
        // opens on the latest entry and keeps the newest in view as they
        // arrive, until the reader scrolls back to read.
        ScrollView {
            VStack(spacing: 1) {
                ForEach(state.entries) { entry in
                    EntryRow(entry: entry, isSelected: entry.id == selection,
                             isExpanded: state.expandedResults.contains(entry.id), theme: theme)
                        .id(entry.id)
                        .onClick { _, _ in state.click(entry.id) }
                }
            }
            .frame(maxWidth: .fixed(Self.maxTextWidth))
        }
        .scrollable()
        .onKeyPress { event in Self.handleKey(event, state: state) }
        // Any part of an entry in sight counts: a reply taller than the
        // pane is still the one being read.
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0) { state.entriesInSight($0) }
        .scrollPosition(id: Binding(get: { state.transcriptPosition }, set: { state.transcriptPosition = $0 }))
        .defaultScrollAnchor(.bottom)
    }

    /// Crush's chat keys beyond the scrolling the scroll view does itself.
    static func handleKey(_ event: KeyEvent, state: CoderState) -> KeyEventResult {
        switch (event.key, event.modifiers) {
        case (.up, .shift), (.character("K"), []):
            state.selectEntry(by: -1)
        case (.down, .shift), (.character("J"), []):
            state.selectEntry(by: 1)
        case (.character(" "), []):
            state.toggleSelectedResult()
        default:
            return .ignored
        }
        return .handled
    }
}

/// One transcript entry in the frame Crush gives it: a rail down its
/// leading edge — thin for what the user said, none for the agent — that
/// thickens to `▌` on the entry selected while the transcript holds focus.
/// Agent text sits two columns in, level with the user's past their rail.
struct EntryRow: TerminalView {
    let entry: Entry
    let isSelected: Bool
    let isExpanded: Bool
    var theme = CoderTheme.dark

    @TerminalEnvironment(\.isFocused) private var transcriptFocused

    var body: some TerminalView {
        // Read focus only on the selected row — a read is a subscription,
        // and every other row would redraw at each Tab for nothing.
        let focused = isSelected && transcriptFocused
        let isUser = if case .message(let message) = entry { message.author == .user } else { false }
        let railed = isUser || focused
        // One modifier chain whatever the state, so an entry keeps its
        // identity as the selection moves on and off it.
        content
            .padding(.leading, railed ? 1 : 2)
            .border(focused ? .halfBlock : .rounded,
                    color: isUser ? theme.primary : theme.successSubtle,
                    edges: railed ? .leading : [])
    }

    @TerminalViewBuilder
    private var content: some TerminalView {
        switch entry {
        case .message(let message):
            MessageBody(message: message, theme: theme)
        case .tool(let call):
            ToolCard(call: call, isExpanded: isExpanded, theme: theme)
        }
    }
}

/// A chat message's author line and markdown body.
struct MessageBody: TerminalView {
    let message: Message
    var theme = CoderTheme.dark

    var body: some TerminalView {
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

/// A tool invocation card: status icon, name, argument summary, and the
/// result beneath, capped until the reader opens it.
struct ToolCard: TerminalView {
    let call: ToolCall
    var isExpanded = false
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 0) {
            Text(spans: [
                TextSpan(badge.glyph, foreground: badge.color),
                TextSpan(" \(call.name)", foreground: theme.secondary, bold: true),
                TextSpan("  \(call.summary)", foreground: theme.foregroundMuted),
            ])
            if let diff = call.diff {
                DiffView(lines: diff, visibleHeight: diff.count)
                    .diffLanguage(call.language)
            } else if let excerpt = call.excerpt {
                ToolExcerpt(excerpt: excerpt, isExpanded: isExpanded, theme: theme)
            } else if let output = call.output {
                ToolOutput(text: output, isExpanded: isExpanded, theme: theme)
            } else if call.state == .pending {
                Text("Waiting for tool response...")
                    .foreground(theme.foregroundFaint)
            }
        }
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

/// What of a result the transcript shows: up to the cap, all of it once the
/// reader opened it, and how many lines that leaves out.
struct CappedLines {
    let shown: ArraySlice<Substring>
    let hidden: Int

    init(_ text: String, expanded: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let count = expanded ? lines.count : ResultCap.shown(of: lines.count)
        shown = lines.prefix(count)
        hidden = lines.count - count
    }
}

/// The note under a capped result: what it held back, and how to see it —
/// Crush's `assistantMessageTruncateFormat`.
struct HiddenLines: TerminalView {
    let count: Int
    var theme = CoderTheme.dark

    var body: some TerminalView {
        Text(" … (\(count) lines hidden) [click or space to expand]")
            .foreground(theme.foregroundFaint)
    }
}

/// A tool's plain-text result, the way Crush shows it: a raised block the
/// width of the card, each line cut to fit rather than wrapped, and capped.
struct ToolOutput: TerminalView {
    let text: String
    var isExpanded = false
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let lines = CappedLines(text, expanded: isExpanded)

        VStack(spacing: 0) {
            Text(lines.shown.map { " " + $0 }.joined(separator: "\n"))
                .wrap(.truncate(.tail))
                .foreground(theme.foregroundMuted)
            if lines.hidden > 0 {
                HiddenLines(count: lines.hidden, theme: theme)
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
    var isExpanded = false
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let lines = CappedLines(excerpt.code, expanded: isExpanded)

        VStack(spacing: 0) {
            CodeView(lines.shown.joined(separator: "\n"), language: excerpt.language,
                     lineNumbers: true, firstLineNumber: excerpt.firstLine)
                .wrap(.truncate(.tail))
            if lines.hidden > 0 {
                HiddenLines(count: lines.hidden, theme: theme)
            }
        }
        .frame(maxWidth: .infinity)
        .background(theme.backgroundRaised)
    }
}

// MARK: - Prompt

/// The composer: Crush's borderless editor. Three rows, each led by its
/// prompt column — `>` on the first while focused, `:::` everywhere else —
/// with the draft or a placeholder beside the first. Enter sends the draft.
struct Prompt: TerminalView {
    let state: CoderState

    /// Crush's `TextareaMinHeight`.
    static let rows = 3

    /// The column Crush's editor draws through its textarea's prompt
    /// function: green while focused, muted when focus is elsewhere.
    static let column = PromptPrefix(width: 4) { row in
        switch (row.index, row.isFocused) {
        case (0, true): [TextSpan("  > ", foreground: row.theme.success, bold: true)]
        case (_, true): [TextSpan("::: ", foreground: row.theme.successSubtle)]
        default: [TextSpan("::: ", foreground: row.theme.foregroundMuted)]
        }
    }

    var body: some TerminalView {
        let state = self.state
        return PromptInput(
            text: Binding(get: { state.draft }, set: { state.draft = $0 }),
            state: Binding(get: { state.promptState }, set: { state.promptState = $0 }),
            placeholder: "Ask anything, or / for commands",
            minimumHeight: Self.rows,
            onSubmit: { state.send($0) }
        )
        .promptPrefix(Self.column)
        // The transcript comes first in Tab order; the keys belong here when
        // the app opens, as in Crush.
        .prefersDefaultFocus()
    }
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
    @TerminalEnvironment(\.terminalSize) private var terminalSize

    /// The blank cells around the transcript and sidebar.
    static let margin = 1
    /// The help line's rows, beneath the margin.
    static let helpHeight = 1

    /// The side panel's width: two thirds of the window, room for the file
    /// list and a readable diff, and never narrower than the sidebar it covers.
    private var reviewPanelWidth: Int {
        max(Sidebar.width, (terminalSize.cols - 2 * Self.margin) * 2 / 3)
    }

    private var helpHints: [(key: String, action: String)] {
        [("enter", "send"), ("tab", "focus chat"), ("^r", "review"), ("^o", "settings"), ("^c", "quit")]
    }

    private var reviewHints: [(key: String, action: String)] {
        state.reviewShowsDiff
            ? [("↑↓", "scroll"), ("esc", "back to files"), ("^o", "settings"), ("^c", "quit")]
            : [("↑↓", "file"), ("enter", "open"), ("←→", "source"), ("esc", "close"), ("^c", "quit")]
    }

    var body: some TerminalView {
        let sidebarHeight = terminalSize.rows - 2 * Self.margin - Self.helpHeight
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                VStack(spacing: 1) {
                    Transcript(state: state, theme: theme)
                        .flexible(.vertical)
                    TodoPill(state: state, theme: theme)
                    Prompt(state: state)
                }
                .flexible(.horizontal)
                Sidebar(state: state, height: sidebarHeight, theme: theme)
                    .frame(width: Sidebar.width)
            }
            .flexible(.vertical)
            .padding(Self.margin)
            Text(spans: [TextSpan(" ")] + HelpLine.spans(helpHints, theme: theme))
        }
        // Declared beneath the review, so it comes later in drawing order and
        // is drawn over the review when opened from it.
        .modal(isPresented: state.showsSettings) {
            SettingsDialog(state: state, theme: theme)
        }
        // A panel over the sidebar's side of the window, the transcript in
        // view beside it — or the whole window, with the setting on.
        .inspector(isPresented: Binding(get: { state.showsReview }, set: { coderState.showsReview = $0 })) {
            VStack(spacing: 0) {
                DiffReview(state: state, height: sidebarHeight, theme: theme)
                    .flexible(.vertical)
                    .padding(Self.margin)
                Text(spans: [TextSpan(" ")] + HelpLine.spans(reviewHints, theme: theme))
            }
            .frame(width: state.fullScreenReview ? terminalSize.cols : reviewPanelWidth)
            .border(.halfBlock, color: theme.borderActive, edges: state.fullScreenReview ? [] : .leading)
            .background(theme.background)
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
        // The composer's `>` says where keys go; Crush draws no other mark.
        .focusIndicator(.none)
        // Escape is the framework's dismiss-or-quit. In Crush it cancels the
        // request in flight and never closes the session — a reflex press
        // must not cost the user their conversation. Coder runs no agent, so
        // there is nothing to cancel yet; the binding is here to own the key.
        .actions {
            Action(id: "coder.cancel", title: .literal("Cancel"), perform: {})
                .bound(to: .keyboard(.escape, []))
            Action(id: "coder.review", title: .literal("Review changes"), perform: {
                coderState.toggleReview()
            })
            .bound(to: .keyboard(.character("r"), [.ctrl]))
            Action(id: "coder.settings", title: .literal("Settings"), perform: {
                coderState.showsSettings = true
            })
            .bound(to: .keyboard(.character("o"), [.ctrl]))
        }
    }
}
