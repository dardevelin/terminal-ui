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
    /// The file text a reading tool returned, shown in place of `output`.
    var excerpt: FileExcerpt? = nil
}

/// Part of a file, as a reading tool returns it.
struct FileExcerpt: Sendable, Equatable {
    let path: String
    /// The file's line number for the first line of `code`.
    let firstLine: Int
    let code: String

    /// The extension, which is the name lexers are registered under.
    var language: String? {
        path.split(separator: ".").last.map { String($0).lowercased() }
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

/// A file the session has touched, with its diff stat.
struct TouchedFile: Identifiable, Sendable {
    let id: Int
    let path: String
    let added: Int
    let removed: Int
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
    var files: [TouchedFile]
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
        files: [TouchedFile],
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
        self.files = files
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
