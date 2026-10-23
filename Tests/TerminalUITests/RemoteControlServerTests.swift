#if DEBUG
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Foundation
import Synchronization
import Testing
@testable import TerminalUI

// The control server answers on the main actor, between frames. A reply
// larger than the socket's buffer used to be written in a loop that slept
// whenever the buffer was full, until the client had read it all: a client
// that read slowly, or not at all, held the app's frame loop for as long.
// A reply now waits on its own connection, written as the socket drains,
// and that client's next request waits until it has taken it.

/// Answers every request with a reply larger than the socket can hold: four
/// times the buffer the server asks for, which Linux doubles.
@MainActor
private final class LargeReplies: RemoteControlDispatcher {
    static let replySize = Int(RemoteControlServer.sendBufferBytes) * 4
    private(set) var answered = 0

    func dispatch(_ request: RemoteRequest) -> RemoteResponse {
        answered += 1
        return RemoteResponse(id: request.id, ok: false, error: String(repeating: "x", count: Self.replySize))
    }
}

@Suite("A control client that reads slowly cannot stall the app")
@MainActor
struct RemoteControlBackpressureTests {

    // Watched, as in a running app, the server acts only when a descriptor
    // is ready: what is left of a reply goes out when the socket has room.
    @Test(arguments: [false, true])
    func pumpingDoesNotWaitForTheClientToRead(watched: Bool) async throws {
        let path = "/tmp/terminalui-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let woken: (@Sendable () -> Void)? = watched ? { @Sendable in } : nil
        let server = RemoteControlServer(path: path, dispatcher: LargeReplies(), onActivity: woken)
        let client = try #require(connectedSocket(to: path))
        defer { close(client) }
        sendLine(#"{"id":1,"cmd":"ping"}"#, to: client)

        // The client starts reading only after a while, as a busy one might.
        let finished = ReadFinished()
        let reader = Task.detached { () -> Data in
            try? await Task.sleep(for: .milliseconds(150))
            defer { finished.flag.store(true, ordering: .releasing) }
            return readLine(from: client)
        }

        var slowestPump = Duration.zero
        let deadline = ContinuousClock.now + .seconds(10)
        while !finished.flag.load(ordering: .acquiring), ContinuousClock.now < deadline {
            let start = ContinuousClock.now
            server.pump()
            slowestPump = max(slowestPump, ContinuousClock.now - start)
            try? await Task.sleep(for: .milliseconds(1))
        }

        // A reply that never finished leaves the reader blocked: end its read.
        shutdown(client, Int32(SHUT_RDWR))
        #expect(slowestPump < .milliseconds(100), "a pump waited \(slowestPump) for the client to read")
        let reply = try JSONDecoder().decode(RemoteResponse.self, from: await reader.value)
        #expect(reply.id == 1)
        #expect(reply.error?.count == LargeReplies.replySize, "the reply should arrive whole")
        withExtendedLifetime(server) {}
    }

    // One request, one response: a client that sends more before it has read
    // a reply is not answered until it has, so one that never reads costs
    // the app one reply, not one per request it sends.
    @Test func aClientIsServedItsNextRequestOnlyOnceItHasTakenTheLast() async throws {
        let path = "/tmp/terminalui-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let dispatcher = LargeReplies()
        let server = RemoteControlServer(path: path, dispatcher: dispatcher)
        let client = try #require(connectedSocket(to: path))
        defer { close(client) }
        sendLine(#"{"id":1,"cmd":"ping"}"# + "\n" + #"{"id":2,"cmd":"ping"}"#, to: client)
        for _ in 0..<20 {
            server.pump()
        }
        #expect(dispatcher.answered == 1)

        let reader = Task.detached { readLine(from: client) }
        while dispatcher.answered < 2 {
            server.pump()
            try? await Task.sleep(for: .milliseconds(1))
        }
        _ = await reader.value
        withExtendedLifetime(server) {}
    }
}

private final class ReadFinished: Sendable {
    let flag = Atomic(false)
}

private func connectedSocket(to path: String) -> Int32? {
    #if canImport(Glibc)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        let bytes = Array(path.utf8.prefix(buffer.count - 1))
        buffer.copyBytes(from: bytes)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func sendLine(_ line: String, to fd: Int32) {
    writeAll(Array((line + "\n").utf8), to: fd)
}

/// Reads until a newline, blocking; the line without it.
private func readLine(from fd: Int32) -> Data {
    var line = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let bytesRead = read(fd, &chunk, chunk.count)
        guard bytesRead > 0 else { return line }
        line.append(contentsOf: chunk[..<bytesRead])
        if let newline = line.firstIndex(of: 0x0A) {
            return line[..<newline]
        }
    }
}
#endif
