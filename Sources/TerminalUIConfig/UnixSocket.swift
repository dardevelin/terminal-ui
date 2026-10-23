#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// AF_UNIX stream sockets, as the debug servers listen on them and
/// `swtui ctl` connects to them, and the newline-ended lines they trade.
package enum UnixSocket {
    /// Why a socket could not be opened at a path.
    package enum Failure: Error, Equatable, CustomStringConvertible {
        /// The path does not fit a socket address, which holds `limit`
        /// bytes, its terminating NUL among them: 104 on Darwin, 108 on
        /// Linux. It used to be cut to fit, and the socket opened elsewhere.
        case pathTooLong(limit: Int)
        /// A system call failed with this `errno`.
        case system(Int32)

        package var description: String {
            switch self {
            case .pathTooLong(let limit): "the path is longer than the \(limit - 1) bytes a socket address holds"
            case .system(let code): String(cString: strerror(code))
            }
        }
    }

    /// A non-blocking socket listening at `path`, in place of whatever was
    /// there.
    package static func listening(at path: String, backlog: Int32) throws(Failure) -> Int32 {
        unlink(path)
        let fd = try opened(at: path) { bind($0, $1, $2) }
        guard listen(fd, backlog) == 0 else {
            let error = errno
            close(fd)
            throw .system(error)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    /// A socket connected to `path`, blocking, or nil when nothing accepts
    /// there.
    package static func connected(to path: String) -> Int32? {
        try? opened(at: path) { connect($0, $1, $2) }
    }

    /// Writes `line` and a newline to `fd`, all of it; false when the peer
    /// has gone.
    package static func sendLine(_ line: [UInt8], to fd: Int32) -> Bool {
        let bytes = line + [newline]
        var sent = 0
        while sent < bytes.count {
            let bytesWritten = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, $0.count - sent) }
            if bytesWritten > 0 {
                sent += bytesWritten
            } else if bytesWritten < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// Reads from `fd` until a newline: the bytes before it, or all that
    /// came when the peer closes first. Bytes after the newline are dropped
    /// — one request, one response.
    package static func readLine(from fd: Int32) -> [UInt8] {
        var line: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = read(fd, &chunk, chunk.count)
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead > 0 else { return line }
            if let end = chunk[..<bytesRead].firstIndex(of: newline) {
                return line + chunk[..<end]
            }
            line += chunk[..<bytesRead]
        }
    }

    private static let newline = UInt8(ascii: "\n")

    /// A stream socket on which `call` — `bind` or `connect` — succeeded at
    /// `path`.
    private static func opened(at path: String,
                               _ call: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32) throws(Failure) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < limit else { throw .pathTooLong(limit: limit) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }

        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw .system(errno) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                call(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw .system(error)
        }
        return fd
    }
}
