import Foundation
import Observation
import TerminalUI

// The smallest app that proves the render loop follows state, not just input.
//
// Nothing here schedules a redraw: no timer is declared, no key is pressed, and
// the render mode is chosen by an env var so the same binary exercises both
// arms of the loop. A `.task` ticks a counter, and the screen has to follow —
// which is the SwiftUI contract every app relies on the moment it reads a file,
// shells out, or talks to a network.

@Observable
final class Ticker {
    var count: Int = 0
    var finished: Bool = false
}

nonisolated(unsafe) let ticker = Ticker()

struct AsyncStateScreen: TerminalView {
    let model: Ticker

    var body: some TerminalView {
        VStack {
            Text(" Async state ").bold()
            Divider()
            Text("count=\(model.count)").foreground(.cyan)
            Text(model.finished ? "done=yes" : "done=no").foreground(.gray)
            Divider()
            Text("no timer, no input — the loop follows the state")
                .foreground(.gray)
        }
        .padding(1)
        .task {
            // Bounded so the process exits on its own under a harness that
            // never sends a key.
            for _ in 0..<50 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(60))
                ticker.count += 1
            }
            ticker.finished = true
        }
    }
}

@main
struct AsyncStateApp: TerminalAppProtocol {
    /// `TUI_RENDER_MODE=ondemand` picks the idle-loop arm; anything else uses
    /// the capped default. One binary, both paths under test.
    static var renderMode: RenderMode {
        ProcessInfo.processInfo.environment["TUI_RENDER_MODE"] == "ondemand"
            ? .onDemand
            : .fps60
    }

    static func content() -> some TerminalView {
        AsyncStateScreen(model: ticker)
    }

    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let key) = event,
           key.key == .character("c"), key.modifiers.contains(.ctrl) {
            return false
        }
        return true
    }
}
