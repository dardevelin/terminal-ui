import Foundation
import Observation
import TerminalUI

// MARK: - File-tree pane

/// Left pane: the list of changed files. Selection is keyboard-
/// and click-driven (TreeView handles both); when the selection
/// changes, the diff pane below re-renders against the new file.
struct FileTreePane: TerminalView {
    let state: GitClientState

    var body: some TerminalView {
        let rows = state.files.map(FileRow.make)
        let selectionBinding = Binding<String?>(
            get: { state.selectedFileID },
            set: { state.selectedFileID = $0 }
        )

        VStack {
            Text("Files (\(state.files.count))")
                .foreground(.cyan)
                .bold()
            Divider()
            TreeView(
                rows,
                children: \.children,
                selection: selectionBinding
            ) { row in
                Text(row.label)
            }
        }
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Diff pane

/// Right pane: hunk-by-hunk diff for `state.selectedFile`. Empty-
/// state placeholder when no file is selected. Includes its own
/// hunk-cursor (we wrap HunkDiffView and forward arrow keys via
/// .onKeyPress so `s` / `u` operate on the line under the cursor).
struct DiffPane: TerminalView {
    let state: GitClientState
    /// Hunk index under the user's cursor (0..<file.hunks.count).
    /// Wrapping in @TerminalState keeps it persistent across body
    /// evals; arrow keys mutate it inside .onKeyPress.
    @TerminalState var hunkCursor: Int = 0

    var body: some TerminalView {
        let cursorBinding = $hunkCursor

        VStack {
            if let file = state.selectedFile {
                Text("\(file.path) — \(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
                    .foreground(.cyan)
                    .bold()
                Divider()
                if file.hunks.isEmpty {
                    Text("(no hunks — all changes staged)")
                        .foreground(.gray)
                } else {
                    // Cursor-position indicator above the hunk view.
                    Text("hunk \(min(hunkCursor, file.hunks.count - 1) + 1)/\(file.hunks.count)")
                        .foreground(.yellow)
                    HunkDiffView(
                        hunks: file.hunks,
                        fileName: file.path,
                        visibleCount: 20
                    )
                }
            } else {
                Text("(select a file from the left)")
                    .foreground(.gray)
            }
        }
        .padding(1)
        .border(.rounded)
        .focusable()
        .onKeyPress { key in
            return DiffPane.handleKey(key: key, state: state, cursor: cursorBinding)
        }
    }

    /// Hoisted out of the body closure so it's testable in isolation
    /// (and so the closure stays `@Sendable`-clean — capturing the
    /// state directly inside .onKeyPress would re-trigger reads each
    /// frame).
    static func handleKey(
        key: KeyEvent,
        state: GitClientState,
        cursor: Binding<Int>
    ) -> KeyEventResult {
        guard let file = state.selectedFile, !file.hunks.isEmpty else { return .ignored }
        switch key.key {
        case .down, .character("j"):
            cursor.wrappedValue = min(file.hunks.count - 1, cursor.wrappedValue + 1)
            return .handled
        case .up, .character("k"):
            cursor.wrappedValue = max(0, cursor.wrappedValue - 1)
            return .handled
        case .character("s"):
            state.stageHunk(at: cursor.wrappedValue)
            // Keep cursor in range after a stage shrinks the hunks list.
            cursor.wrappedValue = min(cursor.wrappedValue, max(0, file.hunks.count - 2))
            return .handled
        case .character("u"):
            state.unstageLast()
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Commit bar

/// Bottom pane: PromptInput for the commit message. Pressing
/// Enter while the prompt has focus submits the message via
/// `state.commit(message:)` — that's the canonical SwiftUI
/// PromptInput.onSubmit channel. No `c` chord (it would swallow
/// every `c` typed into the message buffer).
struct CommitBar: TerminalView {
    let state: GitClientState
    /// PromptInput's own bookkeeping — local because no other view
    /// needs to peek at history/cursor. The text BUFFER lives on
    /// the shared GitClientState so a root-level `c` chord can
    /// commit it from anywhere in the app.
    @TerminalState var promptState: PromptInputState = PromptInputState()

    var body: some TerminalView {
        let promptBinding = $promptState
        let stateRef = state
        let messageBinding = Binding<String>(
            get: { stateRef.commitMessage },
            set: { stateRef.commitMessage = $0 }
        )

        VStack {
            Text("Commit message  (Enter to commit)")
                .foreground(.cyan)
                .bold()
            PromptInput(
                text: messageBinding,
                state: promptBinding,
                prompt: "❯",
                heightPolicy: .fixed(3),
                onSubmit: { msg in
                    stateRef.commit(message: msg)
                    stateRef.commitMessage = ""
                }
            )
            if !state.commitLog.isEmpty {
                Divider()
                let recent = Array(state.commitLog.reversed().prefix(3).enumerated()).map {
                    LogRow(id: $0.offset, text: $0.element)
                }
                ForEach(recent) { row in
                    Text(row.text).foreground(.gray)
                }
            }
        }
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Root layout

/// Three-pane root: file tree + diff side-by-side, commit bar
/// underneath. Fixed-ratio HStack until SplitView (the
/// resizable-split primitive) ships.
///
/// No top-level keyboard chords — the SwiftUI-correct routing has
/// PromptInput.onSubmit drive commit (Enter while focused on the
/// prompt) and DiffPane.onKeyPress drive stage / unstage (s/u
/// while focused on the diff). A global `c` chord would have
/// been the shortcut path: it would swallow every `c` typed into
/// the commit message, making the buffer unwritable for any word
/// containing the letter. The framework's focus engine is the
/// right channel; we don't fight it.
struct GitClientApp: TerminalView {
    let state: GitClientState

    var body: some TerminalView {
        let stagedCount = state.stagedHunks.count
        let stagedColor: Color = stagedCount == 0 ? .gray : .green
        VStack {
            HStack {
                FileTreePane(state: state)
                    .frame(width: 32)
                DiffPane(state: state)
            }
            .flexible(.vertical)  // top panes consume leftover height
            CommitBar(state: state)
                .frame(height: 8)
            StatusBar {
                StatusBarSection(.left, spans: [
                    TextSpan("\(stagedCount) staged", foreground: stagedColor),
                ])
                StatusBarSection(.center, spans: [
                    TextSpan("Tab", foreground: .cyan),
                    TextSpan(" focus  "),
                    TextSpan("s", foreground: .cyan),
                    TextSpan(" stage  "),
                    TextSpan("u", foreground: .cyan),
                    TextSpan(" unstage  "),
                    TextSpan("Enter", foreground: .cyan),
                    TextSpan(" commit  "),
                    TextSpan("q", foreground: .cyan),
                    TextSpan(" quit"),
                ])
                StatusBarSection(.right, spans: [
                    TextSpan("\(state.commitLog.count) commits", foreground: .ansi256(245)),
                ])
            }
        }
    }
}
