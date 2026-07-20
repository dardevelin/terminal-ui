import TerminalUI

/// Initial conversation + canned bot replies. The 12 fixture
/// messages give the demo scrollable content on the very first
/// frame so a smoke case doesn't need to wait for user typing
/// before the message list has anything in it.
enum Fixtures {

    static func initialMessages() -> [Message] {
        return [
            Message(id:  1, kind: .alice, timestamp: "10:42", body: "Hi everyone, anyone around?"),
            Message(id:  2, kind: .bob,   timestamp: "10:43", body: "Welcome to the channel."),
            Message(id:  3, kind: .alice, timestamp: "10:44", body: "Has anyone tried the new build?"),
            Message(id:  4, kind: .bot,   timestamp: "10:45", body: "Build 2026.04.28 is out — release notes pinned."),
            Message(id:  5, kind: .alice, timestamp: "10:46", body: "Nice — does it have the syntax highlighter?"),
            Message(id:  6, kind: .bob,   timestamp: "10:47", body: "Yes, both stateless + stateful tokenization."),
            Message(id:  7, kind: .bob,   timestamp: "10:47", body: "Multiline strings carry across lines now."),
            Message(id:  8, kind: .alice, timestamp: "10:48", body: "Great — I'll wire it into the diff view."),
            Message(id:  9, kind: .bot,   timestamp: "10:49", body: "Reminder: 3 user-decision tickets are awaiting input."),
            Message(id: 10, kind: .alice, timestamp: "10:50", body: "Looking now — thanks for the ping."),
            Message(id: 11, kind: .bob,   timestamp: "10:51", body: "Type below to send a message; the bot will echo back."),
            Message(id: 12, kind: .bot,   timestamp: "10:52", body: "Ready when you are."),
        ]
    }

    /// Bot reply table — keyword match against the user's message.
    /// First match wins; default is a generic ack so every user
    /// submit produces a visible reply (smoke case
    /// `chat.bot_reply_appears` depends on this).
    static func botReply(for userMessage: String) -> String {
        let lower = userMessage.lowercased()
        if lower.contains("ping") {
            return "pong"
        }
        if lower.contains("hello") || lower.contains("hi") {
            return "Hi there! How can I help?"
        }
        if lower.contains("help") {
            return "Type a message and press Enter; I echo back."
        }
        if lower.contains("anchor") {
            return "Anchored. (test reply)"
        }
        return "Got it: \"\(userMessage)\""
    }

    /// Active-user list rendered in the status bar — names only,
    /// space-separated by dots. Hardcoded for the v1 demo since we
    /// don't track real presence.
    static func activeUsers() -> String {
        "alice • bob • bot"
    }

    /// Channel name shown in the title bar + status bar.
    static let channelName = "#general"
}
