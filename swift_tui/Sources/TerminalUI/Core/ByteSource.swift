#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Decouples InputParser's state machine from stdin. The parser calls
// `readByte()` synchronously — `nil` means "no byte available right now"
// (same as `read()` returning 0 under VMIN=0/VTIME=1 raw-mode pacing).
// Tests inject ArrayByteSource; the runtime uses StdinByteSource.
public protocol ByteSource {
    mutating func readByte() -> UInt8?
}

/// Runtime source — reads one byte at a time from STDIN in raw mode.
///
/// Normally relies on VTIME=1 (100ms poll) in raw mode for interruptibility.
/// If `shutdownReadFD` is set, `poll()` watches both STDIN and the
/// shutdown pipe; writing any byte to the pipe wakes a blocked readByte()
/// and causes it to return nil, letting the caller check Task.isCancelled.
///
/// Without the shutdown pipe, quitting would hang up to one VTIME interval
/// because Task.cancel() can't interrupt a blocked read() syscall on Linux.
public struct StdinByteSource: ByteSource {
    /// Read end of a self-pipe used to wake a blocked readByte() at shutdown.
    /// Shared state: TerminalApp.run() opens the pipe and stores the read end
    /// here before starting the input task, then writes to the write end on
    /// exit. nil when no runtime is active (tests, or before run() starts).
    nonisolated(unsafe) public static var shutdownReadFD: Int32?

    public init() {}

    public mutating func readByte() -> UInt8? {
        if let shutdownFD = Self.shutdownReadFD {
            return readByteWithShutdown(shutdownFD: shutdownFD)
        }
        var byte: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &byte, 1)
        return bytesRead == 1 ? byte : nil
    }

    /// poll() wakes on either stdin input OR the shutdown pipe.
    /// POSIX guarantees pollfd layout across Darwin and Glibc.
    private func readByteWithShutdown(shutdownFD: Int32) -> UInt8? {
        var fds = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: shutdownFD,   events: Int16(POLLIN), revents: 0),
        ]

        // Timeout matches VTIME=1 (100ms) so callers that loop on nil still
        // make progress on cancellation checks without a pipe write.
        let ready = poll(&fds, nfds_t(fds.count), 100)
        guard ready > 0 else { return nil }

        // Shutdown pipe readable → drop the wake byte, return nil to caller.
        if fds[1].revents & Int16(POLLIN) != 0 {
            var discard: UInt8 = 0
            _ = read(shutdownFD, &discard, 1)
            return nil
        }

        if fds[0].revents & Int16(POLLIN) != 0 {
            var byte: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &byte, 1)
            return bytesRead == 1 ? byte : nil
        }
        return nil
    }
}

/// Wraps another `ByteSource` and records every consumed byte. The
/// runtime hands one of these to `InputParser.parseEvent` when DEBUG +
/// `events` capture is enabled, then reads `consumed` after the event
/// to log raw bytes alongside the parsed event. HYP-337 — diagnostic
/// for terminal-key bugs where the parsed-event log alone doesn't
/// distinguish "parser bug" from "different bytes than expected."
///
/// Generic over the underlying source so it works with both
/// `StdinByteSource` (runtime) and `ArrayByteSource` (tests).
public struct RecordingByteSource<Source: ByteSource>: ByteSource {
    public var inner: Source
    public var consumed: [UInt8] = []

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
public struct ArrayByteSource: ByteSource {
    public var bytes: [UInt8]
    public var position: Int = 0

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
