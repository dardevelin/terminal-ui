import Foundation
import Observation
import TerminalUI

/// Who sent the message — drives both the colour the row is rendered
/// in and the "name" label that prefixes the body. `you` is the
/// special-case marker for the local user.
enum MessageKind: String, Sendable, Equatable {
    case alice
    case bob
    case bot
    case you

    /// Foreground colour for this kind's name label. Distinct enough
    /// that scanning the message list visually you can pick out who
    /// said what without reading the label.
    var color: Color {
        switch self {
        case .alice: return .cyan
        case .bob:   return .magenta
        case .bot:   return .yellow
        case .you:   return .green
        }
    }
}

/// One message in the conversation. `id` is monotonic — the message
/// list is append-only and ids never reorder, so each row can be tagged
/// `.id(_:)` with it.
struct Message: Identifiable, Sendable, Equatable {
    let id: Int
    let kind: MessageKind
    let timestamp: String  // pre-formatted "HH:MM" — no Date math in render
    let body: String
}

/// Application state. `@Observable` + `final class` per Storybook /
/// Demo / GitClient convention — no `@MainActor` so the top-level
/// `nonisolated(unsafe) let` singleton can initialise it.
@Observable
final class ChatState {
    /// All messages, oldest-first. Auto-scroll pins to `messages.last`.
    var messages: [Message]
    /// PromptInput buffer — hoisted to the state so the root-level
    /// `q-on-empty-prompt` chord can read its emptiness without
    /// reaching into PromptInput's internals.
    var draft: String
    /// Bot replies queued by the user's most recent submit. The
    /// timer tick drains this list and appends each reply as a new
    /// message — keeps the bot-reply path off the keystroke handler
    /// (which mustn't sleep).
    var pendingBotReplies: [String]

    init(messages: [Message] = []) {
        self.messages = messages
        self.draft = ""
        self.pendingBotReplies = []
    }

    /// Append a user message and queue a canned bot reply for the
    /// next timer tick. Trims the buffer; whitespace-only submits
    /// are silently dropped so an accidental Enter doesn't insert
    /// a blank line.
    func sendUserMessage() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let next = (messages.last?.id ?? 0) + 1
        messages.append(Message(
            id: next,
            kind: .you,
            timestamp: nowHHMM(),
            body: trimmed
        ))
        pendingBotReplies.append(Fixtures.botReply(for: trimmed))
        draft = ""
    }

    /// Drain ONE pending bot reply if any. Called from the timer
    /// tick — one reply per tick means a flurry of user messages
    /// produces a paced flurry of bot replies, not a wall of
    /// concurrent appends.
    func tickBot() {
        guard !pendingBotReplies.isEmpty else { return }
        let reply = pendingBotReplies.removeFirst()
        let next = (messages.last?.id ?? 0) + 1
        messages.append(Message(
            id: next,
            kind: .bot,
            timestamp: nowHHMM(),
            body: reply
        ))
    }
}

/// Local-time HH:MM, zero-padded. Avoids pulling in DateFormatter
/// for what is a 5-character string.
private func nowHHMM() -> String {
    let now = Date()
    let cal = Calendar(identifier: .gregorian)
    let h = cal.component(.hour, from: now)
    let m = cal.component(.minute, from: now)
    return String(format: "%02d:%02d", h, m)
}
