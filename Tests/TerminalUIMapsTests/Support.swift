import Foundation
import Synchronization
@testable import TerminalUIMaps

/// A transport that answers from a closure and remembers every request, so
/// a backend is tested with no network.
final class StubTransport: HTTPTransport {
    private let responder: @Sendable (HTTPRequest) throws -> HTTPResponse
    private let recorded = Mutex<[HTTPRequest]>([])

    init(_ responder: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.responder = responder
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try responder(request)
    }
}

extension HTTPResponse {
    static func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Array(text.utf8))
    }
}

/// A clock whose time moves only when something sleeps on it: a sleep
/// returns at once, the clock set to its deadline. A test of pacing reads
/// the deadlines asked for and never waits.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleeps: [Instant] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeps: [Duration] { state.withLock { $0.sleeps.map(\.offset) } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.withLock { state in
            state.sleeps.append(deadline)
            if deadline > state.now { state.now = deadline }
        }
    }
}

/// Pacing that lets every request through and counts them.
final class CountingPacing: RequestPacing {
    private let count = Mutex(0)

    var turns: Int { count.withLock { $0 } }

    func waitForTurn() async throws {
        count.withLock { $0 += 1 }
    }
}

/// A tile source over another that counts what it is asked for and how
/// many requests were in flight at once, and can fail after a number of
/// tiles, as a connection that drops does.
final class InstrumentedSource: EncodedTileSource {
    private struct State {
        var fetched: [TileID] = []
        var inFlight = 0
        var mostInFlight = 0
    }

    struct Dropped: Error {}

    private let base: any EncodedTileSource
    private let failAfter: Int?
    private let state = Mutex(State())

    init(_ base: any EncodedTileSource, failAfter: Int? = nil) {
        self.base = base
        self.failAfter = failAfter
    }

    var fetched: [TileID] { state.withLock { $0.fetched } }
    var mostInFlight: Int { state.withLock { $0.mostInFlight } }

    func info() async throws -> TileSourceInfo { try await base.info() }

    func tileData(_ id: TileID) async throws -> [UInt8]? {
        let shouldFail = state.withLock { state -> Bool in
            if let failAfter, state.fetched.count >= failAfter { return true }
            state.fetched.append(id)
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
            return false
        }
        if shouldFail { throw Dropped() }
        defer { state.withLock { $0.inFlight -= 1 } }
        return try await base.tileData(id)
    }
}

/// A directory of its own for one test, removed when it ends.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminalui-maps-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Whether the live checks, which reach real servers, run.
let liveNetworkEnabled = ProcessInfo.processInfo.environment["TERMINALUI_MAPS_LIVE"] == "1"
