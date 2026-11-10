#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Synchronization
import Testing
import TerminalUIConfig

// The debug servers and `swtui ctl` open AF_UNIX sockets one way, here. A
// path longer than an address holds was cut to fit, so a server bound, and
// a client connected, somewhere other than the path it was given — and a
// server that could not listen said nothing.
@Suite("Unix sockets")
struct UnixSocketTests {

    /// The `errno` a connect to `path` fails with, or 0 when it connects.
    private static func connectError(to path: String) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func temporaryPath() -> String {
        "/tmp/terminalui-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    @Test func aLineGoesBothWays() throws {
        let path = Self.temporaryPath()
        let listener = try UnixSocket.listening(at: path, backlog: 1)
        defer {
            close(listener)
            unlink(path)
        }
        let client = try #require(UnixSocket.connected(to: path))
        defer { close(client) }
        var server: Int32 = -1
        while server < 0 {
            server = accept(listener, nil, nil)
        }
        defer { close(server) }

        #expect(UnixSocket.sendLine(Array("ping".utf8), to: client))
        #expect(UnixSocket.readLine(from: server) == Array("ping".utf8))
    }

    /// A client that finds the socket's path finds something listening. The
    /// path was bound before it listened, and `swtui ctl` run as an app
    /// started — under Thread Sanitizer, on a busy machine — found the file
    /// in between and was refused. A watcher connects the moment the path
    /// appears, over many opens; none may be refused.
    @Test func aPathThatExistsIsListening() throws {
        let rounds = 200
        let paths = (0..<rounds).map { _ in Self.temporaryPath() }
        // The watcher's first connect to each round's path, made the moment
        // the path appears; the server keeps listening until it is made.
        let results = Mutex([Int32?](repeating: nil, count: rounds))
        let watcher = Thread {
            for (round, path) in paths.enumerated() {
                while access(path, F_OK) != 0 {}
                let error = Self.connectError(to: path)
                results.withLock { $0[round] = error }
            }
        }
        watcher.start()
        for (round, path) in paths.enumerated() {
            let listener = try UnixSocket.listening(at: path, backlog: 1)
            while results.withLock({ $0[round] }) == nil {}
            unlink(path)
            close(listener)
        }
        let refused = results.withLock { $0 }.filter { $0 == ECONNREFUSED }.count
        #expect(refused == 0, "\(refused) of \(rounds) paths refused the first client that found them")
    }

    @Test func listeningLeavesNothingButItsPath() throws {
        let path = Self.temporaryPath()
        let listener = try UnixSocket.listening(at: path, backlog: 1)
        defer {
            close(listener)
            unlink(path)
        }
        #expect(access(path, F_OK) == 0)
        #expect(access(path + UnixSocket.unpublishedSuffix, F_OK) != 0, "the unpublished name was left behind")
    }

    @Test func nothingListeningIsNoConnection() {
        #expect(UnixSocket.connected(to: Self.temporaryPath()) == nil)
    }

    @Test func aPathLongerThanAnAddressIsRefusedNotCut() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(UnixSocket.connected(to: path) == nil)
        #expect {
            _ = try UnixSocket.listening(at: path, backlog: 1)
        } throws: { error in
            guard case .pathTooLong = error as? UnixSocket.Failure else { return false }
            return true
        }
    }
}
