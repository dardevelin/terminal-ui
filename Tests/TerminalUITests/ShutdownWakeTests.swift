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
        try? await Task.sleep(for: .milliseconds(200))
        pipes.terminate.signal()

        #expect(await finishes(within: .seconds(1)) { _ = await reader.value })
        #expect(await reader.value, "the read should say it was cut short, and the next wait why")
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
