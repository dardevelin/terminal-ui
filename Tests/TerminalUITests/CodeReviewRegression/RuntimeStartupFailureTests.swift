import Foundation
import Testing
@testable import TerminalUI
import TerminalUIConfig

// Terminal.enableRawMode() returns false on syscall
// failure but the runtime ignored the result, proceeding into
// alternate-screen + event loop with input semantics already invalid.
//
// Contract: when raw-mode setup fails, run() throws a typed
// TerminalRuntimeError so app authors can handle non-TTY environments
// (CI, headless) cleanly.

// Serialized: the data dir is the test process's, one path for every test
// in it, and only these tests run a runtime.
@Suite("Runtime startup — raw-mode failure surfaces as throw", .serialized)
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

    /// A debug app's `/tmp/terminalui-{hash}-{pid}` dir lives as long as its
    /// run. Made by the runtime's initialiser, it outlived a runtime never
    /// run — every test that made one — and a run that failed to start, an
    /// app launched without a terminal, which threw before the teardown
    /// that removes it: a test run left one in /tmp each time.
    @Test("a run that fails to start leaves no data dir, and a runtime not run makes none")
    func theDataDirLivesWithTheRun() async {
        let mock = FailingPosixSyscalls()
        mock.tcgetattrShouldFail = true
        let previous = Terminal.posix
        Terminal.posix = mock
        defer { Terminal.posix = previous }

        let runtime = TerminalRuntime(renderMode: .onDemand) {
            Text("hello")
        }
        #expect(!FileManager.default.fileExists(atPath: DiagPaths.tmpDataDir), "made before the run")
        await #expect(throws: TerminalRuntimeError.rawModeUnavailable) {
            try await runtime.run()
        }
        #expect(!FileManager.default.fileExists(atPath: DiagPaths.tmpDataDir), "left by the failed start")
    }
}
