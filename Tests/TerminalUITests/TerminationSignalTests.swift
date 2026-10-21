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
}
