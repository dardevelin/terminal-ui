#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Synchronization

/// Lines of text from the network — a TCP connection or UDP datagrams —
/// read on a thread of its own and decoded into fixes.
///
/// A socket read blocks in the kernel, so it never runs on the cooperative
/// pool, where it would hold a thread for the life of the stream. The
/// thread polls with a short timeout, so cancelling the stream — the
/// iterating task ending — is noticed within it and the socket closed.
enum LineSocket {
    typealias Endpoint = NMEALocationProvider.Endpoint

    /// How long one poll waits before the thread looks for cancellation.
    static let pollMilliseconds: Int32 = 200
    /// How long a connection may take before it is given up.
    static let connectTimeout: Duration = .seconds(10)
    /// The longest line kept: an NMEA sentence is at most 82 bytes and a
    /// gpsd report a few hundred, so anything longer is not either.
    static let maximumLineLength = 4_096
    static let readChunk = 4_096

    /// A stream of the fixes `decode` makes of each line, carrying `state`
    /// from one line to the next. `greeting`, when given, is sent once a
    /// TCP connection opens.
    static func stream<State: Sendable>(
        _ endpoint: Endpoint, greeting: String?, state: State,
        decode: @escaping @Sendable (inout State, String) -> LocationFix?
    ) -> AsyncThrowingStream<LocationFix, any Error> {
        // A live position matters only as it is now: while the reader of
        // the stream is busy — a reroute awaited — fixes are not queued up
        // to be replayed after, only the latest kept.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancelled = CancellationFlag()
            continuation.onTermination = { _ in cancelled.cancel() }
            let thread = Thread {
                var state = state
                do {
                    try run(endpoint, greeting: greeting, cancelled: cancelled) { line in
                        if let fix = decode(&state, line) { continuation.yield(fix) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "TerminalUIMaps.LineSocket"
            thread.start()
        }
    }

    /// Set from the stream's termination, read by its thread.
    final class CancellationFlag: Sendable {
        private let flag = Atomic(false)
        func cancel() { flag.store(true, ordering: .relaxed) }
        var isCancelled: Bool { flag.load(ordering: .relaxed) }
    }

    static func run(_ endpoint: Endpoint, greeting: String?, cancelled: CancellationFlag,
                    line handle: (String) -> Void) throws {
        let descriptor: Int32
        switch endpoint {
        case .tcp(let host, let port):
            descriptor = try connect(host: host, port: port, cancelled: cancelled)
        case .udp(let port):
            descriptor = try listen(port: port)
        }
        defer { close(descriptor) }
        if let greeting, case .tcp = endpoint {
            try send(Array(greeting.utf8), to: descriptor)
        }
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: readChunk)
        while !cancelled.isCancelled {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw LocationError.connection("poll failed: \(String(cString: strerror(errno)))")
            }
            guard ready > 0 else { continue }
            let bytesRead = read(descriptor, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw LocationError.connection("read failed: \(String(cString: strerror(errno)))")
            }
            guard bytesRead > 0 else {
                if case .udp = endpoint { continue }
                throw LocationError.connection("the server closed the connection")
            }
            pending += chunk[..<bytesRead]
            if case .udp = endpoint { pending.append(newline) }
            while let end = pending.firstIndex(of: newline) {
                var line = pending[..<end]
                if line.last == carriageReturn { line = line.dropLast() }
                handle(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(...end)
            }
            if pending.count > maximumLineLength { pending.removeAll() }
        }
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let datagramType = Int32(SOCK_DGRAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    private static let datagramType = SOCK_DGRAM
    #endif

    private static func failure(_ what: String, _ code: Int32 = errno) -> LocationError {
        .connection("\(what): \(String(cString: strerror(code)))")
    }

    /// A connected TCP socket to the first of the host's addresses that
    /// answers, non-blocking so the connection can wait in `poll` and be
    /// abandoned on cancellation.
    static func connect(host: String, port: UInt16, cancelled: CancellationFlag) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw LocationError.connection("cannot resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(list) }
        var lastError = LocationError.connection("no address for \(host)")
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            candidate = address.pointee.ai_next
            let descriptor = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard descriptor >= 0 else {
                lastError = failure("socket")
                continue
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            if systemConnect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                return descriptor
            }
            guard errno == EINPROGRESS else {
                lastError = failure("cannot connect to \(host):\(port)")
                close(descriptor)
                continue
            }
            if let error = waitForConnection(descriptor, cancelled: cancelled) {
                lastError = error.isEmpty ? .connection("connecting to \(host):\(port) timed out")
                    : .connection("cannot connect to \(host):\(port): \(error)")
                close(descriptor)
                continue
            }
            return descriptor
        }
        throw lastError
    }

    /// Nil once connected; the reason otherwise, empty for a timeout.
    private static func waitForConnection(_ descriptor: Int32, cancelled: CancellationFlag) -> String? {
        let deadline = ContinuousClock.now + connectTimeout
        while ContinuousClock.now < deadline {
            if cancelled.isCancelled { return "cancelled" }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&poller, 1, pollMilliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { continue }
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length)
            return code == 0 ? nil : String(cString: strerror(code))
        }
        return ""
    }

    /// A UDP socket bound to `port` on every IPv4 interface, where a phone
    /// on the same network sends its datagrams.
    static func listen(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, datagramType, 0)
        guard descriptor >= 0 else { throw failure("socket") }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = failure("cannot listen on UDP port \(port)")
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private static func send(_ bytes: [UInt8], to descriptor: Int32) throws {
        var sent = 0
        while sent < bytes.count {
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&poller, 1, pollMilliseconds)
            let bytesWritten = bytes.withUnsafeBytes { buffer in
                systemSend(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
            }
            if bytesWritten > 0 {
                sent += bytesWritten
            } else if bytesWritten < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw failure("write failed")
            }
        }
    }

    /// `send` with `MSG_NOSIGNAL` (POSIX.1-2008), as the runtime's own
    /// socket writes are: a plain `write` to a socket whose peer has gone
    /// raises SIGPIPE, which ends the process inside the call.
    private static func systemSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.send(descriptor, bytes, count, Int32(MSG_NOSIGNAL))
        #else
        Darwin.send(descriptor, bytes, count, MSG_NOSIGNAL)
        #endif
    }

    private static func systemConnect(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>?,
                                      _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.connect(descriptor, address, length)
        #else
        Darwin.connect(descriptor, address, length)
        #endif
    }
}
