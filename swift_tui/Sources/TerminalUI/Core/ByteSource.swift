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
/// Returns nil when the 100ms VTIME poll expires with no input.
public struct StdinByteSource: ByteSource {
    public init() {}

    public mutating func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &byte, 1)
        return bytesRead == 1 ? byte : nil
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
