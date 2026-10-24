import TerminalUI

// MARK: - Diff review

/// A source's changes, in two levels, as Claude Code's `/diff` has them: the
/// files with their counts, and one file's diff — its changed rows tinted,
/// its code highlighted. ↑/↓ choose a file, ←/→ the source, Enter opens the
/// file and Escape steps back. Opened with Ctrl+R or a click on Modified
/// Files; a panel over the sidebar's side of the window, or the whole
/// window when the Full-screen diff review setting is on.
struct DiffReview: TerminalView {
    let state: CoderState
    /// The rows it is laid out in.
    let height: Int
    var theme = CoderTheme.dark

    /// Rows above a list or a diff: the summary and the gap under it.
    static let chromeHeight = 2

    var body: some TerminalView {
        VStack(spacing: 1) {
            if state.reviewShowsDiff, let file = state.reviewedFile {
                fileHeader(file)
                DiffView(lines: file.lines, visibleHeight: max(1, height - Self.chromeHeight))
                    .diffLanguage(file.language)
                    // A wrapped line would continue under the line numbers;
                    // cut at the edge instead.
                    .wrap(.truncate(.tail))
                    .prefersDefaultFocus()
            } else {
                summary(state.reviewChanges)
                if state.reviewChanges.isEmpty {
                    Text("No changes.").foreground(theme.foregroundMuted)
                } else {
                    fileList(state.reviewChanges)
                }
            }
            Spacer()
        }
        // The review holds the keyboard while it is up, so the app's own
        // bindings do not reach past it: the ones it offers are its own.
        .actions {
            Action(id: "coder.review.back", title: .literal("Back"), perform: {
                coderState.stepBackInReview()
            })
            .bound(to: .keyboard(.escape, []))
            Action(id: "coder.review.close", title: .literal("Close review"), perform: {
                coderState.toggleReview()
            })
            .bound(to: .keyboard(.character("r"), [.ctrl]))
            Action(id: "coder.review.settings", title: .literal("Settings"), perform: {
                coderState.showsSettings = true
            })
            .bound(to: .keyboard(.character("o"), [.ctrl]))
        }
    }

    /// "3 files changed +22 −1", and the source ←/→ moves between.
    private func summary(_ changes: [FileChange]) -> some TerminalView {
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }
        let noun = changes.count == 1 ? "file" : "files"
        return HStack(spacing: 2) {
            Text(spans: [
                TextSpan("\(changes.count) \(noun) changed", foreground: theme.foreground, bold: true),
                TextSpan("  +\(added)", foreground: theme.success),
                TextSpan(" −\(removed)", foreground: theme.error),
            ])
            Spacer()
            Text(spans: [
                TextSpan("‹ ", foreground: theme.foregroundFaint),
                TextSpan(state.reviewSource.rawValue, foreground: theme.secondary),
                TextSpan(" ›", foreground: theme.foregroundFaint),
            ])
        }
    }

    private func fileList(_ changes: [FileChange]) -> some TerminalView {
        List(changes, selection: Binding(
            get: { state.reviewedFile?.id },
            set: { coderState.reviewFileID = $0 }
        ), visibleCount: max(1, height - Self.chromeHeight)) { file in
            Text(spans: [
                TextSpan(file.path, foreground: theme.foregroundSubtle),
                TextSpan("  +\(file.added)", foreground: theme.success),
                TextSpan(" −\(file.removed)", foreground: theme.error),
            ])
            .wrap(.truncate(.head))
            .onClick { _, _ in
                coderState.reviewFileID = file.id
                coderState.reviewShowsDiff = true
            }
        }
        // Opened, the review's keys belong to its list.
        .prefersDefaultFocus()
        .onKeyPress { event in
            guard event.modifiers.isEmpty else { return .ignored }
            switch event.key {
            case .enter: coderState.reviewShowsDiff = true
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
            Text(spans: [
                TextSpan(file.path, foreground: theme.foreground, bold: true),
                TextSpan("  +\(file.added)", foreground: theme.success),
                TextSpan(" −\(file.removed)", foreground: theme.error),
            ])
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
