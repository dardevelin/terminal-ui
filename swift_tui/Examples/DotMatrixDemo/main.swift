import Foundation
import Observation
import TerminalUI

// MARK: - Morse Encoding

enum Morse {
    enum Symbol { case dot, dash }

    static let table: [Character: [Symbol]] = [
        "A": [.dot, .dash],           "B": [.dash, .dot, .dot, .dot],
        "C": [.dash, .dot, .dash, .dot], "D": [.dash, .dot, .dot],
        "E": [.dot],                  "F": [.dot, .dot, .dash, .dot],
        "G": [.dash, .dash, .dot],    "H": [.dot, .dot, .dot, .dot],
        "I": [.dot, .dot],            "J": [.dot, .dash, .dash, .dash],
        "K": [.dash, .dot, .dash],    "L": [.dot, .dash, .dot, .dot],
        "M": [.dash, .dash],          "N": [.dash, .dot],
        "O": [.dash, .dash, .dash],   "P": [.dot, .dash, .dash, .dot],
        "Q": [.dash, .dash, .dot, .dash], "R": [.dot, .dash, .dot],
        "S": [.dot, .dot, .dot],      "T": [.dash],
        "U": [.dot, .dot, .dash],     "V": [.dot, .dot, .dot, .dash],
        "W": [.dot, .dash, .dash],    "X": [.dash, .dot, .dot, .dash],
        "Y": [.dash, .dot, .dash, .dash], "Z": [.dash, .dash, .dot, .dot],
        "0": [.dash, .dash, .dash, .dash, .dash],
        "1": [.dot, .dash, .dash, .dash, .dash],
        "2": [.dot, .dot, .dash, .dash, .dash],
        "3": [.dot, .dot, .dot, .dash, .dash],
        "4": [.dot, .dot, .dot, .dot, .dash],
        "5": [.dot, .dot, .dot, .dot, .dot],
        "6": [.dash, .dot, .dot, .dot, .dot],
        "7": [.dash, .dash, .dot, .dot, .dot],
        "8": [.dash, .dash, .dash, .dot, .dot],
        "9": [.dash, .dash, .dash, .dash, .dot],
    ]

    /// Encode text into a linear tape of colored cells.
    /// Each cell is either a signal (dot/dash colored) or a gap.
    /// Uses ITU timing: dot=1, dash=3, symbol-gap=1, letter-gap=3, word-gap=7.
    enum Cell {
        case signal(Symbol)
        case gap
    }

    static func encode(_ text: String) -> [Cell] {
        var tape: [Cell] = []
        var prevWasLetter = false

        for char in text.uppercased() {
            if char == " " {
                // Word gap: 7 units (we already have 3 from letter gap if prev was letter)
                let extra = prevWasLetter ? 4 : 7
                for _ in 0..<extra { tape.append(.gap) }
                prevWasLetter = false
                continue
            }

            guard let symbols = table[char] else { continue }

            // Letter gap before this letter (except first)
            if prevWasLetter {
                for _ in 0..<3 { tape.append(.gap) }
            }

            for (j, sym) in symbols.enumerated() {
                // Symbol gap
                if j > 0 { tape.append(.gap) }

                let width = sym == .dot ? 1 : 3
                for _ in 0..<width { tape.append(.signal(sym)) }
            }

            prevWasLetter = true
        }

        return tape
    }

    static func textRepresentation(_ text: String) -> String {
        text.uppercased().compactMap { char -> String? in
            if char == " " { return " / " }
            guard let syms = table[char] else { return nil }
            return syms.map { $0 == .dot ? "\u{00B7}" : "\u{2014}" }.joined()
        }.joined(separator: "  ")
    }
}

// MARK: - Morse Signal View

/// Renders a scrolling Morse signal as large bullet dots.
/// Two rows tall — dots are single ● , dashes are ●●● (3 wide).
/// White dots, red dashes, dark background.
struct MorseSignal: TerminalView {
    let tape: [Morse.Cell]
    let scrollOffset: Int
    let width: Int

    private let dotChar = "\u{25CF}"    // ●
    private let dimChar = "\u{00B7}"    // ·
    private let dotFg = Color.rgb(218, 218, 214)
    private let dashFg = Color.rgb(200, 60, 60)
    private let dimFg = Color.ansi256(238)
    private let bg = Color.rgb(23, 24, 26)

    var body: some TerminalView {
        Text(spans: renderSignal())
            .background(bg)
    }

    private func renderSignal() -> [TextSpan] {
        let tapeLen = tape.count
        guard tapeLen > 0 else {
            return [TextSpan(String(repeating: " ", count: width))]
        }

        var spans: [TextSpan] = []

        // Row 1: top of signal (dashes extend here, dots don't)
        for col in 0..<width {
            let idx = (scrollOffset + col) % tapeLen
            switch tape[idx] {
            case .signal(.dash):
                spans.append(TextSpan(dotChar, foreground: dashFg))
            case .signal(.dot):
                spans.append(TextSpan(dimChar, foreground: dimFg))
            case .gap:
                spans.append(TextSpan(" "))
            }
        }

        spans.append(TextSpan("\n"))

        // Row 2: center — both dots and dashes visible here
        for col in 0..<width {
            let idx = (scrollOffset + col) % tapeLen
            switch tape[idx] {
            case .signal(.dash):
                spans.append(TextSpan(dotChar, foreground: dashFg))
            case .signal(.dot):
                spans.append(TextSpan(dotChar, foreground: dotFg))
            case .gap:
                spans.append(TextSpan(" "))
            }
        }

        spans.append(TextSpan("\n"))

        // Row 3: bottom of signal (dashes extend here, dots don't)
        for col in 0..<width {
            let idx = (scrollOffset + col) % tapeLen
            switch tape[idx] {
            case .signal(.dash):
                spans.append(TextSpan(dotChar, foreground: dashFg))
            case .signal(.dot):
                spans.append(TextSpan(dimChar, foreground: dimFg))
            case .gap:
                spans.append(TextSpan(" "))
            }
        }

        return spans
    }
}

// MARK: - App State

@Observable
final class AppState {
    var inputText: String = "HELLO WORLD"
    var promptState: PromptInputState = PromptInputState()
    var scrollOffset: Int = 0
    var paused: Bool = false
}

nonisolated(unsafe) let state = AppState()

// MARK: - App

@main struct DotMatrixDemo: TerminalAppProtocol {
    static var renderMode: RenderMode { .onDemand }

    static var timers: [TerminalTimer] {[
        TerminalTimer("scroll", every: .milliseconds(80)),
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        switch event {
        case .key(let k):
            switch k.key {
            case .character("c") where k.modifiers.contains(.ctrl): return false
            case .character("q") where k.modifiers.contains(.ctrl): return false
            case .character("p") where k.modifiers.contains(.ctrl):
                state.paused.toggle()
            default: break
            }
        case .timer(let name):
            if name == "scroll" && !state.paused {
                state.scrollOffset += 1
            }
        default: break
        }
        return true
    }

    static func content() -> some TerminalView {
        GeometryReader { size in
            VStack {
                // Morse signal — the main visual, edge to edge
                MorseSignal(
                    tape: Morse.encode(state.inputText),
                    scrollOffset: state.scrollOffset,
                    width: size.width
                )

                Text("")

                // Input field — full width, grows downward
                PromptInput(
                    text: Binding(
                        get: { state.inputText },
                        set: {
                            state.inputText = $0
                            state.scrollOffset = 0
                        }
                    ),
                    state: Binding(
                        get: { state.promptState },
                        set: { state.promptState = $0 }
                    ),
                    prompt: "\u{276F}",
                    badge: state.paused ? "PAUSED" : "LIVE",
                    maxVisibleLines: 4,
                    onSubmit: { _ in
                        state.scrollOffset = 0
                    }
                )

                Text("")

                // Morse subtitle
                HStack {
                    Text("  ")
                    Text(Morse.textRepresentation(state.inputText))
                        .foreground(.ansi256(242))
                }

                Spacer()

                // Bottom hint
                HStack {
                    Text("  tab: focus  enter: submit  opt+enter: newline  ctrl+p: pause  ctrl+c: quit")
                        .foreground(.ansi256(238))
                    Spacer()
                }
            }
        }
    }
}
