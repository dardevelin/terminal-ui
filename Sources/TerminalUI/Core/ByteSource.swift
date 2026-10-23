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

/// Runtime source — reads STDIN in raw mode: a chunk at a time when
/// buffered, as the runtime's input task keeps it, a byte at a time otherwise.
///
/// Between events the runtime waits in
/// ``waitForActivity(input:resize:terminate:shutdown:)``.
/// A read waits at most 100ms (VTIME=1, or the same timeout on `poll()`),
/// which the parser relies on part-way through an escape sequence. If
/// `shutdownReadFD` is set, `poll()` watches both STDIN and the shutdown
/// pipe; writing any byte to the pipe wakes a blocked readByte() and causes
/// it to return nil — Task.cancel() can't interrupt a blocked read() syscall
/// on Linux.
public struct StdinByteSource: ByteSource {
    /// Read end of a self-pipe used to wake a blocked readByte() at shutdown.
    /// Shared state: TerminalApp.run() opens the pipe and stores the read end
    /// here before starting the input task, then writes to the write end on
    /// exit. nil when no runtime is active (tests, or before run() starts).
    /// The input task reads it on its own thread while the runtime sets and
    /// clears it, so it is held atomically.
    public static var shutdownReadFD: Int32? {
        get {
            let fd = shutdownFD.load(ordering: .acquiring)
            return fd < 0 ? nil : fd
        }
        set { shutdownFD.store(newValue ?? -1, ordering: .releasing) }
    }
    private static let shutdownFD = Atomic<Int32>(-1)

    /// Whether a read found the terminal hung up. The parser takes the `nil`
    /// that read returns for a timeout, so the input task asks here before it
    /// queues what the parser made of a sequence the hang-up cut short.
    private(set) var hungUp = false

    /// The descriptor read: stdin, or a test's terminal.
    private let input: Int32

    /// How much one read may take. A terminal delivers a keypress, a mouse
    /// report or a paste as one burst; 4 KiB holds a burst, and keeps a
    /// paste to a few reads where a byte at a time made it two system calls
    /// per byte.
    private static let chunkCapacity = 4096

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
    /// input task does.
    init(input: Int32, buffered: Bool = false) {
        self.input = input
        self.readSize = buffered ? Self.chunkCapacity : 1
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

    /// One byte from stdin, or `nil` on a poll/read timeout (pacing) or a
    /// shutdown-pipe wake.
    public mutating func readByte() -> UInt8? {
        guard hasBufferedInput || refill() else { return nil }
        return pending.popFirst()
    }

    /// Wait for input as the parser needs — at most 100ms — and take what
    /// is waiting, up to `readSize`. False on a timeout, a hang-up or a
    /// shutdown wake.
    private mutating func refill() -> Bool {
        if let shutdownFD = Self.shutdownReadFD, !waitForInput(shutdownFD: shutdownFD) {
            return false
        }
        let chunk = [UInt8](unsafeUninitializedCapacity: readSize) { bytes, count in
            count = max(read(input, bytes.baseAddress, readSize), 0)
        }
        pending = chunk[...]
        bytesRead += chunk.count
        return !chunk.isEmpty
    }

    /// poll() wakes on either stdin input OR the shutdown pipe.
    /// POSIX guarantees pollfd layout across Darwin and Glibc.
    private mutating func waitForInput(shutdownFD: Int32) -> Bool {
        var fds = [
            pollfd(fd: input, events: Int16(POLLIN), revents: 0),
            pollfd(fd: shutdownFD, events: Int16(POLLIN), revents: 0),
        ]

        // Timeout matches VTIME=1 (100ms) so callers that loop on nil still
        // make progress on cancellation checks without a pipe write.
        let ready = poll(&fds, nfds_t(fds.count), 100)
        guard ready > 0 else { return false }

        // The wake byte stays in the pipe: every later poll returns at once,
        // so a sequence the parser is part-way through gives up its retries
        // immediately instead of waiting out a 100ms poll for each, and the
        // input task reaches its cancellation check without delay.
        if fds[1].revents & Int16(POLLIN) != 0 {
            return false
        }

        if fds[0].revents & Int16(POLLHUP) != 0 {
            hungUp = true
            return false
        }
        return fds[0].revents & Int16(POLLIN) != 0
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
    /// Shutdown's byte stays in the pipe, as in `readByte()`. A resize empties its pipe, so several signals before the
    /// task looks are one resize. A hang-up goes before input because macOS
    /// reports a hung-up terminal readable as well as hung up, and a read of
    /// it returns nothing: taken for input, it would wake the task at once,
    /// forever. Linux reports the hang-up alone. Keys typed before it have no
    /// screen left to act on.
    static func waitForActivity(input: Int32 = STDIN_FILENO, resize: Int32,
                                terminate: Int32, shutdown: Int32) -> InputActivity {
        var fds = [
            pollfd(fd: input, events: Int16(POLLIN), revents: 0),
            pollfd(fd: resize, events: Int16(POLLIN), revents: 0),
            pollfd(fd: terminate, events: Int16(POLLIN), revents: 0),
            pollfd(fd: shutdown, events: Int16(POLLIN), revents: 0),
        ]
        // The task's pool thread blocks the signals the app handles, so they
        // reach it as pipe bytes; a poll() interrupted all the same returns
        // EINTR, whatever SA_RESTART says, and that is not activity.
        while poll(&fds, nfds_t(fds.count), -1) < 0 && errno == EINTR {}

        if fds[3].revents != 0 { return .shutdown }
        if fds[2].revents & Int16(POLLIN) != 0 { return .terminate }
        if fds[0].revents & Int16(POLLHUP) != 0 { return .hangUp }
        if fds[1].revents & Int16(POLLIN) != 0 {
            // One byte per SIGWINCH; one read takes every one written so far.
            var drained = [UInt8](repeating: 0, count: 64)
            _ = read(resize, &drained, drained.count)
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
