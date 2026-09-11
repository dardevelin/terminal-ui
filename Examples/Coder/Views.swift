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
            if let output = call.output {
                Text(output)
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
    }
}
