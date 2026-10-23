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

    // What a test driving the app through its terminal waits on: every byte
    // it wrote has become an event. Bytes read ahead have not, yet.
    @Test func itCountsTheBytesHandedOutNotTheBytesReadAhead() throws {
        let terminal = try SelfPipe()
        defer { terminal.close() }
        terminal.send("ab\u{1B}[A")
        var source = StdinByteSource(input: terminal.read, buffered: true)
        #expect(source.bytesConsumed == 0)

        _ = InputParser.readEvent(from: &source)
        #expect(source.bytesConsumed == 1)
        _ = InputParser.readEvent(from: &source)
        _ = InputParser.readEvent(from: &source)
        #expect(source.bytesConsumed == 5)
    }
}

// A test that types into the app's terminal or resizes it, rather than
// driving the app over the control socket, gets no reply that says the app
// took the input in. The queue records what it has taken from the terminal,
// under the lock it holds the events with: a record that includes a byte or
// a size means its event is queued.
@Suite("The event queue records what it has taken from the terminal")
struct TerminalInputTakenTests {

    @Test func bytesThatMadeNoEventAreCountedToo() {
        let queue = EventQueue(wake: WakeSignal())
        queue.pushTerminalInput(.key(KeyEvent(key: .up)), bytesConsumed: 3)
        queue.pushTerminalInput(nil, bytesConsumed: 5)
        #expect(queue.terminalInputTaken.bytes == 5)
        #expect(queue.drain().count == 1)
    }

    @Test func drainingKeepsTheRecord() {
        let queue = EventQueue(wake: WakeSignal())
        queue.pushTerminalInput(.key(KeyEvent(key: .up)), bytesConsumed: 3)
        _ = queue.drain()
        #expect(queue.terminalInputTaken.bytes == 3)
    }

    @Test func aResizeRecordsTheNewSize() {
        let queue = EventQueue(wake: WakeSignal())
        queue.pushTerminalInput(.resize(100, 30), bytesConsumed: 0)
        #expect(queue.terminalInputTaken == TerminalInputTaken(bytes: 0, cols: 100, rows: 30))
    }
}
