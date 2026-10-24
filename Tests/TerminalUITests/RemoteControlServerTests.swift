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
import TerminalUIConfig

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
        let client = try #require(UnixSocket.connected(to: path))
        defer { close(client) }
        _ = UnixSocket.sendLine(Array(#"{"id":1,"cmd":"ping"}"#.utf8), to: client)

        // The client reads only once released, as a busy one might. Were a
        // pump to wait for it, the pumps below would never return: a watchdog
        // releases it after a while and says so. Measured by what happened,
        // not by how long a pump took, so a loaded machine cannot fail it.
        let finished = ReadFinished()
        let release = DispatchSemaphore(value: 0)
        let watchdogFired = ReadFinished()
        let watchdog = BlockingThread(name: "watchdog") {
            if release.wait(timeout: .now() + .seconds(5)) == .timedOut {
                watchdogFired.flag.store(true, ordering: .releasing)
            }
            release.signal()
        }
        let reader = BlockingThread(name: "slow client") { () -> Data in
            release.wait()
            release.signal()
            defer { finished.flag.store(true, ordering: .releasing) }
            return Data(UnixSocket.readLine(from: client))
        }

        for _ in 0..<5 {
            server.pump()
        }
        let waitedForTheClient = watchdogFired.flag.load(ordering: .acquiring)
        #expect(!waitedForTheClient, "a pump waited for the client to read")
        release.signal()
        await watchdog.value
        let deadline = ContinuousClock.now + .seconds(10)
        while !finished.flag.load(ordering: .acquiring), ContinuousClock.now < deadline {
            server.pump()
            try? await Task.sleep(for: .milliseconds(1))
        }

        // A reply that never finished leaves the reader blocked: end its read.
        shutdown(client, Int32(SHUT_RDWR))
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
        let client = try #require(UnixSocket.connected(to: path))
        defer { close(client) }
        _ = UnixSocket.sendLine(Array((#"{"id":1,"cmd":"ping"}"# + "\n" + #"{"id":2,"cmd":"ping"}"#).utf8), to: client)
        for _ in 0..<20 {
            server.pump()
        }
        #expect(dispatcher.answered == 1)

        let reader = BlockingThread(name: "client") { UnixSocket.readLine(from: client) }
        while dispatcher.answered < 2 {
            server.pump()
            try? await Task.sleep(for: .milliseconds(1))
        }
        _ = await reader.value
        withExtendedLifetime(server) {}
    }
}

// A server that cannot listen used to say nothing: the app ran, and
// `swtui ctl` found no socket. A path too long for a socket address — a deep
// checkout with `use_tmp = false` — was cut to fit and bound elsewhere.
@Suite("A debug server that cannot listen says why")
@MainActor
struct DebugSocketWarningTests {

    @Test func aPathTooLongForAnAddressIsAWarning() {
        let probe = WarningProbe()
        DebugStream.shared.addSink(probe)
        defer { DebugStream.shared.removeAllSinks() }
        let path = "/tmp/\(String(repeating: "x", count: 200))-\(UInt32.random(in: 0...UInt32.max)).sock"

        withExtendedLifetime(RemoteControlServer(path: path, dispatcher: LargeReplies())) {}

        let warnings = probe.warnings.withLock { $0 }
        #expect(warnings.contains { $0.code == .debugSocketUnavailable && $0.message.contains("longer than") },
                "got \(warnings)")
    }
}

private final class WarningProbe: DebugSink, Sendable {
    let warnings = Mutex<[FrameworkWarningInfo]>([])

    func receive(_ event: DebugEvent) {
        guard case .frameworkWarning(let info) = event else { return }
        warnings.withLock { $0.append(info) }
    }
}

private final class ReadFinished: Sendable {
    let flag = Atomic(false)
}
#endif
