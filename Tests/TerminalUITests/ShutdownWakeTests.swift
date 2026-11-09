#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
@testable import TerminalUI

// Quitting writes one byte to the shutdown pipe to wake the input task, and
// the runtime then waits for that task before it closes the pipe. The task
// may be part-way through an escape sequence whose parser retries on nil, so
// the wake has to hold for every read that follows, not only the first: the
// byte stays in the pipe. Reading it away left each retry waiting out a full
// 100ms poll of stdin. A terminating signal's byte on the terminate pipe
// ends a read the same way: a bracketed paste the terminal never finished
// held a Ctrl+C up for the 3s the parser gives a paste's end to arrive.

@Suite("A wake to stop holds for every read that follows")
struct ShutdownWakeTests {

    @Test func everyReadAfterAShutdownWakeReturnsNilAtOnce() throws {
        let terminal = try SelfPipe()
        let pipes = try InputWakePipes()
        defer {
            terminal.close()
            pipes.close()
        }
        pipes.shutdown.signal()

        var source = StdinByteSource(input: terminal.read, wakes: pipes.wakes)
        for _ in 0..<5 {
            #expect(source.readByte() == nil)
        }
        #expect(source.cutShort)
        #expect(source.waitForActivity() == .shutdown, "the next wait says why")

        var stillWaking = pollfd(fd: pipes.shutdown.read, events: Int16(POLLIN), revents: 0)
        #expect(poll(&stillWaking, 1, 0) == 1, "the wake byte must stay in the pipe")
    }

    @Test func aTerminateEndsAPasteTheTerminalNeverFinished() async throws {
        let terminal = try SelfPipe()
        let pipes = try InputWakePipes()
        defer {
            terminal.close()
            pipes.close()
        }
        terminal.send("\u{1B}[200~half a paste")
        let reader = BlockingThread(name: "test read") {
            var source = StdinByteSource(input: terminal.read, buffered: true, wakes: pipes.wakes)
            _ = InputParser.readEvent(from: &source)
            return source.cutShort && source.waitForActivity() == .terminate
        }
        // The terminate is meant for a read inside the paste, waiting for its
        // end, and the parser gives a paste 3 s of wall-clock time: it must
        // arrive within them. So it is sent from a thread of its own, once
        // the reader has taken the half paste in. Sent from a task, it waited
        // on the cooperative pool, which on CI's three-core runner under the
        // Thread Sanitizer, shared with every test in the run, let the 3 s
        // run out first; the paste then ended on its own, not cut short.
        let terminator = BlockingThread(name: "test terminate") {
            Self.waitUntilTaken(from: terminal)
            pipes.terminate.signal()
        }

        // Only a hang waits this long; that the terminate, not the paste's
        // 3 s limit, ended the read is what the next expectation checks.
        #expect(await finishes(within: eventualLimit) { await terminator.value })
        #expect(await finishes(within: eventualLimit) { _ = await reader.value })
        #expect(await reader.value, "the read should say it was cut short, and the next wait why")
    }

    /// Blocks until nothing written to `pipe` is waiting to be read: on a
    /// thread of its own, where blocking belongs.
    private static func waitUntilTaken(from pipe: SelfPipe) {
        var pending = pollfd(fd: pipe.read, events: Int16(POLLIN), revents: 0)
        while poll(&pending, 1, 0) == 1 {
            pending.revents = 0
            usleep(PollPause.microseconds)
        }
    }

    /// How long the terminator waits between looks at the pipe.
    private enum PollPause {
        static let microseconds: UInt32 = 1_000
    }

    // A hang-up part-way through an escape sequence ends the read early, and
    // the parser makes a key of what it had: one nobody pressed. The read
    // says it was cut short, so the input task drops that key, and its next
    // wait reports the hang-up.
    @Test func aReadThatFindsTheTerminalHungUpSaysSo() throws {
        let terminal = try #require(PseudoTerminal())
        defer { terminal.closeReplica() }
        terminal.hangUp()

        var source = StdinByteSource(input: terminal.replica)
        #expect(source.readByte() == nil)
        #expect(source.cutShort)
        #expect(source.waitForActivity() == .hangUp)
        #expect(!StdinByteSource(input: terminal.replica).cutShort, "another source has not seen it")
    }
}
