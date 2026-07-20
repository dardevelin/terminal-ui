import Foundation
import Observation
import TerminalUI

/// One file in the working tree that has changes vs the index.
/// Status maps to git's two-letter index/worktree pair, simplified.
enum FileStatus: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case untracked = "??"
}

/// A staged-or-unstaged hunk in a file. The `id` is stable across
/// stage/unstage moves so TreeView's selection survives the move.
struct StagedHunk: Identifiable, Sendable {
    let id: Int
    let fileID: Int
    let oldStart: Int
    let newStart: Int
    let lines: [HunkDiff.Line]
}

/// A file's changes — list of hunks and a status.
struct FileChange: Identifiable, Sendable {
    let id: Int
    let path: String
    let status: FileStatus
    var hunks: [HunkDiff.Hunk]
}

/// File-tree row — rendered by TreeView. Identifiable across
/// stage/commit cycles so TreeView's selection persists. The
/// `children` field is unused (we don't nest by directory in v1)
/// but TreeView's generic API needs it.
struct FileRow: Identifiable, Sendable {
    let id: String
    let label: String
    let children: [FileRow]?

    static func make(_ change: FileChange) -> FileRow {
        FileRow(
            id: "file-\(change.id)",
            label: "\(change.status.rawValue) \(change.path)",
            children: nil
        )
    }
}

/// One commit-log row in the recent-commits panel. ForEach
/// requires Identifiable elements; the index doubles as the id
/// since the log is append-only and rows never reorder.
struct LogRow: Identifiable, Sendable {
    let id: Int
    let text: String
}

/// Application state. `@Observable` + `final class` per the
/// SwiftUI ergonomics rule (Storybook + Demo pattern). Mutating
/// fields here triggers the surgical body-evaluation flow.
/// All callers run on the main actor at runtime; we don't need
/// type-level @MainActor isolation, which would block use of
/// this state from `nonisolated(unsafe)` top-level singletons
/// (the Storybook/Demo idiom).
@Observable
final class GitClientState {
    /// Files with unstaged changes. Mutated when the user stages a
    /// hunk (the hunk leaves its file and joins `stagedHunks`).
    var files: [FileChange]
    /// Hunks the user has staged. Cleared on commit.
    var stagedHunks: [StagedHunk]
    /// Commit log — every successful commit appends here.
    var commitLog: [String]
    /// Currently-focused file in the tree. `nil` means "no
    /// selection" (empty working tree). When non-nil, the diff
    /// pane shows this file's hunks.
    var selectedFileID: String?
    /// Commit message buffer — hoisted to the top-level state so a
    /// root-level `c` chord (anywhere in the app) can commit
    /// against the same buffer the CommitBar's PromptInput is
    /// driving. Without this hoist, Cmd-style global shortcuts
    /// can't see the prompt's text.
    var commitMessage: String

    init(files: [FileChange]) {
        self.files = files
        self.stagedHunks = []
        self.commitLog = []
        self.selectedFileID = files.first.map { "file-\($0.id)" }
        self.commitMessage = ""
    }

    /// File matching the current selection, or `nil` if cleared.
    var selectedFile: FileChange? {
        guard let id = selectedFileID else { return nil }
        return files.first(where: { "file-\($0.id)" == id })
    }

    /// Stage one hunk by index within `selectedFile.hunks`. Removes
    /// the hunk from the file and appends to `stagedHunks`. No-op if
    /// the index is out of range or the selection is nil.
    func stageHunk(at idx: Int) {
        guard let fileID = selectedFileID,
              let fIdx = files.firstIndex(where: { "file-\($0.id)" == fileID }),
              idx >= 0 && idx < files[fIdx].hunks.count
        else { return }
        let hunk = files[fIdx].hunks.remove(at: idx)
        let staged = StagedHunk(
            id: stagedHunks.count + 1,
            fileID: files[fIdx].id,
            oldStart: hunk.oldStart,
            newStart: hunk.newStart,
            lines: hunk.lines
        )
        stagedHunks.append(staged)
    }

    /// Unstage the most recently staged hunk back to its file. We
    /// don't reorder — the file just re-grows by one hunk at the end.
    func unstageLast() {
        guard let staged = stagedHunks.popLast(),
              let fIdx = files.firstIndex(where: { $0.id == staged.fileID })
        else { return }
        let hunk = HunkDiff.Hunk(
            oldStart: staged.oldStart,
            newStart: staged.newStart,
            lines: staged.lines
        )
        files[fIdx].hunks.append(hunk)
    }

    /// Commit all staged hunks with `message`. Appends a one-line
    /// summary to `commitLog` and clears `stagedHunks`. No-op when
    /// nothing is staged or message is empty (whitespace-only is
    /// also a no-op so accidental Ctrl+C-style commits don't slip
    /// through).
    func commit(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stagedHunks.isEmpty, !trimmed.isEmpty else { return }
        commitLog.append("[\(commitLog.count + 1)] \(trimmed) (\(stagedHunks.count) hunks)")
        stagedHunks.removeAll()
    }
}
