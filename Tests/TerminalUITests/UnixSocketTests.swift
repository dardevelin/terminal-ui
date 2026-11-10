#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Testing
@testable import TerminalUI
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
    /// in between and was refused; on the old code, nearly every new socket
    /// refused its first finder. Each round, a watcher connects the moment
    /// the round's path appears, and the server stops listening only after.
    ///
    /// Both sides run on threads of their own and hand over by semaphore:
    /// a test spinning on a cooperative pool thread starved CI's three-core
    /// runner of the threads the tests beside it needed.
    @Test func aPathThatExistsIsListening() async throws {
        let rounds = 200
        let paths = (0..<rounds).map { _ in Self.temporaryPath() }
        let attempted = DispatchSemaphore(value: 0)
        let watcher = BlockingThread(name: "socket watcher") { () -> [Int32] in
            paths.map { path in
                // Polled, not waited for: the moment the path appears is the
                // one a racing client meets.
                while access(path, F_OK) != 0 {}
                let error = Self.connectError(to: path)
                attempted.signal()
                return error
            }
        }
        let server = BlockingThread(name: "socket server") { () -> String? in
            for path in paths {
                guard let listener = try? UnixSocket.listening(at: path, backlog: 1) else { return "could not listen at \(path)" }
                attempted.wait()
                unlink(path)
                close(listener)
            }
            return nil
        }
        let failure = await server.value
        #expect(failure == nil)
        let refused = await watcher.value.filter { $0 == ECONNREFUSED }.count
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
