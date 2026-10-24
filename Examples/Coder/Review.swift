import TerminalUI

// MARK: - Diff review

/// A source's changes as Claude Code's `/diff` panel stacks them: the files
/// with their counts, folding under the summary, and below them every
/// file's diff in one scroll — each under its own header, each folding away
/// on a click there, changed rows tinted and code highlighted. ↑/↓ choose a
/// file and its section scrolls up; scroll, and the list follows the section
/// on top. ←/→ choose the source. Opened with Ctrl+R or a click on Modified
/// Files, in the sidebar's place, or over the whole window with the
/// Full-screen diff review setting on.
struct DiffReview: TerminalView {
    let state: CoderState
    var theme = CoderTheme.dark

    /// The most files listed at once; more scroll.
    static let listRows = 8

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
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(state.reviewChanges) { file in
                        section(file)
                    }
                }
            }
            .flexible(.vertical)
            // Both ways: choosing a file scrolls its section to the top, and
            // scrolling chooses the file whose section is on top.
            .scrollPosition(id: Binding(get: { state.reviewPosition },
                                        set: { coderState.followReviewScroll(to: $0) }),
                            anchor: .top)
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
            // Flexible, so it takes what the source leaves and is what gives
            // way when the panel is narrow.
            Text(spans: note.map { [TextSpan($0, foreground: theme.foregroundMuted)] } ?? [
                TextSpan("\(changes.count) \(noun) changed", foreground: theme.foreground, bold: true),
                TextSpan(" +\(added)", foreground: theme.success),
                TextSpan(" −\(removed)", foreground: theme.error),
            ])
            .wrap(.truncate(.tail))
            .flexible(.horizontal)
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
            set: { coderState.chooseReviewFile($0) }
        ), visibleCount: listHeight) { file in
            HStack(spacing: 2) {
                // The path takes what the counts leave, and loses its start
                // first: the file's name is what tells files apart.
                Text(file.path)
                    .foreground(theme.foregroundSubtle)
                    .wrap(.truncate(.head))
                    .flexible(.horizontal)
                Text(spans: [
                    TextSpan("+\(file.added)", foreground: theme.success),
                    TextSpan(" −\(file.removed)", foreground: theme.error),
                ])
                .wrap(.none)
            }
            .onClick { _, _ in coderState.chooseReviewFile(file.id) }
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

    /// One file's change: its header between rules, then its diff, which a
    /// click on the header folds away.
    private func section(_ file: FileChange) -> some TerminalView {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: Binding(
                get: { !state.reviewFolded.contains(file.id) },
                set: { coderState.setReviewSection(file.id, expanded: $0) }
            )) {
                Divider()
                // As tall as the change: the scroll around it does the
                // scrolling, so a section is never a scroller of its own.
                DiffView(lines: file.lines, visibleHeight: max(1, file.lines.count))
                    .diffLanguage(file.language)
                    // A wrapped line would continue under the line numbers;
                    // cut at the edge instead.
                    .wrap(.truncate(.tail))
            } label: {
                fileHeader(file)
            }
        }
        .id(file.id)
    }

    /// The file's path and counts, and the question to ask about it.
    private func fileHeader(_ file: FileChange) -> some TerminalView {
        HStack(spacing: 2) {
            Text(spans: [TextSpan(file.path, foreground: theme.foreground, bold: true)]
                 + (file.isUntracked ? [TextSpan("  (untracked)", foreground: theme.foregroundMuted)] : []))
                .wrap(.truncate(.head))
                .flexible(.horizontal)
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
