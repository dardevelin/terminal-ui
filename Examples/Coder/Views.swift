import TerminalUI

// MARK: - Header

/// Top band: wordmark, diagonal field, and session metadata.
struct Header: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        GeometryReader { size in
            Text(spans: line(width: size.width))
        }
        .frame(height: 1)
        .background(theme.backgroundRaised)
    }

    private func line(width: Int) -> [TextSpan] {
        // The wordmark is the one place the two brand colours meet, which is
        // what ties the header to the rails and the pills further down.
        let brand: [TextSpan] = [TextSpan(" ")]
            + Text.gradient("CODER", from: theme.primary, to: theme.secondary)
                .spans.map { $0.bolded() }
            + [TextSpan(" ")]
        let meta = metadata()
        let brandWidth = brand.reduce(0) { $0 + $1.text.count }
        let metaWidth = meta.reduce(0) { $0 + $1.text.count }
        let fill = max(0, width - brandWidth - metaWidth - 1)
        return brand
            + DiagonalField.spans(width: fill, theme: theme)
            + [TextSpan(" ")]
            + meta
    }

    private func metadata() -> [TextSpan] {
        let separator = TextSpan(" \(Glyph.bullet) ", foreground: theme.separator)
        return [
            TextSpan(state.workingDirectory, foreground: theme.foregroundMuted),
            separator,
            TextSpan("\(state.contextPercent)%", foreground: theme.foregroundSubtle),
            TextSpan(" (\(state.contextLabel))", foreground: theme.foregroundFaint),
            separator,
            TextSpan("^p", foreground: theme.foregroundSubtle, bold: true),
            TextSpan(" palette ", foreground: theme.foregroundFaint),
        ]
    }
}

// MARK: - Sidebar

/// Right rail: session identity, model, touched files, and resource health.
struct Sidebar: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 1) {
            sessionBlock
            filesBlock
            resourcesBlock
            Spacer()
        }
        .padding(1)
        .background(theme.backgroundRaised)
    }

    private var sessionBlock: some TerminalView {
        VStack(spacing: 0) {
            Text(state.sessionTitle)
                .foreground(theme.foreground)
                .bold()
            Text(state.workingDirectory)
                .foreground(theme.foregroundFaint)
            Text(spans: [
                TextSpan(Glyph.diamond, foreground: theme.primary),
                TextSpan(" \(state.modelName)", foreground: theme.foregroundSubtle),
                TextSpan(" via \(state.providerName)", foreground: theme.foregroundFaint),
            ])
            Text(spans: [
                TextSpan("\(state.contextPercent)%", foreground: theme.foregroundMuted),
                TextSpan(" (\(state.contextLabel))", foreground: theme.foregroundFaint),
                TextSpan("  $\(String(format: "%.2f", state.cost))", foreground: theme.success),
            ])
        }
    }

    private var filesBlock: some TerminalView {
        VStack(spacing: 0) {
            SectionRule(
                title: "Modified Files",
                trailing: "\(state.files.count)",
                theme: theme
            )
            ForEach(state.files) { file in
                // Head truncation: the basename is what identifies the file,
                // so the directory prefix is the part that gives way.
                Text(spans: [
                    TextSpan(file.path, foreground: theme.foregroundSubtle),
                    TextSpan("  +\(file.added)", foreground: theme.success),
                    TextSpan(" −\(file.removed)", foreground: theme.error),
                ])
                .wrap(.truncate(.head))
            }
        }
    }

    private var resourcesBlock: some TerminalView {
        VStack(spacing: 0) {
            SectionRule(title: "Servers", theme: theme)
            ForEach(state.resources) { resource in
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

    var body: some TerminalView {
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
        }
        .padding(1)
    }
}

/// One chat message: an accent rail, an author line, and the body.
struct MessageRow: TerminalView {
    let message: Message
    var theme = CoderTheme.dark

    var body: some TerminalView {
        // The rail is a real border edge, so it runs the full height of the
        // entry — including the rows a long body wraps onto.
        VStack(spacing: 0) {
            Text(spans: [
                TextSpan(authorLabel, foreground: railColor, bold: true),
                TextSpan("  \(message.timestamp)", foreground: theme.foregroundFaint),
            ])
            MarkdownView(message.body)
        }
        // GAP LEDGER — G3. Crush sets a single column of breathing room
        // between the rail and the text (BorderLeft + PaddingLeft(1)).
        // `.padding(1)` is uniform, so it would also open a blank row above
        // and below every entry. A gap on the first line only — from padding
        // the spans — would be worse, since the wrapped continuation rows
        // would not get it. Flush until edge-aware padding lands.
        .border(.heavy, color: railColor, edges: .leading)
    }

    private var authorLabel: String {
        switch message.author {
        case .user: "You"
        case .assistant: "Coder"
        }
    }

    private var railColor: Color {
        switch message.author {
        case .user: theme.secondary
        case .assistant: theme.primary
        }
    }
}

/// A tool invocation card: status icon, name, argument summary, and an
/// indented result body.
struct ToolCard: TerminalView {
    let call: ToolCall
    var theme = CoderTheme.dark

    var body: some TerminalView {
        // Quiet rail: a tool call is subordinate to the message that caused
        // it, so the frame is thin and the separator colour rather than an
        // author accent.
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
        .border(.rounded, color: theme.separator, edges: .leading)
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

/// The composer. A mode glyph, the draft text, and a hint line.
struct Prompt: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                Text(":::")
                    .foreground(state.focus == .prompt ? theme.primary : theme.foregroundFaint)
                Text(state.draft.isEmpty ? "Ask anything, or / for commands" : state.draft)
                    .foreground(state.draft.isEmpty ? theme.foregroundFaint : theme.foreground)
            }
            TodoPill(state: state, theme: theme)
        }
        .padding(1)
        // Focus reads as a brightened top rule: the frame states focus
        // without tinting the draft text inside it.
        .border(
            .heavy,
            color: state.focus == .prompt ? theme.borderActive : theme.borderIdle,
            edges: .top)
        .background(theme.backgroundRaised)
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

/// The whole window: header, split body, prompt, status bar.
struct CoderApp: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 0) {
            Header(state: state, theme: theme)
            HStack(spacing: 0) {
                Transcript(state: state, theme: theme)
                    .flexible(.horizontal)
                Sidebar(state: state, theme: theme)
                    .frame(width: 34)
            }
            .flexible(.vertical)
            Prompt(state: state, theme: theme)
            StatusBar(background: Palette.slate, foreground: Palette.ash) {
                StatusBar.Section(.left) {
                    KeyHint.spans("tab", "focus", theme: theme)
                    "   "
                    KeyHint.spans("^p", "palette", theme: theme)
                    "   "
                    KeyHint.spans("q", "quit", theme: theme)
                }
                StatusBar.Section(.right) {
                    TextSpan("\(state.modelName) ", foreground: theme.foregroundMuted)
                }
            }
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
    }
}
