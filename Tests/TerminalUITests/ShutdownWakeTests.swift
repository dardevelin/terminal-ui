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
// 100ms poll of stdin.

@Suite("A shutdown wake holds for every read that follows", .serialized)
struct ShutdownWakeTests {

    @Test func everyReadAfterTheWakeReturnsNilAtOnce() throws {
        let shutdown = try SelfPipe()
        defer {
            StdinByteSource.shutdownReadFD = nil
            shutdown.close()
        }
        StdinByteSource.shutdownReadFD = shutdown.read
        shutdown.signal()

        var source = StdinByteSource()
        for _ in 0..<5 {
            #expect(source.readByte() == nil)
        }

        var stillWaking = pollfd(fd: shutdown.read, events: Int16(POLLIN), revents: 0)
        #expect(poll(&stillWaking, 1, 0) == 1, "the wake byte must stay in the pipe")
    }

    // A hang-up part-way through an escape sequence ends the read early, and
    // the parser makes a key of what it had: one nobody pressed. The read
    // says the terminal hung up, so the input task drops that key.
    @Test func aReadThatFindsTheTerminalHungUpSaysSo() throws {
        let shutdown = try SelfPipe()
        let terminal = try #require(PseudoTerminal())
        defer {
            StdinByteSource.shutdownReadFD = nil
            terminal.closeReplica()
            shutdown.close()
        }
        StdinByteSource.shutdownReadFD = shutdown.read
        terminal.hangUp()

        var source = StdinByteSource(input: terminal.replica)
        #expect(source.readByte() == nil)
        #expect(source.hungUp)
        #expect(!StdinByteSource(input: terminal.replica).hungUp, "another source has not seen it")
    }
}
