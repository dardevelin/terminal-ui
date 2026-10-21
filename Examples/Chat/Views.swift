import Foundation
import Observation
import TerminalUI

// MARK: - One message row

/// `name HH:MM body` styled per kind. Foreground colour on the
/// name label is what lets the user scan who's speaking; the body
/// stays in default colour so long messages don't look noisy.
struct MessageRow: TerminalView {
    let message: Message

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(padded(message.kind.rawValue, to: 5))
                .foreground(message.kind.color)
                .bold()
            Text(message.timestamp)
                .foreground(.gray)
            Text(message.body)
        }
    }

    /// Right-pad with spaces so columns align; the stack's spacing
    /// provides the gaps. The longest fixture kind is `alice` (5).
    private func padded(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}

// MARK: - Message list pane

/// ScrollView wrapping ForEach over the message list. The latest
/// message is `.id`-tagged and the ScrollView is `.scrollPosition`-
/// targeted at it, so any new append auto-scrolls into view.
///
/// Marked `.scrollable()` to opt the ScrollView into focus + arrow-
/// key handling, so the user can scroll back through history with
/// Up/Down when this pane has focus.
struct MessageList: TerminalView {
    let state: ChatState

    var body: some TerminalView {
        // `.scrollable()` is defined on `ScrollView` directly (not the
        // generic `TerminalView`), so it MUST come before any other
        // TerminalView-flavoured modifier. The anchor and border/padding
        // wrap the result. Anchored to the bottom, the list opens on the
        // latest message and follows new ones in until the reader scrolls
        // back through the history.
        return ScrollView {
            ForEach(state.messages) { msg in
                MessageRow(message: msg)
                    .id(msg.id)
            }
        }
        .scrollable()
        .defaultScrollAnchor(.bottom)
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Prompt bar

/// PromptInput at the bottom — Enter submits via `onSubmit`,
/// flowing through `state.sendUserMessage` which clears the buffer
/// and queues a bot reply. The text binding is hoisted to
/// `state.draft` so the root chord can read its emptiness.
struct ChatBar: TerminalView {
    let state: ChatState
    @TerminalState var promptState: PromptInputState = PromptInputState()

    var body: some TerminalView {
        let stateRef = state
        let promptBinding = $promptState
        let textBinding = Binding<String>(
            get: { stateRef.draft },
            set: { stateRef.draft = $0 }
        )

        return PromptInput(
            text: textBinding,
            state: promptBinding,
            prompt: "❯",
            heightPolicy: .fixed(3),
            onSubmit: { _ in
                stateRef.sendUserMessage()
            }
        )
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Root layout

/// Three-piece root: scrollable message list, prompt bar, status
/// bar. `.flexible(.vertical)` on the message list means it
/// consumes leftover height so the prompt + status bar always sit
/// at the bottom regardless of terminal size.
struct ChatApp: TerminalView {
    let state: ChatState

    var body: some TerminalView {
        VStack {
            MessageList(state: state)
                .flexible(.vertical)
            ChatBar(state: state)
                .frame(height: 5)
            StatusBar {
                StatusBarSection(.left, spans: [
                    TextSpan("[", foreground: .ansi256(245)),
                    TextSpan(Fixtures.channelName, foreground: .cyan),
                    TextSpan("]", foreground: .ansi256(245)),
                    TextSpan(" "),
                    TextSpan(Fixtures.activeUsers(), foreground: .ansi256(245)),
                ])
                StatusBarSection(.right, spans: [
                    TextSpan("Enter", foreground: .cyan),
                    TextSpan(" send  "),
                    TextSpan("q", foreground: .cyan),
                    TextSpan(" quit (empty prompt)"),
                ])
            }
        }
    }
}
