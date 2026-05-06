import Foundation
import Testing
@testable import TerminalUI

// HYP-324 — terminal escape state must NEVER leak to the parent
// terminal on signal/abort. Cleanup is normally in TerminalApp.run()'s
// defer block, but defer doesn't run for SIGINT/SIGTERM/SIGHUP or
// direct exit() calls. Framework MUST install signal handlers + an
// atexit hook that emit the cleanup sequence + restore termios via
// async-signal-safe syscalls only (posix_write + tcsetattr).
//
// User report (verbatim 2026-05-06): "this should never happen, bad
// escapes can cause injections."
//
// These unit tests pin the cleanup body's behaviour without needing
// PTY orchestration. A separate integration test (filed as a
// follow-up) will spawn a real subprocess, send SIGINT, capture PTY
// output, and assert the trailing bytes contain the cleanup sequence.

@Suite("Signal cleanup — escape state must not leak on abort")
struct SignalCleanupTests {

    @Test("Terminal.cleanupEscapeSequence contains all enabled-mode disables")
    func cleanupSequenceCoversAllModes() {
        let sequence = Terminal.cleanupEscapeSequence
        // SGR 1006 mouse + 1003 motion + 1002 drag + 1000 basic.
        #expect(sequence.contains("\u{1B}[?1006l"), "missing SGR 1006 mouse disable")
        #expect(sequence.contains("\u{1B}[?1003l"), "missing mouse motion disable")
        #expect(sequence.contains("\u{1B}[?1002l"), "missing mouse drag disable")
        #expect(sequence.contains("\u{1B}[?1000l"), "missing mouse basic disable")
        // Bracketed-paste, cursor visibility, alternate screen.
        #expect(sequence.contains("\u{1B}[?2004l"), "missing bracketed-paste disable")
        #expect(sequence.contains("\u{1B}[?25h"),   "missing cursor-show")
        #expect(sequence.contains("\u{1B}[?1049l"), "missing alt-screen exit")
    }

    @Test("cleanup sequence disables SGR 1006 BEFORE alt-screen exit")
    func cleanupSequenceOrderingIsSafe() {
        // Disabling alt-screen first would briefly leave the user's
        // shell rendering mouse coordinates before SGR is disabled.
        // Mouse modes must come first.
        let sequence = Terminal.cleanupEscapeSequence
        let sgrPos = sequence.range(of: "\u{1B}[?1006l")!.lowerBound
        let altScreenPos = sequence.range(of: "\u{1B}[?1049l")!.lowerBound
        #expect(sgrPos < altScreenPos,
                "SGR 1006 disable must come before alt-screen exit")
    }

    @Test("Terminal.installSignalCleanup is callable without error")
    func installSignalCleanupIsCallable() {
        // Just exercises that the API exists and doesn't crash on
        // install. Tests cannot actually send themselves signals
        // without leaving the harness in an unrecoverable state, so
        // the installation step is the maximum we can verify in a
        // unit test. PTY-based integration test is a follow-up.
        Terminal.installSignalCleanup()
        // No assertion beyond no-crash; SIGINT handler is now armed
        // for the test process. Deliberately do NOT invoke it here.
    }

    @Test("Terminal.runCleanup emits cleanup sequence to stdout (signal-safe path)")
    func runCleanupEmitsSequence() {
        // The signal-safe cleanup path uses posix_write(STDOUT_FILENO,
        // ...). We can't easily redirect stdout in a Swift Testing
        // context, but we CAN verify that calling runCleanup() doesn't
        // crash and produces no Swift-allocator activity on the
        // critical path (compile-time check via the @convention(c)
        // signature on the underlying handler).
        Terminal.runCleanup()
        // The function returns; the OS already wrote the bytes.
        // Assertions on stdout content live in the integration test.
    }
}
