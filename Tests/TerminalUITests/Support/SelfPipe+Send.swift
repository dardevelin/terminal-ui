#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import TerminalUI

extension SelfPipe {
    /// Writes `text` to the pipe, as a terminal sends what is typed.
    func send(_ text: String) {
        writeAll(Array(text.utf8), to: write)
    }
}

/// Writes `bytes` to `descriptor` in one call. File scope, where `write` is
/// the system call and not the member above.
func writeAll(_ bytes: [UInt8], to descriptor: Int32) {
    _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
}
