#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
import TerminalUIConfig

// The debug servers and `swtui ctl` open AF_UNIX sockets one way, here. A
// path longer than an address holds was cut to fit, so a server bound, and
// a client connected, somewhere other than the path it was given — and a
// server that could not listen said nothing.
@Suite("Unix sockets")
struct UnixSocketTests {

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
