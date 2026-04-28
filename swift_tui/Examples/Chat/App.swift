import Foundation
import TerminalUI

/// Top-level singleton — Storybook / Demo / GitClient pattern. Safe
/// because all reads happen on @MainActor at body-eval time.
nonisolated(unsafe) let chatState = ChatState(messages: Fixtures.initialMessages())

@main
struct ChatMain: TerminalAppProtocol {

    /// One timer drains pending bot replies, one per tick. 200ms
    /// feels conversational without making the smoke harness wait
    /// too long; the bot-reply smoke case sleeps 400ms which is two
    /// safety ticks.
    static var timers: [TerminalTimer] {[
        TerminalTimer("bot", every: .milliseconds(200)),
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        switch event {
        case .key(let k):
            // `q` quits ONLY when the prompt buffer is empty.
            // Otherwise the letter must reach the focused
            // PromptInput and be inserted as text — see
            // `feedback_no_global_chord_for_text_input_letters.md`
            // for the full rationale (a global `q` chord would
            // make every word containing 'q' unwriteable).
            //
            // Esc is the unconditional escape hatch — by terminal
            // convention it always exits modal/raw apps.
            if case .character("q") = k.key, chatState.draft.isEmpty {
                return false
            }
            if case .escape = k.key {
                return false
            }
        case .timer(let name):
            if name == "bot" {
                chatState.tickBot()
            }
        default:
            break
        }
        return true
    }

    static func content() -> some TerminalView {
        ChatApp(state: chatState)
    }
}
