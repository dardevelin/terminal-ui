#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization

/// A synchronous input stream that hands ``InputParser`` one byte at a time.
///
/// Decouples InputParser's state machine from stdin. The parser calls
/// `readByte()` synchronously — `nil` means "no byte available right now"
/// (same as `read()` returning 0 under VMIN=0/VTIME=1 raw-mode pacing).
/// Tests inject ArrayByteSource; the runtime uses StdinByteSource.
public protocol ByteSource {
    /// Returns the next byte, or `nil` when none is available right now —
    /// a raw-mode read timeout, an exhausted test array, or a shutdown wake.
    /// `nil` is a pacing signal, not end-of-stream; callers mid-sequence may
    /// retry.
    mutating func readByte() -> UInt8?
}

/// The pipes besides input that wake the input task, each by a byte written
/// to it: SIGWINCH's handler writes to `resize`, a terminating signal's to
/// `terminate`, and the runtime writes to `shutdown` as it quits.
struct InputWakes: Sendable {
    let resize: Int32
    let terminate: Int32
    let shutdown: Int32

    /// No pipes: only input wakes the source. `poll()` ignores a negative
    /// descriptor (POSIX.1-2008).
    static let none = InputWakes(resize: -1, terminate: -1, shutdown: -1)
}

/// The pipes behind ``InputWakes``, as the runtime makes them for its input
/// task. The write ends are the signal handlers' and the runtime's.
struct InputWakePipes: Sendable {
    let resize: SelfPipe
    let terminate: SelfPipe
    let shutdown: SelfPipe

    /// Closes what it made when a later pipe cannot be.
    init() throws(TerminalRuntimeError) {
        resize = try SelfPipe()
        do {
            terminate = try SelfPipe()
        } catch {
            resize.close()
            throw error
        }
        do {
            shutdown = try SelfPipe()
        } catch {
            resize.close()
            terminate.close()
            throw error
        }
    }

    /// The read ends, for the input task's source.
    var wakes: InputWakes {
        InputWakes(resize: resize.read, terminate: terminate.read, shutdown: shutdown.read)
    }

    func close() {
        resize.close()
        terminate.close()
        shutdown.close()
    }
}

/// Runtime source — reads STDIN in raw mode: a chunk at a time when
/// buffered, as the runtime's input task keeps it, a byte at a time otherwise.
///
/// Between events the input task waits in ``waitForActivity()``. A read
/// waits at most 100ms, which the parser relies on part-way through an
/// escape sequence, and ends at once on a wake to stop — a byte on the
/// terminate or shutdown pipe — returning nil. The byte stays in its pipe, so
/// every read after returns at once too, and the parser's retries do not
/// hold the quit up: a paste the terminal never finished kept a Ctrl+C
/// waiting 3s. Task.cancel() can't interrupt a blocked read() on Linux.
public struct StdinByteSource: ByteSource {
    /// Read end of a self-pipe that wakes a blocked readByte(), for a source
    /// made without wakes. The runtime gives its source its pipes instead.
    @available(*, deprecated, message: "The runtime's input source owns its wake pipes and ignores this; only a source made without them reads it.")
    public static var shutdownReadFD: Int32? {
        get {
            let fd = shutdownFD.load(ordering: .acquiring)
            return fd < 0 ? nil : fd
        }
        set { shutdownFD.store(newValue ?? -1, ordering: .releasing) }
    }
    private static let shutdownFD = Atomic<Int32>(-1)

    /// Whether a read ended early — the terminal hung up, or a wake asked
    /// the task to stop — rather than waiting out its timeout. The parser
    /// takes the `nil` such a read returns for a pause, and makes an event
    /// of what it had: one nobody sent. The input task drops it, and its next
    /// ``waitForActivity()`` says what ended the read, since a hang-up and a
    /// wake's byte both stay to be seen.
    private(set) var cutShort = false

    /// The descriptor read: stdin, or a test's terminal.
    private let input: Int32
    private let wakes: InputWakes

    /// How much one read may take. A terminal delivers a keypress, a mouse
    /// report or a paste as one burst; 4 KiB holds a burst, and keeps a
    /// paste to a few reads where a byte at a time made it two system calls
    /// per byte.
    private static let chunkCapacity = 4096

    /// How long a read waits for a byte — the gap that tells a bare Escape
    /// from the start of a sequence, as raw mode's VTIME=1 does.
    private static let readTimeoutMilliseconds: Int32 = 100

    /// 1 for a source made per event, which must not read ahead: the bytes
    /// past its event would go with it.
    private let readSize: Int
    /// Bytes read and not yet handed out.
    private var pending: ArraySlice<UInt8> = []
    /// Every byte read from the input so far, handed out or not.
    private var bytesRead = 0

    /// Creates a stdin source that reads a byte at a time, for a caller that
    /// makes one per event, as ``InputParser/readEvent()`` does.
    public init() {
        self.init(input: STDIN_FILENO)
    }

    /// `buffered` reads everything waiting at once and serves it from memory,
    /// across events — for a caller that keeps the source, as the runtime's
    /// input task does. `wakes` are the pipes that end its waits.
    init(input: Int32, buffered: Bool = false, wakes: InputWakes = .none) {
        self.input = input
        self.readSize = buffered ? Self.chunkCapacity : 1
        let shutdown = wakes.shutdown >= 0 ? wakes.shutdown : Self.shutdownFD.load(ordering: .acquiring)
        self.wakes = InputWakes(resize: wakes.resize, terminate: wakes.terminate, shutdown: shutdown)
    }

    /// Whether bytes already read are waiting to be handed out.
    var hasBufferedInput: Bool {
        !pending.isEmpty
    }

    /// Bytes handed to the parser so far. Those a chunked read took ahead
    /// of it are not counted until it asks for them.
    var bytesConsumed: Int {
        bytesRead - pending.count
    }

    /// One byte from stdin, or `nil` on a read timeout (pacing), a hang-up
    /// or a wake to stop.
    public mutating func readByte() -> UInt8? {
        guard hasBufferedInput || refill() else { return nil }
        return pending.popFirst()
    }

    /// Wait for input as the parser needs and take what is waiting, up to
    /// `readSize`. False on a timeout, or when the read was cut short.
    private mutating func refill() -> Bool {
        switch pollActivity(watchingResize: false, timeoutMilliseconds: Self.readTimeoutMilliseconds) {
        case nil:
            return false
        case .input:
            break
        case .resize, .terminate, .hangUp, .shutdown:
            cutShort = true
            return false
        }
        let chunk = [UInt8](unsafeUninitializedCapacity: readSize) { bytes, count in
            count = max(read(input, bytes.baseAddress, readSize), 0)
        }
        pending = chunk[...]
        bytesRead += chunk.count
        return !chunk.isEmpty
    }
}

/// What woke the input task.
enum InputActivity: Equatable {
    /// A byte is waiting on the input.
    case input
    /// The terminal was resized: SIGWINCH wrote to the resize pipe.
    case resize
    /// A terminating signal asked the app to quit: its handler wrote to the
    /// terminate pipe.
    case terminate
    /// The terminal went away — its window closed, its connection dropped —
    /// and nothing more will arrive on the input.
    case hangUp
    /// Stop reading: the runtime wrote to the shutdown pipe, or a descriptor
    /// reports an error, which polling again would only report again.
    case shutdown
}

extension StdinByteSource {
    /// Blocks until something wakes the input task — with no timeout, so an
    /// idle app's input thread sleeps. The 100ms timeout `readByte()` keeps
    /// is for the parser part-way through an escape sequence, where a bare
    /// Escape is told apart from a sequence's start by the silence after it;
    /// between events there is nothing to tell apart.
    ///
    /// When several are ready: shutdown, then terminate, then hang-up, then
    /// resize, then input. Input already read goes before all of them — the
    /// input task asks only once its buffer is empty, at most a chunk later.
    /// Shutdown's and terminate's bytes stay in their pipes, as in
    /// `readByte()`. A resize empties its pipe, so several signals before the
    /// task looks are one resize. A hang-up goes before input because macOS
    /// reports a hung-up terminal readable as well as hung up, and a read of
    /// it returns nothing: taken for input, it would wake the task at once,
    /// forever. Linux reports the hang-up alone. Keys typed before it have no
    /// screen left to act on.
    func waitForActivity() -> InputActivity {
        pollActivity(watchingResize: true, timeoutMilliseconds: -1) ?? .shutdown
    }

    /// What is ready, by the order ``waitForActivity()`` gives, or nil when
    /// nothing is within the timeout; -1 waits for ever. A read part-way
    /// through a sequence leaves a resize for later. POSIX guarantees pollfd
    /// layout across Darwin and Glibc.
    private func pollActivity(watchingResize: Bool, timeoutMilliseconds: Int32) -> InputActivity? {
        var fds = [
            pollfd(fd: input, events: Int16(POLLIN), revents: 0),
            pollfd(fd: watchingResize ? wakes.resize : -1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakes.terminate, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakes.shutdown, events: Int16(POLLIN), revents: 0),
        ]
        // The task's pool thread blocks the signals the app handles, so they
        // reach it as pipe bytes; a poll() interrupted all the same returns
        // EINTR, whatever SA_RESTART says, and that is not activity.
        var ready: Int32
        repeat {
            ready = poll(&fds, nfds_t(fds.count), timeoutMilliseconds)
        } while ready < 0 && errno == EINTR
        guard ready > 0 else { return nil }

        if fds[3].revents != 0 { return .shutdown }
        if fds[2].revents & Int16(POLLIN) != 0 { return .terminate }
        if fds[0].revents & Int16(POLLHUP) != 0 { return .hangUp }
        if fds[1].revents & Int16(POLLIN) != 0 {
            // One byte per SIGWINCH; one read takes every one written so far.
            var drained = [UInt8](repeating: 0, count: 64)
            _ = read(wakes.resize, &drained, drained.count)
            return .resize
        }
        if fds[0].revents & Int16(POLLIN) != 0 { return .input }
        // A pipe of the runtime's own reporting POLLHUP or POLLERR: polling
        // again would return at once, forever.
        return .shutdown
    }
}

/// Wraps another `ByteSource` and records every consumed byte. The
/// runtime hands one of these to `InputParser.parseEvent` when DEBUG +
/// `events` capture is enabled, then reads `consumed` after the event
/// to log raw bytes alongside the parsed event — a diagnostic for
/// terminal-key bugs where the parsed-event log alone doesn't
/// distinguish "parser bug" from "different bytes than expected."
///
/// Generic over the underlying source so it works with both
/// `StdinByteSource` (runtime) and `ArrayByteSource` (tests).
public struct RecordingByteSource<Source: ByteSource>: ByteSource {
    /// The wrapped source every read is forwarded to.
    public var inner: Source
    /// Every byte returned by `inner` so far, in read order; `nil`
    /// returns are not recorded.
    public var consumed: [UInt8] = []

    /// Wraps a source with an empty recording.
    public init(_ inner: Source) {
        self.inner = inner
    }

    public mutating func readByte() -> UInt8? {
        guard let byte = inner.readByte() else { return nil }
        consumed.append(byte)
        return byte
    }
}

/// Test source — yields bytes from a pre-seeded array in order.
/// Returns nil once exhausted, which the parser treats as "no byte available"
/// (identical to a stdin timeout in raw mode).
///
/// This is the seam that makes ``InputParser`` testable without a PTY: seed
/// the exact byte sequence a terminal would send and drive
/// `InputParser.parseEvent(from:)` directly.
///
/// ```swift
/// var source = ArrayByteSource([0x1B, 0x5B, 0x41])  // ESC [ A
/// let event = InputParser.parseEvent(from: &source)  // .key(.up)
/// ```
public struct ArrayByteSource: ByteSource {
    /// The full seeded byte sequence; never mutated by reads.
    public var bytes: [UInt8]
    /// Index of the next byte `readByte()` will return. Starts at 0; equals
    /// `bytes.count` once the source is exhausted.
    public var position: Int = 0

    /// Creates a source that replays `bytes` in order, then yields `nil`.
    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public mutating func readByte() -> UInt8? {
        guard position < bytes.count else { return nil }
        let byte = bytes[position]
        position += 1
        return byte
    }
}
