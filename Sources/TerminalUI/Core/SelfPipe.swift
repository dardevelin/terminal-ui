#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A pipe one thread, or a signal handler, writes a byte to so that another
/// thread's `poll()` wakes.
struct SelfPipe: Sendable {
    let read: Int32
    let write: Int32

    /// Both ends close on exec. The write end never blocks: a byte nobody has
    /// read yet already says what another would, so a full pipe must not
    /// stall the writer — which may be a signal handler.
    init() throws(TerminalRuntimeError) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw .wakePipeUnavailable }
        read = descriptors[0]
        write = descriptors[1]
        _ = fcntl(write, F_SETFL, O_NONBLOCK)
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
    }

    /// Wakes whoever polls ``read``.
    func signal() {
        Self.signal(writeEnd: write)
    }

    /// Writes the wake byte to a pipe's write end. write(2) is
    /// async-signal-safe, so a signal handler may call this.
    static func signal(writeEnd: Int32) {
        writeOneByte(to: writeEnd)
    }

    func close() {
        closeDescriptor(read)
        closeDescriptor(write)
    }
}

// File scope, where the system calls are not shadowed by the members above.
private func writeOneByte(to descriptor: Int32) {
    var byte: UInt8 = 1
    _ = write(descriptor, &byte, 1)
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}
