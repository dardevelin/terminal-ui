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
struct ToolCall: Identifiable, Sendable {
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
}

/// One entry in the chat transcript.
enum Entry: Identifiable, Sendable {
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
struct Message: Identifiable, Sendable {
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
    enum Health: Sendable {
        case online
        case busy
        case offline
        case failed
    }

    let id: Int
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

/// Which pane owns the keyboard.
enum Pane: Sendable {
    case transcript
    case prompt
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
    var focus: Pane = .prompt

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

    var doneTodoCount: Int {
        todos.filter { if case .done = $0.status { true } else { false } }.count
    }
}
