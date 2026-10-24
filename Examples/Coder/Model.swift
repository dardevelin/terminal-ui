import Foundation
import Observation
import TerminalUI

/// Who produced a transcript entry.
enum Author: Sendable {
    case user
    case assistant
}

/// Outcome of a tool call, which drives its icon and accent color.
enum ToolState: Sendable {
    case pending
    case success
    case failure
}

/// A tool invocation shown as a card inside the transcript.
struct ToolCall: Identifiable, Sendable, Equatable {
    let id: Int
    /// Display name, e.g. "Read", "Bash", "Edit".
    let name: String
    /// One-line summary of the arguments, e.g. a path or a command.
    let summary: String
    let state: ToolState
    /// Result body. Rendered in the card when present.
    let output: String?
    /// The change an editing tool made, shown in place of `output`.
    var diff: [DiffLine]? = nil
    /// The edited file's language, from the path `summary` starts with.
    var language: String? {
        FileExcerpt.language(ofPath: String(summary.prefix { $0 != " " }))
    }
    /// The file text a reading tool returned, shown in place of `output`.
    var excerpt: FileExcerpt? = nil
}

/// Part of a file, as a reading tool returns it.
struct FileExcerpt: Sendable, Equatable {
    let path: String
    /// The file's line number for the first line of `code`.
    let firstLine: Int
    let code: String

    var language: String? { Self.language(ofPath: path) }

    /// A path's extension, which is the name lexers are registered under.
    static func language(ofPath path: String) -> String? {
        guard path.contains(".") else { return nil }
        return path.split(separator: ".").last.map { String($0).lowercased() }
    }
}

/// One entry in the chat transcript.
enum Entry: Identifiable, Sendable, Equatable {
    case message(Message)
    case tool(ToolCall)

    var id: Int {
        switch self {
        case .message(let m): m.id
        case .tool(let t): t.id
        }
    }
}

/// A chat message. `body` is markdown, rendered by `MarkdownView`.
struct Message: Identifiable, Sendable, Equatable {
    let id: Int
    let author: Author
    let body: String
    /// Wall-clock label, e.g. "14:02". Fixed in fixtures so the demo
    /// renders identically on every run — the PTY harness compares
    /// cell grids and a live clock would make every frame differ.
    let timestamp: String
}

/// A status-bearing resource in the sidebar (LSP server, MCP server).
struct Resource: Identifiable, Sendable {
    /// Which sidebar section lists it.
    enum Kind: Sendable {
        case lsp
        case mcp
    }

    enum Health: Sendable {
        case online
        case busy
        case offline
        case failed
    }

    let id: Int
    let kind: Kind
    let name: String
    let health: Health
    /// Trailing detail, e.g. "12 tools" or "starting…".
    let detail: String
}

/// One file's change: its path and the diff, from which the counts follow.
struct FileChange: Identifiable, Sendable, Equatable {
    let path: String
    let lines: [DiffLine]

    var added: Int { lines.count { $0.kind == .added } }
    var removed: Int { lines.count { $0.kind == .removed } }
    var language: String? { FileExcerpt.language(ofPath: path) }
    /// A path names one file in a source, and stays its name across
    /// refreshes, so the selection does too.
    var id: String { path }
}

/// Whose changes the review shows. It opens on what is uncommitted, as
/// Claude Code's `/diff` panel does. That and the last commit are read from
/// `git` in the directory Coder runs in; the session's are the edits its
/// transcript shows.
enum ReviewSource: String, CaseIterable, Identifiable, Sendable {
    case uncommitted = "Uncommitted"
    case session = "This session"
    case lastCommit = "Last commit"

    var id: Self { self }
}

/// A task in the todo pill's list.
struct Todo: Identifiable, Sendable {
    enum Status: Sendable {
        case pending
        case inProgress
        case done
    }

    let id: Int
    let title: String
    let status: Status
}

/// Application state. `@Observable` + `final class` so mutations drive
/// the surgical body-evaluation path. Deliberately *not* `@MainActor`,
/// matching the Demo / GitClient / Chat convention — type-level
/// isolation would block the top-level `nonisolated(unsafe) let`
/// singleton the `@main` entry point needs.
@Observable
final class CoderState {
    var sessionTitle: String
    var workingDirectory: String
    var modelName: String
    var providerName: String
    var contextUsed: Int
    var contextWindow: Int
    var cost: Double

    var entries: [Entry]
    var resources: [Resource]
    /// Every source's changes; the sidebar lists the session's.
    var changes: [ReviewSource: [FileChange]]
    /// Why the git sources are empty, when it is not that nothing changed.
    var gitProblem: String?
    var todos: [Todo]

    var draft: String
    /// The composer's cursor, scroll and history.
    var promptState = PromptInputState()

    /// The transcript entry the reader selected — Crush's chat cursor. Nil
    /// until the reader moves it, and the latest entry stands in.
    var selectedEntryID: Int?
    /// Where the transcript is told to scroll: the selection, each time a
    /// key moves it.
    var transcriptPosition: Int?
    /// Tool results the reader expanded past the cap.
    var expandedResults: Set<Int> = []

    /// Whether the settings dialog is up.
    var showsSettings = false
    /// The setting it holds: the review covers the whole window rather than
    /// the sidebar's side of it.
    var fullScreenReview = false
    /// Whether the diff review is open, whose changes it shows, and which
    /// of them is selected.
    var showsReview = false
    var reviewSource = ReviewSource.uncommitted
    var reviewFileID: String?
    /// Whether the review's file list is unfolded above the diff.
    var reviewListExpanded = true

    /// The files this session touched.
    var files: [FileChange] { changes[.session] ?? [] }
    /// What the review lists.
    var reviewChanges: [FileChange] { changes[reviewSource] ?? [] }
    /// The change the review shows: the selected one, or the first.
    var reviewedFile: FileChange? {
        reviewChanges.first { $0.id == reviewFileID } ?? reviewChanges.first
    }

    /// How often the open review reads git again: often enough that a file
    /// an agent writes appears while the user is looking, as in Claude
    /// Code, and seldom enough that git's cost stays out of sight.
    static let gitRefreshInterval = Duration.seconds(1)

    /// Reads the git sources again, while the review is open. A `git` call
    /// blocks until git exits, so it runs on a thread of its own: on the
    /// cooperative pool it would hold one of a few threads every second.
    @MainActor
    func refreshFromGit() async {
        let directory = FileManager.default.currentDirectoryPath
        let snapshot = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: Git.snapshot(of: directory)) }
        }
        switch snapshot {
        case .success(let snapshot):
            // Assigned only when they differ: an unchanged tree redraws
            // nothing.
            if changes[.uncommitted] != snapshot.uncommitted { changes[.uncommitted] = snapshot.uncommitted }
            if changes[.lastCommit] != snapshot.lastCommit { changes[.lastCommit] = snapshot.lastCommit }
            if gitProblem != nil { gitProblem = nil }
        case .failure(let problem):
            if gitProblem != problem.message { gitProblem = problem.message }
        }
    }

    /// Opens the review on `file`, or on the uncommitted changes, where
    /// `/diff` opens.
    func openReview(on file: FileChange? = nil) {
        reviewSource = file == nil ? .uncommitted : .session
        reviewFileID = file?.id
        showsReview = true
    }

    /// The next source, or the one before: ←/→ in the review's list.
    func switchReviewSource(by step: Int) {
        let sources = ReviewSource.allCases
        let index = sources.firstIndex(of: reviewSource) ?? 0
        reviewSource = sources[(index + step + sources.count) % sources.count]
        reviewFileID = nil
    }

    /// Ctrl+R: opens the review, or closes it.
    func toggleReview() {
        if showsReview {
            showsReview = false
        } else {
            openReview()
        }
    }

    /// Puts a question about `file` in the composer and returns to it.
    func ask(about file: FileChange) {
        draft = "About \(file.path): "
        showsReview = false
    }

    init(
        sessionTitle: String,
        workingDirectory: String,
        modelName: String,
        providerName: String,
        contextUsed: Int,
        contextWindow: Int,
        cost: Double,
        entries: [Entry],
        resources: [Resource],
        changes: [ReviewSource: [FileChange]],
        todos: [Todo],
        draft: String = ""
    ) {
        self.sessionTitle = sessionTitle
        self.workingDirectory = workingDirectory
        self.modelName = modelName
        self.providerName = providerName
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
        self.cost = cost
        self.entries = entries
        self.resources = resources
        self.changes = changes
        self.todos = todos
        self.draft = draft
    }

    /// Percentage of the context window consumed, 0–100.
    var contextPercent: Int {
        guard contextWindow > 0 else { return 0 }
        return Int((Double(contextUsed) / Double(contextWindow)) * 100)
    }

    /// Token count abbreviated to K/M, matching how coding agents report it.
    var contextLabel: String {
        Self.abbreviate(contextUsed)
    }

    static func abbreviate(_ count: Int) -> String {
        switch count {
        case 1_000_000...:
            let millions = Double(count) / 1_000_000
            return trimZero(String(format: "%.1f", millions)) + "M"
        case 1_000...:
            let thousands = Double(count) / 1_000
            return trimZero(String(format: "%.1f", thousands)) + "K"
        default:
            return String(count)
        }
    }

    private static func trimZero(_ value: String) -> String {
        value.hasSuffix(".0") ? String(value.dropLast(2)) : value
    }

    /// Add what the user sent to the transcript. Coder runs no agent, so
    /// nothing answers it.
    func send(_ text: String) {
        let id = (entries.map(\.id).max() ?? 0) + 1
        entries.append(.message(Message(id: id, author: .user, body: text,
                                        timestamp: Self.clock.string(from: Date()))))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The selected entry, or the latest while the reader has chosen none.
    var selection: Int? {
        selectedEntryID ?? entries.last?.id
    }

    /// Move the selection by `step` entries and bring it into sight —
    /// Crush's Shift+↑/↓.
    func selectEntry(by step: Int) {
        guard let current = index(of: selection) else { return }
        let next = entries[max(0, min(entries.count - 1, current + step))].id
        selectedEntryID = next
        transcriptPosition = next
    }

    /// The reader clicked an entry: it is selected, and a capped result
    /// opens or closes, as in Crush.
    func click(_ id: Int) {
        selectedEntryID = id
        toggleResult(id)
    }

    /// Open the selected entry's result past its cap, or close it — Crush's
    /// Space.
    func toggleSelectedResult() {
        selection.map(toggleResult)
    }

    /// An entry with nothing held back draws the same opened or not, so
    /// any entry may be toggled.
    private func toggleResult(_ id: Int) {
        if expandedResults.remove(id) == nil {
            expandedResults.insert(id)
        }
    }

    private func index(of id: Int?) -> Int? {
        id.flatMap { id in entries.firstIndex { $0.id == id } }
    }

    /// The transcript reports the entries in sight. A selection scrolled out
    /// of them passes to the nearest one still in sight, so Space acts on
    /// something the reader can see — Crush moves its cursor the same way.
    func entriesInSight(_ visible: [Int]) {
        guard let first = visible.first, let last = visible.last,
              let current = selection, !visible.contains(current),
              let currentIndex = index(of: current), let firstIndex = index(of: first) else { return }
        selectedEntryID = currentIndex < firstIndex ? first : last
    }

    var doneTodoCount: Int {
        todos.filter { if case .done = $0.status { true } else { false } }.count
    }
}
