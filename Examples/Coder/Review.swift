import TerminalUI

// MARK: - Diff review

/// A source's changes as Claude Code's `/diff` panel stacks them: the files
/// with their counts, folding under the summary, and below them the chosen
/// file's diff — its changed rows tinted, its code highlighted. ↑/↓ choose a
/// file and the diff follows; ←/→ choose the source; Tab reaches the diff
/// to scroll it. Opened with Ctrl+R or a click on Modified Files, in the
/// sidebar's place, or over the whole window with the Full-screen diff
/// review setting on.
struct DiffReview: TerminalView {
    let state: CoderState
    /// The rows it is laid out in.
    let height: Int
    var theme = CoderTheme.dark

    /// The most files listed at once; more scroll.
    static let listRows = 8
    /// Rows that are not the list or the diff: the summary, and the rules
    /// around the file's header and the header itself.
    static let chromeRows = 4

    private var listHeight: Int {
        state.reviewListExpanded ? min(Self.listRows, state.reviewChanges.count) : 0
    }

    /// What the summary says in place of counts, while there is nothing to
    /// count: "0 files changed" would claim a clean tree before git answers.
    private var note: String? {
        if state.reviewSource != .session, let problem = state.gitProblem { return problem }
        if state.changes[state.reviewSource] == nil { return "Reading git…" }
        return state.reviewChanges.isEmpty ? "No changes." : nil
    }

    var body: some TerminalView {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: Binding(
                get: { state.reviewListExpanded },
                set: { coderState.reviewListExpanded = $0 }
            )) {
                // Empty, it is still focusable: it takes focus when the
                // review opens, before git has answered too.
                fileList(state.reviewChanges)
            } label: {
                summary(state.reviewChanges)
            }
            if let file = state.reviewedFile {
                Divider()
                fileHeader(file)
                Divider()
                DiffView(lines: file.lines,
                         visibleHeight: max(1, height - Self.chromeRows - listHeight))
                    .diffLanguage(file.language)
                    // A wrapped line would continue under the line numbers;
                    // cut at the edge instead.
                    .wrap(.truncate(.tail))
            }
            Spacer()
        }
        // Read git while the review is open, so a file changed meanwhile
        // appears in it; the task ends when the review closes.
        .task {
            while !Task.isCancelled {
                await coderState.refreshFromGit()
                try? await Task.sleep(for: CoderState.gitRefreshInterval)
            }
        }
        // The review holds the keyboard while it is up, so the app's own
        // bindings do not reach past it: the ones it offers are its own.
        .actions {
            Action(id: "coder.review.close", title: .literal("Close review"), perform: {
                coderState.showsReview = false
            })
            .bound(to: .keyboard(.escape, []))
            Action(id: "coder.review.toggle", title: .literal("Close review"), perform: {
                coderState.toggleReview()
            })
            .bound(to: .keyboard(.character("r"), [.ctrl]))
            Action(id: "coder.review.settings", title: .literal("Settings"), perform: {
                coderState.showsSettings = true
            })
            .bound(to: .keyboard(.character("o"), [.ctrl]))
        }
    }

    /// "3 files changed +22 −1", or what stands in for it, and the source
    /// ←/→ moves between.
    private func summary(_ changes: [FileChange]) -> some TerminalView {
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }
        let noun = changes.count == 1 ? "file" : "files"
        return HStack(spacing: 1) {
            Text(spans: note.map { [TextSpan($0, foreground: theme.foregroundMuted)] } ?? [
                TextSpan("\(changes.count) \(noun) changed", foreground: theme.foreground, bold: true),
                TextSpan(" +\(added)", foreground: theme.success),
                TextSpan(" −\(removed)", foreground: theme.error),
            ])
            .wrap(.truncate(.tail))
            Spacer()
            // The source names what is listed; short of room, the summary
            // gives way.
            Text(spans: [
                TextSpan("‹ ", foreground: theme.foregroundFaint),
                TextSpan(state.reviewSource.rawValue, foreground: theme.secondary),
                TextSpan(" ›", foreground: theme.foregroundFaint),
            ])
            .wrap(.none)
        }
    }

    private func fileList(_ changes: [FileChange]) -> some TerminalView {
        List(changes, selection: Binding(
            get: { state.reviewedFile?.id },
            set: { coderState.reviewFileID = $0 }
        ), visibleCount: listHeight) { file in
            HStack(spacing: 2) {
                Text(file.path)
                    .foreground(theme.foregroundSubtle)
                    .wrap(.truncate(.head))
                Spacer()
                Text(spans: [
                    TextSpan("+\(file.added)", foreground: theme.success),
                    TextSpan(" −\(file.removed)", foreground: theme.error),
                ])
            }
            // The row's width, so the counts stand at its right edge.
            .frame(maxWidth: .infinity)
            .onClick { _, _ in coderState.reviewFileID = file.id }
        }
        // Opened, the review's keys belong to its list.
        .prefersDefaultFocus()
        .onKeyPress { event in
            guard event.modifiers.isEmpty else { return .ignored }
            switch event.key {
            case .left: coderState.switchReviewSource(by: -1)
            case .right: coderState.switchReviewSource(by: 1)
            default: return .ignored
            }
            return .handled
        }
    }

    /// The file's path and counts, and the question to ask about it.
    private func fileHeader(_ file: FileChange) -> some TerminalView {
        HStack(spacing: 2) {
            Text(file.path)
                .bold()
                .foreground(theme.foreground)
                .wrap(.truncate(.head))
            Spacer()
            Button("ask") { coderState.ask(about: file) }
        }
    }
}

// MARK: - Settings

/// The app's settings, over everything. One so far: whether the diff review
/// covers the whole window. Ctrl+O opens it, Escape closes it.
struct SettingsDialog: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    var body: some TerminalView {
        VStack(spacing: 1) {
            Text("Settings").bold().foreground(theme.primary)
            Form {
                Section("Review") {
                    Toggle("Full-screen diff review", isOn: Binding(
                        get: { coderState.fullScreenReview },
                        set: { coderState.fullScreenReview = $0 }
                    ))
                }
            }
            Text(spans: HelpLine.spans([("space", "toggle"), ("esc", "close")], theme: theme))
        }
        .padding(1)
        .frame(width: 44)
        .border(.rounded, color: theme.borderActive)
        .background(theme.background)
        .actions {
            Action(id: "coder.settings.close", title: .literal("Close settings"), perform: {
                coderState.showsSettings = false
            })
            .bound(to: .keyboard(.escape, []))
        }
    }
}
