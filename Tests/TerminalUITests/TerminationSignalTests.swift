#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
@testable import TerminalUI

// SIGINT, SIGTERM and SIGHUP ask a running app to quit rather than killing it
// on the spot: the handler records the signal and writes to the terminate
// pipe, and the app leaves through its normal teardown — terminal restored,
// socket and per-process dir removed, trace summary written. Killed inside
// the handler, the app could only do what is async-signal-safe, and left its
// output behind on every closed terminal tab.
//
// Only the first signal is asked: a second ends the process, so this calls
// the handler once, then forgets the request.

@Suite("A terminating signal asks a running app to quit", .serialized)
struct TerminationSignalTests {

    @Test func theFirstSignalIsRecordedAndWakesTheInputTask() throws {
        let pipe = try SelfPipe()
        defer { pipe.close() }
        Terminal.terminateWakeFD = pipe.write
        defer {
            Terminal.terminateWakeFD = nil
            Terminal.resetTermination()
        }

        _terminalSignalHandler(signum: SIGTERM)

        #expect(Terminal.terminationSignal == SIGTERM)
        var woken = pollfd(fd: pipe.read, events: Int16(POLLIN), revents: 0)
        #expect(poll(&woken, 1, 0) == 1, "the input task was not woken")
    }

    @Test func theInputTaskReportsATerminationRequest() throws {
        let input = try SelfPipe(), resize = try SelfPipe(), terminate = try SelfPipe(), shutdown = try SelfPipe()
        defer { [input, resize, terminate, shutdown].forEach { $0.close() } }
        input.signal()
        resize.signal()
        terminate.signal()
        #expect(StdinByteSource.waitForActivity(input: input.read, resize: resize.read,
                                                terminate: terminate.read, shutdown: shutdown.read) == .terminate)
        shutdown.signal()
        #expect(StdinByteSource.waitForActivity(input: input.read, resize: resize.read,
                                                terminate: terminate.read, shutdown: shutdown.read) == .shutdown)
    }

    // A terminal that goes away hangs up the PTY; an app that is not its
    // controlling process hears of it from stdin alone, and treats it as the
    // SIGHUP it did not receive.

    @Test func aHangUpEndsAsTheTerminalHangingUp() {
        defer { Terminal.resetTermination() }
        Terminal.recordHangUp()
        #expect(Terminal.terminationSignal == SIGHUP)
        #expect(TerminationReason(terminationSignal: Terminal.terminationSignal) == .terminalHungUp)
    }

    @Test func aHangUpDoesNotReplaceASignalAlreadyRecorded() throws {
        // With no pipe to wake, the handler would end the process.
        let pipe = try SelfPipe()
        defer { pipe.close() }
        Terminal.terminateWakeFD = pipe.write
        defer {
            Terminal.terminateWakeFD = nil
            Terminal.resetTermination()
        }
        _terminalSignalHandler(signum: SIGTERM)
        Terminal.recordHangUp()
        #expect(Terminal.terminationSignal == SIGTERM)
    }

    @Test func eachWayOfQuittingHasItsReason() {
        #expect(TerminationReason(terminationSignal: nil) == .quit)
        #expect(TerminationReason(terminationSignal: SIGTERM) == .signal(SIGTERM))
        #expect(TerminationReason(terminationSignal: SIGINT) == .signal(SIGINT))
        #expect(TerminationReason(terminationSignal: SIGHUP) == .terminalHungUp)
    }

    @Test func theConventionalEndingIsWhatTheParentWouldHaveSeen() {
        #expect(ProcessEnding(.quit, .conventional) == .exit(0))
        #expect(ProcessEnding(.signal(SIGTERM), .conventional) == .signal(SIGTERM))
        #expect(ProcessEnding(.terminalHungUp, .conventional) == .signal(SIGHUP))
    }

    @Test func anAppCanEndWithAStatusOfItsOwn() {
        for reason in [TerminationReason.quit, .signal(SIGTERM), .terminalHungUp] {
            #expect(ProcessEnding(reason, .exit(code: 3)) == .exit(3))
        }
    }
}
