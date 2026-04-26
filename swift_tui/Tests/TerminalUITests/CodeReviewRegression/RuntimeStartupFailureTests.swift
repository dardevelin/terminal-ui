import Testing
@testable import TerminalUI

// HYP-198 / R7: Terminal.enableRawMode() returns false on syscall
// failure but the runtime ignored the result, proceeding into
// alternate-screen + event loop with input semantics already invalid.
//
// Contract: when raw-mode setup fails, run() throws a typed
// TerminalRuntimeError so app authors can handle non-TTY environments
// (CI, headless) cleanly.

@Suite("Runtime startup — raw-mode failure surfaces as throw")
@MainActor
struct RuntimeStartupFailureTests {

    @Test("run() throws when raw-mode setup fails")
    func runThrowsOnRawModeFailure() async {
        // Inject a failing tcgetattr so enableRawMode returns false.
        let mock = FailingPosixSyscalls()
        mock.tcgetattrShouldFail = true
        let previous = Terminal.posix
        Terminal.posix = mock
        defer { Terminal.posix = previous }

        let runtime = TerminalRuntime(renderMode: .onDemand) {
            Text("hello")
        }
        await #expect(throws: TerminalRuntimeError.rawModeUnavailable) {
            try await runtime.run()
        }
    }
}
