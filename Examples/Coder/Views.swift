import TerminalUI

// MARK: - Header

/// Top band: wordmark, diagonal field, and session metadata.
///
/// GAP LEDGER — the wordmark is flat text. Crush ramps a gradient across
/// its letterforms and gives the diagonal field a second ramp; both need
/// G2 (color blending). Structure first, flourish later.
struct Header: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        GeometryReader { size in
            Text(spans: line(width: size.width))
        }
        .frame(height: 1)
        .background(theme.bgRaised)
    }

    private func line(width: Int) -> [TextSpan] {
        let brand: [TextSpan] = [
            TextSpan(" CODER", foreground: theme.primaryLift, bold: true),
            TextSpan(" "),
        ]
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
            TextSpan(state.workingDirectory, foreground: theme.fgMoreSubtle),
            separator,
            TextSpan("\(state.contextPercent)%", foreground: theme.fgSubtle),
            TextSpan(" (\(state.contextLabel))", foreground: theme.fgMostSubtle),
            separator,
            TextSpan("^p", foreground: theme.fgSubtle, bold: true),
            TextSpan(" palette ", foreground: theme.fgMostSubtle),
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
        .background(theme.bgRaised)
    }

    private var sessionBlock: some TerminalView {
        VStack(spacing: 0) {
            Text(state.sessionTitle)
                .foreground(theme.fgBase)
                .bold()
            Text(state.workingDirectory)
                .foreground(theme.fgMostSubtle)
            Text(spans: [
                TextSpan(Glyph.diamond, foreground: theme.primaryLift),
                TextSpan(" \(state.modelName)", foreground: theme.fgSubtle),
                TextSpan(" via \(state.providerName)", foreground: theme.fgMostSubtle),
            ])
            Text(spans: [
                TextSpan("\(state.contextPercent)%", foreground: theme.fgMoreSubtle),
                TextSpan(" (\(state.contextLabel))", foreground: theme.fgMostSubtle),
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
                    TextSpan(file.path, foreground: theme.fgSubtle),
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
///
/// GAP LEDGER — G4. TerminalUI's `.border(_:)` draws all four sides and
/// takes its color from the inherited foreground, so a one-column colored
/// rail is not expressible. Every row here fakes it by prefixing a glyph
/// inside an `HStack`, which means the bar cannot span a wrapped message
/// body — it marks only the first line. The framework fix is
/// `.border(_:color:edges:)`.
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
        HStack(spacing: 1) {
            Text(Glyph.barThick)
                .foreground(railColor)
            VStack(spacing: 0) {
                Text(spans: [
                    TextSpan(authorLabel, foreground: railColor, bold: true),
                    TextSpan("  \(message.timestamp)", foreground: theme.fgMostSubtle),
                ])
                // GAP LEDGER — G5. `body` is markdown in every real agent
                // TUI. Rendered as plain text until the framework has a
                // markdown view.
                Text(message.body)
                    .foreground(theme.fgSubtle)
            }
        }
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
        case .assistant: theme.primaryLift
        }
    }
}

/// A tool invocation card: status icon, name, argument summary, and an
/// indented result body.
struct ToolCard: TerminalView {
    let call: ToolCall
    var theme = CoderTheme.dark

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(Glyph.barThin)
                .foreground(theme.separator)
            VStack(spacing: 0) {
                Text(spans: [
                    TextSpan(badge.glyph, foreground: badge.color),
                    TextSpan(" \(call.name)", foreground: theme.keyword, bold: true),
                    TextSpan("  \(call.summary)", foreground: theme.fgMoreSubtle),
                ])
                if let output = call.output {
                    Text(output)
                        .foreground(theme.fgMostSubtle)
                }
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

// MARK: - Prompt

/// The composer. A mode glyph, the draft text, and a hint line.
struct Prompt: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                Text(":::")
                    .foreground(state.focus == .prompt ? theme.primaryLift : theme.fgMostSubtle)
                Text(state.draft.isEmpty ? "Ask anything, or / for commands" : state.draft)
                    .foreground(state.draft.isEmpty ? theme.fgMostSubtle : theme.fgBase)
            }
            TodoPill(state: state, theme: theme)
        }
        .padding(1)
        // GAP LEDGER — G4 again. A focused composer should read as a
        // tinted frame around dim content; today the border inherits the
        // foreground, so an explicit `.foreground` here would tint the
        // draft text too. Left unbordered rather than mis-colored.
        .background(theme.bgRaised)
    }
}

/// Progress chip for the active task list.
struct TodoPill: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        let current = state.todos.first { if case .inProgress = $0.status { true } else { false } }
        return Text(spans: [
            TextSpan("To-Do", foreground: theme.fgMoreSubtle),
            TextSpan(" \(state.doneTodoCount)/\(state.todos.count)", foreground: theme.accent),
            TextSpan("  \(current?.title ?? "")", foreground: theme.fgMostSubtle),
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
                    TextSpan("\(state.modelName) ", foreground: theme.fgMoreSubtle)
                }
            }
        }
        .background(theme.bgBase)
    }
}
