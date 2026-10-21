#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Testing
@testable import TerminalUI

// `swtui ctl kill` sends its quit and hangs up without reading the reply. The
// remote-control server then wrote that reply to a closed socket, SIGPIPE's
// default action ended the app inside the write, and no handler restored the
// terminal. A write to a socket whose peer has gone must come back as EPIPE.
// Had it raised SIGPIPE, this test would have ended the whole test process.

@Suite("A socket write to a peer that hung up fails instead of killing the process")
struct SocketWriteTests {

    @Test func aClosedPeerIsAnErrorTheCallerSees() {
        var pair: [Int32] = [-1, -1]
        #if canImport(Glibc)
        let created = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair)
        #else
        let created = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        #endif
        #expect(created == 0)
        close(pair[1])
        defer { close(pair[0]) }

        let reply: [UInt8] = Array("{\"ok\":true}\n".utf8)
        let written = reply.withUnsafeBytes { socketWrite(pair[0], $0.baseAddress!, $0.count) }
        let failure = errno

        #expect(written == -1)
        #expect(failure == EPIPE)
    }
}
