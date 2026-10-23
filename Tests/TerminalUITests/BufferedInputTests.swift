#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
@testable import TerminalUI

// The runtime's input task keeps one buffered source for the life of the
// app: a read takes everything waiting, and the bytes past one event serve
// the next, so a paste costs a few system calls rather than two per byte.

@Suite("Input is read in chunks")
struct BufferedInputTests {

    @Test func oneReadTakesEverythingWaiting() throws {
        let terminal = try SelfPipe()
        defer { terminal.close() }
        terminal.send("hello")
        var source = StdinByteSource(input: terminal.read, buffered: true)

        #expect(source.readByte() == UInt8(ascii: "h"))
        var waiting = pollfd(fd: terminal.read, events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 0) == 0, "the rest was left in the pipe, to be read a byte at a time")
        #expect((0..<4).compactMap { _ in source.readByte() } == Array("ello".utf8))
    }

    @Test func bytesReadForOneEventServeTheNext() throws {
        let terminal = try SelfPipe()
        defer { terminal.close() }
        terminal.send("ab\u{1B}[A")
        var source = StdinByteSource(input: terminal.read, buffered: true)

        let keys = (0..<3).compactMap { _ -> Key? in
            guard case .key(let key) = InputParser.readEvent(from: &source) else { return nil }
            return key.key
        }
        #expect(keys == [.character("a"), .character("b"), .up])
        #expect(!source.hasBufferedInput)
    }
}
