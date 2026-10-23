#if DEBUG

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import Synchronization
import TerminalUIConfig

// MARK: - Wire protocol (JSON lines)

/// remote control protocol. A unix-domain socket accepts one JSON
/// request per line and writes one JSON response per line back. The protocol
/// is intentionally plain so smoke tests can be shell scripts and external
/// MCP servers don't need a vendored Swift client.
///
/// Every request carries `id` (echoed by the response) and `cmd`. Responses
/// are `{id, ok, result?, error?}`. Commands that mutate runtime state
/// (`send_key`, `focus_set`) return `{ok: true}` with no result.
public enum RemoteControlProtocol {
    /// The line delimiter (`\n`) framing every request and response.
    public static let newline: UInt8 = 0x0A
}

/// A request body. Additional cmd-specific fields ride on the same struct
/// via optional properties — keeps the wire flat for easy hand-authoring.
///
/// The verb goes in ``cmd``; every other property is a payload field that
/// only some verbs read (unused fields are simply omitted from the JSON).
/// Recognized verbs: `ping`, `send_key`, `send_text`, `send_mouse`,
/// `focus_get`, `focus_set`, `query_cells`, `query_tree`,
/// `inspector_probe`, `inspector_move`, `inspector_toggle`,
/// `inspect_range`, `scan`, `frame_number`, `terminal_input`, `screenshot`, `list_actions`,
/// `invoke_action`, `quit`, `crash`. The typed Python client in
/// `tools/terminalui/client.py` speaks this same shape.
public struct RemoteRequest: Codable, Sendable {
    /// Client-chosen correlation ID; the response echoes it back.
    public var id: Int
    /// The command verb — selects which handler runs and which payload
    /// fields below are read.
    public var cmd: String
    // send_key / send_text payloads
    /// `send_key`: key name (`"a"`, `"enter"`, `"F5"`, ...); also
    /// `focus_set`'s target node ID.
    public var key: String?
    /// `send_key`: modifier names (`"ctrl"`, `"alt"`, `"shift"`).
    public var modifiers: [String]?
    /// `send_text`: literal text typed into the app as individual key
    /// events. Also `focus_set`'s preferred field for the target node ID.
    public var text: String?
    // query_cells + inspector_probe + inspect_range payload
    /// `query_cells` / `inspect_range`: region as `[x, y, w, h]` in cells.
    public var rect: [Int]?  // [x, y, w, h]
    /// Cell x for `send_mouse`, `inspector_probe`, and `inspector_move`.
    public var x: Int?
    /// Cell y for `send_mouse`, `inspector_probe`, and `inspector_move`.
    public var y: Int?
    // wait_for_frame payload
    /// Number of frames a client-side frame-wait spans; no shipped verb
    /// reads it — clients poll `frame_number` instead.
    public var frames: Int?
    // send_mouse payload — `kind` is one of:
    //   "move"   — mouse cursor at (x, y), no button state change
    //   "click"  — press+release of `button` at (x, y) (defaults to "left")
    //   "press"  — press only
    //   "release"— release only
    //   "wheel_up" / "wheel_down" — scroll at (x, y)
    /// `send_mouse`: event kind — `"move"`, `"click"`, `"press"`,
    /// `"release"`, `"wheel_up"`, or `"wheel_down"`.
    public var kind: String?
    /// `send_mouse`: button name (`"left"`, `"middle"`, `"right"`);
    /// defaults to left when omitted.
    public var button: String?
    // grid overlay for query_cells / screenshot (coordinate rulers)
    /// `query_cells` / `screenshot`: include coordinate-ruler overlays.
    public var grid: Bool?
    // scan criteria — first non-nil match wins. `match_kind` e.g. "Text",
    // "Button"; `match_text` substring match on a text node; `match_focused`
    // finds the currently-focused node.
    /// `scan`: match nodes by kind tag, e.g. `"Text"`, `"Button"`.
    public var matchKind: String?
    /// `scan`: match text nodes containing this substring.
    public var matchText: String?
    /// `scan`: match the currently keyboard-focused node.
    public var matchFocused: Bool?
    /// Action invocation payload — the stable Action.ID to fire via
    /// ActionDispatch.invoke. Used by the `invoke_action` command.
    public var actionId: String?
}

/// One JSON-line reply to a ``RemoteRequest`` — always `{id, ok}` plus
/// either a ``result`` on success or an ``error`` message on failure.
public struct RemoteResponse: Codable, Sendable {
    /// Echo of the request's correlation ID.
    public var id: Int
    /// Whether the command succeeded. Mutating verbs (`send_key`,
    /// `focus_set`, ...) return `ok` alone with no result.
    public var ok: Bool
    /// Query payload — present only for verbs that return data; consumers
    /// read the ``RemoteResult`` field matching the verb they sent.
    public var result: RemoteResult?
    /// Human-readable failure reason; present only when ``ok`` is false.
    public var error: String?

    /// Assemble a response; the dispatcher builds one per handled request.
    public init(id: Int, ok: Bool, result: RemoteResult? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }
}

/// Union response payload. A tagged struct is simpler than an enum here —
/// JSON consumers pick the field that matches the command they sent.
public struct RemoteResult: Codable, Sendable {
    /// `focus_get`'s answer — the keyboard-focused node.
    public var focus: FocusInfo?
    /// `query_cells`' answer — the requested region's text.
    public var cells: CellSlice?
    /// `query_tree`'s answer — the graph root, nested.
    public var tree: GraphDebugNode?
    /// `frame_number`'s answer — the current frame counter.
    public var frame: Int?
    /// `terminal_input`'s answer — what the app has taken from its terminal.
    public var terminalInput: TerminalInputTaken?
    /// `screenshot`'s answer — path of the written capture file.
    public var screenshotPath: String?
    /// `inspector_probe`'s answer — one probe at the requested cell.
    public var inspector: InspectorProbe?
    /// Multiple probes — one per cell in the requested range. Used by
    /// `inspect_range` so a single round trip covers a whole rect.
    public var probes: [InspectorProbe]?
    /// Action graph reachable from the focused node. Populated by
    /// `list_actions`. Empty when no scope reaches the focused node.
    public var actions: [ActionRemoteInfo]?
    /// Whether `invoke_action` matched and fired an action.
    public var fired: Bool?

    /// Assembles a payload; pass only the field matching the verb.
    public init(focus: FocusInfo? = nil,
                cells: CellSlice? = nil,
                tree: GraphDebugNode? = nil,
                frame: Int? = nil,
                terminalInput: TerminalInputTaken? = nil,
                screenshotPath: String? = nil,
                inspector: InspectorProbe? = nil,
                probes: [InspectorProbe]? = nil,
                actions: [ActionRemoteInfo]? = nil,
                fired: Bool? = nil) {
        self.focus = focus
        self.cells = cells
        self.tree = tree
        self.frame = frame
        self.terminalInput = terminalInput
        self.screenshotPath = screenshotPath
        self.inspector = inspector
        self.probes = probes
        self.actions = actions
        self.fired = fired
    }
}

/// Wire-format action info — what `list_actions` returns. Mirrors
/// `Action` plus its bound input bindings, so an LLM can introspect
/// "what can I do here?" and invoke by stable ID.
public struct ActionRemoteInfo: Codable, Sendable {
    /// The stable Action ID `invoke_action` fires by.
    public var id: String
    /// The action's menu/help title.
    public var title: String
    /// Longer explanation, when the action declared one.
    public var description: String?
    /// `false` for actions that surface in readouts but won't fire.
    public var enabled: Bool
    /// The device bindings that trigger the action; empty for
    /// ID-only actions.
    public var bindings: [ActionBindingRemoteInfo]
}

/// Wire-format form of one `InputBinding`, inside ``ActionRemoteInfo``.
public struct ActionBindingRemoteInfo: Codable, Sendable {
    /// "keyboard" / "mouse" / "gesture" / "voice" / "accessibility".
    public var kind: String
    /// Keyboard binding fields.
    public var key: String?
    /// Keyboard modifier names (`"ctrl"`, `"alt"`, `"shift"`); nil for
    /// non-keyboard bindings.
    public var modifiers: [String]?
    /// Mouse binding field.
    public var button: String?
    /// Gesture / voice / accessibility identifier.
    public var payload: String?
}

/// Inspector probe result — what the in-app inspector shows for the node at
/// a given cell. Same data the crosshair renders, so MCP-driven smoke tests
/// see exactly what a user with the inspector open would see.
///
/// Returned by the `inspector_probe` verb (one probe at the requested
/// cell, or at the live inspector cursor when no coordinates are given)
/// and by `inspect_range` (one probe per cell of a rect). The node fields
/// are nil when no node hit-tests at that cell.
public struct InspectorProbe: Codable, Sendable {
    /// Probed cell's x coordinate.
    public var cursorX: Int
    /// Probed cell's y coordinate.
    public var cursorY: Int
    /// Whether the in-app inspector overlay was active when probed.
    public var active: Bool
    /// Kind tag of the deepest node at the cell (`"text"`, `"vstack"`, ...);
    /// nil when nothing hit-tests there.
    public var nodeKind: String?
    /// That node's layout rect as `[x, y, width, height]` in cells.
    public var nodeRect: [Int]?
    /// The node's declared properties as shown in the inspector panel
    /// (e.g. content, colors), keyed by property name.
    public var declared: [String: String]
    /// Modifier names wrapping the node, outermost first — the "chain"
    /// line of the inspector panel.
    public var modifierChain: [String]

    /// Assemble a probe; the dispatcher builds these from hit-test results.
    public init(cursorX: Int, cursorY: Int, active: Bool,
                nodeKind: String? = nil, nodeRect: [Int]? = nil,
                declared: [String: String] = [:], modifierChain: [String] = []) {
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.active = active
        self.nodeKind = nodeKind
        self.nodeRect = nodeRect
        self.declared = declared
        self.modifierChain = modifierChain
    }
}

/// Wire-format description of the keyboard-focused node — `focus_get`'s
/// result.
public struct FocusInfo: Codable, Sendable {
    /// Path-formatted ID of the focused node; nil when nothing is
    /// focused.
    public var nodeID: String?
    /// The focused node's kind tag (`"text"`, `"button"`, ...).
    public var kind: String?
    /// Layout rect as `[x, y, width, height]` in cells; empty when
    /// nothing is focused.
    public var rect: [Int]
    /// The node's payload summary — text content, label, etc.
    public var value: String?
}

/// What an app has taken from its terminal — `terminal_input`'s result: the
/// bytes it has turned into events, and the size of the last resize. A
/// client that typed into the terminal, or resized it, waits for this to
/// reach what it did; the reply to its next request then shows it drawn.
public struct TerminalInputTaken: Codable, Sendable, Equatable {
    /// Bytes read from the terminal whose events are queued or handled,
    /// counting those that made none.
    public var bytes: Int
    /// Columns of the last resize taken, nil before the first.
    public var cols: Int?
    /// Rows of the last resize taken, nil before the first.
    public var rows: Int?

    /// A record of `bytes` taken and the last resize, if any.
    public init(bytes: Int = 0, cols: Int? = nil, rows: Int? = nil) {
        self.bytes = bytes
        self.cols = cols
        self.rows = rows
    }
}

/// A rectangular region of the screen as text — `query_cells`' result.
public struct CellSlice: Codable, Sendable {
    /// Region left edge, 0-based column.
    public var x: Int
    /// Region top edge, 0-based row.
    public var y: Int
    /// Region width in cells; each row string is padded to it.
    public var width: Int
    /// Region height in rows — `rows.count`.
    public var height: Int
    /// Row-major text — one string per row, padded to `width`. Suitable for
    /// `contains("...")` assertions in test scripts without building a map.
    public var rows: [String]
    /// Optional coordinate-ruler strings (`grid: true` in the request).
    /// `rulerTop` is a 3-line stack of column-ruler characters so the caller
    /// can read e.g. column 137 as the stacked glyph of rows "1"/"3"/"7".
    /// `rulerLeft` is per-row digits prepended to `rows` conceptually — it's
    /// returned separately so consumers can choose to concatenate or not.
    public var rulerTop: [String]?
    /// Per-row row-number digits (`grid: true` only), parallel to `rows`;
    /// returned separately so consumers choose whether to concatenate.
    public var rulerLeft: [String]?
}

// MARK: - Server

/// Accepts JSON commands over an AF_UNIX socket and applies them to a
/// running `TerminalRuntime`. Called by the runtime via `pump()` once per
/// frame — non-blocking so the event loop keeps running when no client is
/// connected.
///
/// One request at a time, from any number of connections. The dispatch below
/// is synchronous inside `pump()`, so requests never interleave — but a second
/// client is *served*, not ignored. Accepting only while no client was attached
/// left later connections sitting unread in the kernel's backlog: their writes
/// succeeded, so `swtui ctl kill` reported `status=quit-sent` against an app
/// that never heard the command and never exited.
public final class RemoteControlServer: @unchecked Sendable {
    /// One connected client. The protocol is one request, one response: a
    /// client is served its next request only once its socket has taken the
    /// last reply. One that does not read is answered nothing more, holds
    /// only its own socket, and never holds up the frame loop.
    private struct Connection {
        let descriptor: WatchedDescriptor
        /// The bytes read so far — a partial line belongs to the connection
        /// that sent it, so the buffers cannot be shared.
        var received = Data()
        /// What the socket has not yet taken of the last reply.
        var unsent = Data()
        /// While `onActivity` is set: one watch for requests, one for room
        /// to write a reply the socket could not take at once.
        var readWatch: ReadinessWatch?
        var writeWatch: ReadinessWatch?
    }

    private var listener: WatchedDescriptor?
    private var listenWatch: ReadinessWatch?
    private var clients: [Int32: Connection] = [:]
    /// Called, from a dispatch queue, when a client connects, sends
    /// something, or has room for the rest of its reply — so a frame loop
    /// with nothing to do can sleep until then instead of polling the
    /// socket. Nil leaves the server to be pumped every frame.
    private let onActivity: (@Sendable () -> Void)?
    /// Set when a watch fires, cleared by `pump()`.
    private let activity = Atomic<Bool>(false)

    /// Room in each client's socket for a reply. A whole app's tree is tens
    /// of KiB and macOS gives a local socket 8 KiB, so a reply went out over
    /// as many wakeups. Linux doubles the request, up to its own maximum.
    static let sendBufferBytes: Int32 = 512 * 1024

    /// Whether a client has connected, sent something, or had room made for
    /// its reply that `pump()` has not yet seen to. Any thread.
    public var hasPendingActivity: Bool {
        activity.load(ordering: .acquiring)
    }
    private let path: String
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Accept snake_case wire fields (`match_kind`, `match_text`, etc.)
        // since the CLI and curl-style clients are more natural that way.
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Match the wire style — clients parsing responses see `match_kind`,
        // `node_id`, etc. rather than Swift's camelCase.
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private let dispatcher: any RemoteControlDispatcher

    /// Binds the listening socket at `path` and routes every parsed
    /// request through `dispatcher`. Bind failure leaves an inert server
    /// rather than throwing.
    public convenience init(path: String, dispatcher: any RemoteControlDispatcher) {
        self.init(path: path, dispatcher: dispatcher, onActivity: nil)
    }

    init(path: String, dispatcher: any RemoteControlDispatcher, onActivity: (@Sendable () -> Void)?) {
        self.path = path
        self.dispatcher = dispatcher
        self.onActivity = onActivity
        do {
            // `pump()` accepts every waiting client when it runs, so the
            // queue must hold all that connect between two runs. Past the
            // backlog, macOS refuses a connection outright; Linux makes it
            // wait.
            let listener = WatchedDescriptor(try UnixSocket.listening(at: path, backlog: SOMAXCONN))
            self.listener = listener
            listenWatch = watch(listener, until: .readable)
        } catch {
            DebugStream.shared.emitWarning(.debugSocketUnavailable,
                                           message: "remote control has no socket at \(path): \(error)")
        }
    }

    /// A watch on `descriptor` that wakes the frame loop, when there is
    /// anyone to tell.
    private func watch(_ descriptor: WatchedDescriptor, until readiness: ReadinessWatch.Readiness) -> ReadinessWatch? {
        guard let onActivity else { return nil }
        return ReadinessWatch(descriptor, until: readiness) { [weak self] in
            self?.activity.store(true, ordering: .releasing)
            onActivity()
        }
    }

    /// Runtime hook — call once per frame BEFORE draining the event queue.
    /// Accepts every waiting client, then serves each. Never blocks. With
    /// its descriptors watched, it does nothing until one is ready.
    @MainActor
    public func pump() {
        guard onActivity == nil || activity.exchange(false, ordering: .acquiringAndReleasing) else { return }
        acceptPending()
        // A snapshot of the keys: serving writes to `clients`, and a write
        // while its keys are iterated copies every buffer in it.
        for fd in Array(clients.keys) {
            serve(fd)
        }
        // Watches are level-triggered: a client still waiting fires again.
        listenWatch?.rearm()
    }

    /// Drain the listen backlog. `accept` is non-blocking, so this returns as
    /// soon as nothing is waiting.
    @MainActor
    private func acceptPending() {
        guard let listener else { return }
        while true {
            let accepted = accept(listener.fd, nil, nil)
            guard accepted >= 0 else { return }
            _ = fcntl(accepted, F_SETFL, O_NONBLOCK)
            var sendBufferBytes = Self.sendBufferBytes
            _ = setsockopt(accepted, SOL_SOCKET, SO_SNDBUF, &sendBufferBytes, socklen_t(MemoryLayout<Int32>.size))
            let descriptor = WatchedDescriptor(accepted)
            clients[accepted] = Connection(descriptor: descriptor, readWatch: watch(descriptor, until: .readable))
        }
    }

    /// Writes what `fd`'s socket takes of its last reply and, once it has
    /// taken all of it, reads and answers the client's requests one by one.
    /// The read watch is rearmed only then: a client with a reply unread
    /// would otherwise wake the loop for requests it will not be served.
    @MainActor
    private func serve(_ fd: Int32) {
        guard flush(fd) else { return }
        readAvailable(from: fd)
        while let line = nextLine(from: fd) {
            handleLine(line, from: fd)
            guard flush(fd) else { return }
        }
        clients[fd]?.readWatch?.rearm()
    }

    @MainActor
    private func readAvailable(from fd: Int32) {
        // Read up to 4 KiB per pump; the buffer keeps partial lines between
        // pumps so fragmented commands assemble correctly.
        let bytesRead = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4096) { scratch in
            let bytesRead = posixRead(fd, scratch.baseAddress!, scratch.count)
            if bytesRead > 0 {
                clients[fd]?.received.append(scratch.baseAddress!, count: bytesRead)
            }
            return bytesRead
        }
        if bytesRead == 0 {
            // EOF — client closed.
            disconnect(fd)
        }
        // bytesRead < 0 with EAGAIN is the normal "no data yet" case — ignore.
    }

    /// The next whole request `fd` has sent, without its newline; nil when
    /// none has arrived whole.
    private func nextLine(from fd: Int32) -> Data? {
        while let received = clients[fd]?.received,
              let newline = received.firstIndex(of: RemoteControlProtocol.newline) {
            let line = received[..<newline]
            clients[fd]?.received.removeSubrange(...newline)
            if !line.isEmpty {
                return Data(line)
            }
        }
        return nil
    }

    @MainActor
    private func handleLine(_ line: Data, from fd: Int32) {
        let response: RemoteResponse
        do {
            let request = try decoder.decode(RemoteRequest.self, from: line)
            response = dispatcher.dispatch(request)
        } catch {
            response = RemoteResponse(id: -1, ok: false, error: "decode: \(error)")
        }
        guard var data = try? encoder.encode(response) else { return }
        data.append(RemoteControlProtocol.newline)
        clients[fd]?.unsent = data
    }

    /// Writes as much of `fd`'s last reply as its socket takes now, and says
    /// whether it took all of it. A reply larger than the socket's buffer
    /// goes out over several pumps as the client reads, each woken by a
    /// watch for room. Any failure but a full buffer drops the client.
    private func flush(_ fd: Int32) -> Bool {
        guard var connection = clients[fd] else { return false }
        while !connection.unsent.isEmpty {
            let bytesWritten = connection.unsent.withUnsafeBytes { socketWrite(fd, $0.baseAddress!, $0.count) }
            let error = errno
            if bytesWritten > 0 {
                connection.unsent = connection.unsent.dropFirst(bytesWritten)
            } else if bytesWritten < 0, error == EINTR {
                continue
            } else if bytesWritten < 0, error == EAGAIN {
                if let writeWatch = connection.writeWatch {
                    writeWatch.rearm()
                } else {
                    connection.writeWatch = watch(connection.descriptor, until: .writable)
                }
                clients[fd] = connection
                return false
            } else {
                disconnect(fd)
                return false
            }
        }
        connection.unsent = Data()
        clients[fd] = connection
        return true
    }

    /// Dropping the connection stops its watches and closes its descriptor.
    private func disconnect(_ fd: Int32) {
        clients[fd] = nil
    }

    deinit {
        unlink(path)
    }
}

/// A descriptor the server watches, closed once no watch needs it: every
/// dispatch source on a descriptor must be cancelled before it closes, and a
/// client's may have two. Each source's cancel handler holds it until the
/// cancel is done.
private final class WatchedDescriptor: Sendable {
    let fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }
}

/// Calls `onReady` when a descriptor can be read, or written, then holds off
/// until ``rearm()``.
///
/// A dispatch source fires for as long as the descriptor is ready, but the
/// reading or writing happens later, on the main actor, in `pump()`; left
/// running, the source would spin a dispatch thread until then. So it
/// suspends itself when it fires, and `pump()` resumes it once it is done.
private final class ReadinessWatch: Sendable {
    enum Readiness {
        case readable
        case writable
    }

    /// The source as made. Held as `any DispatchSourceProtocol`, it could not
    /// go under the lock without a warning on Linux, where the sources are
    /// not `Sendable`: the conversion is not known to leave the value the
    /// lock's alone.
    private enum Source {
        case read(any DispatchSourceRead)
        case write(any DispatchSourceWrite)

        var dispatchSource: any DispatchSourceProtocol {
            switch self {
            case .read(let source): source
            case .write(let source): source
            }
        }
    }

    private struct State {
        let source: Source
        /// Whether the source is resumed. Dispatch traps on an unbalanced
        /// resume, and on cancelling or releasing a suspended source.
        var armed: Bool
    }

    /// The source lives under the lock with its state: it is not `Sendable`
    /// on every platform, and every call on it must agree with `armed`.
    private let state: Mutex<State>

    init(_ descriptor: WatchedDescriptor, until readiness: Readiness, onReady: @escaping @Sendable () -> Void) {
        let source: Source = switch readiness {
        case .readable: .read(DispatchSource.makeReadSource(fileDescriptor: descriptor.fd, queue: .global()))
        case .writable: .write(DispatchSource.makeWriteSource(fileDescriptor: descriptor.fd, queue: .global()))
        }
        state = Mutex(State(source: source, armed: true))
        state.withLock { state in
            state.source.dispatchSource.setCancelHandler {
                withExtendedLifetime(descriptor) {}
            }
            state.source.dispatchSource.setEventHandler { [weak self] in
                self?.disarm()
                onReady()
            }
            state.source.dispatchSource.resume()
        }
    }

    func rearm() {
        state.withLock { state in
            guard !state.armed else { return }
            state.source.dispatchSource.resume()
            state.armed = true
        }
    }

    /// Releasing the watch stops it; its descriptor closes once no other
    /// watch holds it.
    deinit {
        state.withLock { state in
            if !state.armed {
                state.source.dispatchSource.resume()
            }
            state.source.dispatchSource.cancel()
        }
    }

    private func disarm() {
        state.withLock { state in
            guard state.armed else { return }
            state.source.dispatchSource.suspend()
            state.armed = false
        }
    }
}

// MARK: - Dispatcher

/// Abstracts the runtime bits the server mutates so tests can swap in a
/// mock without spinning up a whole `TerminalRuntime`. The real
/// implementation lives inside the runtime (see `RuntimeRemoteDispatcher`).
@MainActor
public protocol RemoteControlDispatcher: AnyObject {
    /// Handles one request synchronously and returns its response;
    /// never throws — failures come back as `{ok: false, error}`.
    func dispatch(_ request: RemoteRequest) -> RemoteResponse
}

/// Protocol for runtime surfaces the dispatcher calls. Keeps RemoteControl
/// free of the `TerminalRuntime<RootView>` generic.
@MainActor
public protocol RemoteControlRuntime: AnyObject {
    /// Injects an event into the runtime's queue as if input produced
    /// it.
    func enqueueEvent(_ event: TerminalEvent)
    /// The current attribute-graph root, or nil before the first frame.
    func remoteCurrentGraphRoot() -> AttributeNode?
    /// The runtime's live focus engine.
    func remoteFocusEngine() -> FocusEngine
    /// The runtime's live inspector.
    func remoteInspector() -> Inspector
    /// The last flushed frame's cell buffer, or nil before the first
    /// flush.
    func remotePreviousBuffer() -> CellBuffer?
    /// Asks the runtime to write a screenshot capture on its next frame.
    func remoteRequestCapture()
    /// Ask for a frame: a command changed what is drawn without an event or
    /// observed state to say so.
    func remoteRequestFrame()
    /// The monotonic frame counter — clients poll it to await a render.
    func remoteCurrentFrameNumber() -> Int
    /// What the app has taken from its terminal. A client that typed into
    /// the terminal or resized it polls this to know the app has the input:
    /// requests are served before each drain, so the next one is answered
    /// after those events are drawn.
    func remoteTerminalInputTaken() -> TerminalInputTaken
    /// Build the framework's default action scope (Ctrl+C → Action.quit,
    /// Esc → Action.dismissOrQuit) so `list_actions` / `invoke_action`
    /// can route through the same data the runtime dispatch uses.
    func remoteFrameworkDefaultsScope() -> ActionScope
}

extension RemoteControlRuntime {
    /// Default for a runtime that draws every frame regardless.
    public func remoteRequestFrame() {}
}

/// Concrete dispatcher that translates `RemoteRequest` → actions on the
/// runtime. Owned by the server; weakly references the runtime so the
/// runtime's lifetime controls ours.
@MainActor
public final class RuntimeRemoteDispatcher: RemoteControlDispatcher {
    private weak var runtime: (any RemoteControlRuntime)?

    /// Creates a dispatcher over the runtime; the reference is weak, so
    /// a deallocated runtime turns every request into an error response.
    public init(runtime: any RemoteControlRuntime) {
        self.runtime = runtime
    }

    /// Routes the request's `cmd` verb to its handler on the runtime.
    public func dispatch(_ request: RemoteRequest) -> RemoteResponse {
        guard let runtime else {
            return RemoteResponse(id: request.id, ok: false, error: "runtime deallocated")
        }
        switch request.cmd {
        case "send_key":    return sendKey(request, runtime: runtime)
        case "send_text":   return sendText(request, runtime: runtime)
        case "send_mouse":  return sendMouse(request, runtime: runtime)
        case "focus_get":   return focusGet(request, runtime: runtime)
        case "focus_set":   return focusSet(request, runtime: runtime)
        case "query_cells": return queryCells(request, runtime: runtime)
        case "query_tree":  return queryTree(request, runtime: runtime)
        case "inspector_probe": return inspectorProbe(request, runtime: runtime)
        case "inspector_move":  return inspectorMove(request, runtime: runtime)
        case "inspector_toggle":return inspectorToggle(request, runtime: runtime)
        case "inspect_range":   return inspectRange(request, runtime: runtime)
        case "scan":            return scan(request, runtime: runtime)
        case "frame_number":return frameNumber(request, runtime: runtime)
        case "terminal_input": return terminalInput(request, runtime: runtime)
        case "screenshot":  return screenshot(request, runtime: runtime)
        case "quit":        return quit(request, runtime: runtime)
        case "crash":       return crash(request)
        case "list_actions": return listActions(request, runtime: runtime)
        case "invoke_action": return invokeAction(request, runtime: runtime)
        case "ping":        return RemoteResponse(id: request.id, ok: true)
        default:
            return RemoteResponse(id: request.id, ok: false, error: "unknown cmd: \(request.cmd)")
        }
    }

    // MARK: Input injection

    private func sendKey(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let keyName = request.key else {
            return RemoteResponse(id: request.id, ok: false, error: "send_key requires `key`")
        }
        guard let key = parseKey(keyName) else {
            return RemoteResponse(id: request.id, ok: false, error: "unknown key: \(keyName)")
        }
        guard let modifiers = parseModifiers(request.modifiers ?? []) else {
            return RemoteResponse(id: request.id, ok: false,
                                  error: "unknown modifier in \(request.modifiers ?? [])")
        }
        // `source: .remote` tags every dispatcher-injected event so the
        // debug input log + downstream audit machinery can distinguish MCP
        // from stdin presses without heuristics.
        runtime.enqueueEvent(.key(KeyEvent(key: key, modifiers: modifiers, source: .remote)))
        return RemoteResponse(id: request.id, ok: true)
    }

    private func sendText(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let text = request.text else {
            return RemoteResponse(id: request.id, ok: false, error: "send_text requires `text`")
        }
        for char in text {
            let key: Key
            switch char {
            case "\n": key = .enter
            case "\t": key = .tab
            default: key = .character(char)
            }
            runtime.enqueueEvent(.key(KeyEvent(key: key, source: .remote)))
        }
        return RemoteResponse(id: request.id, ok: true)
    }

    /// Inject a mouse event so smoke tests can drive hover/click/scroll
    /// over the remote-control socket. SGR 1006 byte sequences are not
    /// reproducible from the test harness (no PTY mouse emulation), so
    /// we synthesise `MouseEvent` values directly. The runtime's event
    /// loop handles them identically to real terminal mouse input.
    private func sendMouse(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let kind = request.kind else {
            return RemoteResponse(id: request.id, ok: false, error: "send_mouse requires `kind`")
        }
        guard let x = request.x, let y = request.y else {
            return RemoteResponse(id: request.id, ok: false, error: "send_mouse requires `x` + `y`")
        }
        guard let modifiers = parseModifiers(request.modifiers ?? []) else {
            return RemoteResponse(id: request.id, ok: false,
                                  error: "unknown modifier in \(request.modifiers ?? [])")
        }
        let buttonName = request.button ?? "left"
        let button: MouseButton
        switch buttonName {
        case "left":   button = .left
        case "middle": button = .middle
        case "right":  button = .right
        default:
            return RemoteResponse(id: request.id, ok: false, error: "unknown button: \(buttonName)")
        }

        switch kind {
        case "move":
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .moved, x: x, y: y, modifiers: modifiers)))
        case "press":
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .press(button), x: x, y: y, modifiers: modifiers)))
        case "release":
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .release(button), x: x, y: y, modifiers: modifiers)))
        case "click":
            // A click is press + release at the same coordinate. Most
            // handlers respond to .press; emitting both keeps drag-aware
            // listeners happy too.
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .press(button), x: x, y: y, modifiers: modifiers)))
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .release(button), x: x, y: y, modifiers: modifiers)))
        case "wheel_up":
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .scrollUp, x: x, y: y, modifiers: modifiers)))
        case "wheel_down":
            runtime.enqueueEvent(.mouse(MouseEvent(kind: .scrollDown, x: x, y: y, modifiers: modifiers)))
        default:
            return RemoteResponse(id: request.id, ok: false, error: "unknown mouse kind: \(kind)")
        }
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Focus

    private func focusGet(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        let engine = runtime.remoteFocusEngine()
        guard let id = engine.keyboardFocusID,
              let root = runtime.remoteCurrentGraphRoot(),
              let node = engine.findNode(id: id, in: root) else {
            let info = FocusInfo(nodeID: nil, kind: nil, rect: [], value: nil)
            return RemoteResponse(id: request.id, ok: true, result: RemoteResult(focus: info))
        }
        let info = FocusInfo(
            nodeID: String(describing: id),
            kind: node.kind.debugName,
            rect: [node.rect.x, node.rect.y, node.rect.width, node.rect.height],
            value: nodeValue(node)
        )
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(focus: info))
    }

    private func focusSet(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        // Target by node-id string (stringified NodeID). Requires caller to
        // have obtained the id from `focus_get` or `query_tree` — nothing
        // else is stable across graph builds.
        guard let target = request.text ?? request.key else {
            return RemoteResponse(id: request.id, ok: false, error: "focus_set requires node id in `text`")
        }
        let engine = runtime.remoteFocusEngine()
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: false, error: "no graph root")
        }
        guard let match = findNodeByDescribedID(target, in: root) else {
            return RemoteResponse(id: request.id, ok: false, error: "node not found: \(target)")
        }
        engine.keyboardFocusID = match.id
        runtime.remoteRequestFrame()
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Cell / tree queries

    private func queryCells(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let buffer = runtime.remotePreviousBuffer() else {
            return RemoteResponse(id: request.id, ok: false, error: "no rendered frame yet")
        }
        // `parseRect` already clamps to buffer size for an `ok: false` signal
        // never to panic the runtime — rect rejection is a soft error, not
        // a precondition failure. Hostile or buggy clients sending
        // `[-1, -1, 999_999, 999_999]` should get a non-empty ok response
        // instead of crashing the app.
        let (x, y, w, h) = clampRect(request.rect, bufferWidth: buffer.width, bufferHeight: buffer.height)
        var rows: [String] = []
        let lastRow = min(y + h, buffer.height)
        let lastCol = min(x + w, buffer.width)
        if lastRow > y && lastCol > x {
            for row in y..<lastRow {
                var line = ""
                for col in x..<lastCol {
                    line.append(buffer[col, row].character)
                }
                rows.append(line)
            }
        }

        var rulerTop: [String]? = nil
        var rulerLeft: [String]? = nil
        if request.grid == true {
            let safeWidth = max(0, lastCol - x)
            rulerTop = buildColumnRuler(startX: x, width: safeWidth)
            rulerLeft = buildRowRuler(startY: y, height: rows.count)
        }
        let slice = CellSlice(x: x, y: y, width: w, height: h, rows: rows,
                              rulerTop: rulerTop, rulerLeft: rulerLeft)
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(cells: slice))
    }

    // MARK: Inspector — range + scan

    /// Probe every cell in the requested rect (or default to 1×1 at (x, y))
    /// and return the declared info for each. Reduces MCP round-trips when
    /// the client wants to see "all nodes in this area" in one shot. The
    /// crosshair also moves to the first cell of the range so the user sees
    /// the probe live.
    private func inspectRange(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: false, error: "no graph root")
        }
        let buffer = runtime.remotePreviousBuffer()
        let bufferW = buffer?.width ?? 80
        let bufferH = buffer?.height ?? 24
        // Clamp width/height to non-negative + buffer-bounded, so a client
        // asking for `[0, 0, 999999, 999999]` gets a constrained response
        // instead of a 999999²-cell allocation. Clients that want the whole
        // frame can omit rect entirely.
        let (rx, ry, rw, rh): (Int, Int, Int, Int)
        if let r = request.rect, r.count == 4 {
            rx = max(0, min(bufferW, r[0]))
            ry = max(0, min(bufferH, r[1]))
            rw = max(0, min(bufferW - rx, r[2]))
            rh = max(0, min(bufferH - ry, r[3]))
        } else {
            let x = max(0, min(bufferW - 1, request.x ?? runtime.remoteInspector().cursorX))
            let y = max(0, min(bufferH - 1, request.y ?? runtime.remoteInspector().cursorY))
            (rx, ry, rw, rh) = (x, y, 1, 1)
        }

        // Move the crosshair to the upper-left of the requested range so the
        // user watching the app sees where MCP is probing.
        let inspector = runtime.remoteInspector()
        inspector.moveCursor(dx: rx - inspector.cursorX, dy: ry - inspector.cursorY,
                             maxX: bufferW, maxY: bufferH)

        var probes: [InspectorProbe] = []
        let capacity = min(rw * rh, 4096)
        probes.reserveCapacity(capacity)  // guardrail for huge rects
        if rh > 0 && rw > 0 {
            for y in ry..<(ry + rh) where probes.count < 4096 {
                for x in rx..<(rx + rw) where probes.count < 4096 {
                    probes.append(makeProbe(x: x, y: y, root: root, inspector: inspector))
                }
            }
        }
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(probes: probes))
    }

    /// Sweep the graph (not cells) looking for the first node whose kind
    /// matches `matchKind` or whose text contains `matchText`, or the
    /// currently-focused node when `matchFocused=true`. Returns an
    /// `InspectorProbe` for the match's rect. Cheaper than scanning cells
    /// because it walks the AttributeGraph directly.
    private func scan(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: false, error: "no graph root")
        }
        let inspector = runtime.remoteInspector()
        if request.matchFocused == true {
            if let id = runtime.remoteFocusEngine().keyboardFocusID,
               let node = runtime.remoteFocusEngine().findNode(id: id, in: root) {
                let probe = InspectorProbe(
                    cursorX: node.rect.x, cursorY: node.rect.y,
                    active: inspector.active,
                    nodeKind: node.kind.debugName,
                    nodeRect: [node.rect.x, node.rect.y, node.rect.width, node.rect.height],
                    declared: ["type": node.kind.debugName],
                    modifierChain: []
                )
                return RemoteResponse(id: request.id, ok: true, result: RemoteResult(inspector: probe))
            }
            return RemoteResponse(id: request.id, ok: false, error: "no keyboard focus")
        }
        if let match = findNode(in: root, matchKind: request.matchKind, matchText: request.matchText) {
            let probe = InspectorProbe(
                cursorX: match.rect.x, cursorY: match.rect.y,
                active: inspector.active,
                nodeKind: match.kind.debugName,
                nodeRect: [match.rect.x, match.rect.y, match.rect.width, match.rect.height],
                declared: ["type": match.kind.debugName, "text": nodeValue(match) ?? ""],
                modifierChain: []
            )
            return RemoteResponse(id: request.id, ok: true, result: RemoteResult(inspector: probe))
        }
        return RemoteResponse(id: request.id, ok: false, error: "no match")
    }

    private func findNode(in node: AttributeNode, matchKind: String?, matchText: String?) -> AttributeNode? {
        // Match test — either criterion is optional; non-nil criteria must
        // all pass. A call with both nil never matches (use query_tree for
        // that).
        if matchKind != nil || matchText != nil {
            var ok = true
            if let want = matchKind {
                ok = ok && node.kind.debugName.caseInsensitiveCompare(want) == .orderedSame
            }
            if let want = matchText, let value = nodeValue(node) {
                ok = ok && value.contains(want)
            } else if matchText != nil {
                ok = false
            }
            if ok { return node }
        }
        for child in node.children {
            if let m = findNode(in: child, matchKind: matchKind, matchText: matchText) {
                return m
            }
        }
        return nil
    }

    private func makeProbe(x: Int, y: Int, root: AttributeNode, inspector: Inspector) -> InspectorProbe {
        let result = HitTest.nodeAt(x: x, y: y, root: root)
        var declared: [String: String] = [:]
        var chain: [String] = []
        var kind: String? = nil
        var nodeRect: [Int]? = nil
        if let result {
            for (k, v) in result.declaredValues { declared[k] = v }
            chain = result.modifierChain
            kind = declared["type"] ?? declared["modifier"]
            let r = result.resolvedRect
            nodeRect = [r.x, r.y, r.width, r.height]
        }
        return InspectorProbe(
            cursorX: x, cursorY: y, active: inspector.active,
            nodeKind: kind, nodeRect: nodeRect,
            declared: declared, modifierChain: chain
        )
    }

    // MARK: Grid rulers

    /// Build three-row column labels so wide rulers (col > 99) still fit in
    /// a monospace layout. Row 0 is hundreds, row 1 tens, row 2 ones; cells
    /// where the higher digits are zero show a space.
    private func buildColumnRuler(startX: Int, width: Int) -> [String] {
        var hundreds = ""
        var tens = ""
        var ones = ""
        for x in startX..<(startX + width) {
            let h = (x / 100) % 10
            let t = (x / 10) % 10
            let o = x % 10
            hundreds.append(h == 0 ? " " : Character(String(h)))
            tens.append((h == 0 && t == 0) ? " " : Character(String(t)))
            ones.append(Character(String(o)))
        }
        return [hundreds, tens, ones]
    }

    /// Per-row ruler strings, right-padded to the max width so callers can
    /// concatenate `rulerLeft[i] + "|" + rows[i]` cleanly.
    private func buildRowRuler(startY: Int, height: Int) -> [String] {
        let maxValue = startY + height - 1
        let width = max(2, String(maxValue).count)
        var out: [String] = []
        for y in startY..<(startY + height) {
            let s = String(y)
            let padded = String(repeating: " ", count: width - s.count) + s
            out.append(padded)
        }
        return out
    }

    private func queryTree(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: false, error: "no graph root")
        }
        let tree = DebugStream.shared.buildDebugNode(root, depth: 0)
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(tree: tree))
    }

    // MARK: Inspector

    private func inspectorProbe(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        let x = request.x ?? runtime.remoteInspector().cursorX
        let y = request.y ?? runtime.remoteInspector().cursorY
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: false, error: "no graph root")
        }
        let inspector = runtime.remoteInspector()
        let result = HitTest.nodeAt(x: x, y: y, root: root)
        var declared: [String: String] = [:]
        var chain: [String] = []
        var kind: String? = nil
        var nodeRect: [Int]? = nil
        if let result {
            for (k, v) in result.declaredValues { declared[k] = v }
            chain = result.modifierChain
            kind = declared["type"] ?? declared["modifier"]
            let r = result.resolvedRect
            nodeRect = [r.x, r.y, r.width, r.height]
        }
        let probe = InspectorProbe(
            cursorX: x, cursorY: y, active: inspector.active,
            nodeKind: kind, nodeRect: nodeRect,
            declared: declared, modifierChain: chain
        )
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(inspector: probe))
    }

    private func inspectorMove(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let x = request.x, let y = request.y else {
            return RemoteResponse(id: request.id, ok: false, error: "inspector_move requires `x` and `y`")
        }
        let inspector = runtime.remoteInspector()
        let buffer = runtime.remotePreviousBuffer()
        let maxX = buffer?.width ?? 0
        let maxY = buffer?.height ?? 0
        // Move by dx/dy from current cursor; simpler for MCP to pass an
        // absolute target by computing the delta client-side.
        inspector.moveCursor(dx: x - inspector.cursorX, dy: y - inspector.cursorY,
                             maxX: maxX, maxY: maxY)
        runtime.remoteRequestFrame()
        return RemoteResponse(id: request.id, ok: true)
    }

    private func inspectorToggle(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        runtime.remoteInspector().toggle()
        runtime.remoteRequestFrame()
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Misc

    private func frameNumber(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        let n = runtime.remoteCurrentFrameNumber()
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(frame: n))
    }

    private func terminalInput(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        RemoteResponse(id: request.id, ok: true,
                       result: RemoteResult(terminalInput: runtime.remoteTerminalInputTaken()))
    }

    private func screenshot(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        runtime.remoteRequestCapture()
        // Path isn't known until captureFrame fires — client polls `query_cells`
        // or uses `frame_number` + filesystem sidechannel to locate the file.
        return RemoteResponse(id: request.id, ok: true)
    }

    /// Crash the app as a fault in its own code would: raise SIGSEGV on the
    /// main thread, once this reply has gone out. For tests of what a crash
    /// leaves behind.
    ///
    /// Not `kill -SEGV` from outside, which may land on any thread. Worker
    /// threads leave the fault signals unblocked on purpose — a fault there
    /// with its signal blocked is killed by the kernel outright, so masking
    /// them would lose every real crash on a worker — and under Thread
    /// Sanitizer a worker the sanitizer has not set up faulted in the handler
    /// that way, so a crash test passed or failed by chance.
    private func crash(_ request: RemoteRequest) -> RemoteResponse {
        Task { @MainActor in
            _ = raise(SIGSEGV)
        }
        return RemoteResponse(id: request.id, ok: true)
    }

    /// Tell the runtime to exit cleanly. We inject a Ctrl+C so the runtime's
    /// existing "universal quit" path fires (same as a user pressing Ctrl+C).
    /// That tears down raw mode, the alternate screen, and sockets — avoids
    /// the orphaned-socket mess that `pkill -9` leaves behind.
    private func quit(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        runtime.enqueueEvent(.key(KeyEvent(key: .character("c"), modifiers: [.ctrl], source: .remote)))
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Action graph (remote control + scope dispatch)

    /// Enumerate the action graph reachable from the focused node.
    /// Includes framework defaults so LLM clients see Ctrl+C → app.quit
    /// and Esc → app.dismissOrQuit alongside any user-declared actions.
    /// Disabled actions are returned with `enabled: false` so an agent
    /// can introspect "what's currently unavailable here."
    private func listActions(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: true, result: RemoteResult(actions: []))
        }
        let focused = runtime.remoteFocusEngine().focusedNode(in: root) ?? root
        let defaults = runtime.remoteFrameworkDefaultsScope()

        // Reachable actions, deduped by ID, innermost-first.
        let actions = ActionDispatch.reachableActions(from: focused, frameworkDefaults: defaults)

        // For each action, collect every binding that reaches it from
        // the focus chain. Walk the scope chain locally so we can
        // pair (action, binding) — ActionDispatch.reachableActions
        // gives us actions only.
        let scopes = collectScopes(from: focused, frameworkDefaults: defaults)
        let bindings = bindingsByActionID(scopes: scopes)

        let infos = actions.map { action in
            ActionRemoteInfo(
                id: action.id.raw,
                title: action.title.resolved(),
                description: action.description?.resolved(),
                enabled: action.isEnabled,
                bindings: bindings[action.id] ?? []
            )
        }
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(actions: infos))
    }

    /// Fire an action by stable ID. Wraps `ActionDispatch.invoke` so
    /// LLMs / scripts / debuggers can drive the app without simulating
    /// keystrokes. Returns `fired: true` when an enabled action with
    /// the requested ID existed in scope and its handler ran.
    private func invokeAction(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        guard let actionID = request.actionId else {
            return RemoteResponse(id: request.id, ok: false, error: "invoke_action requires `action_id`")
        }
        guard let root = runtime.remoteCurrentGraphRoot() else {
            return RemoteResponse(id: request.id, ok: true, result: RemoteResult(fired: false))
        }
        let focused = runtime.remoteFocusEngine().focusedNode(in: root) ?? root
        let defaults = runtime.remoteFrameworkDefaultsScope()
        let fired = ActionDispatch.invoke(
            id: ActionID(actionID),
            from: focused,
            frameworkDefaults: defaults
        )
        if fired { runtime.remoteRequestFrame() }
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(fired: fired))
    }

    /// Walk focused node → root collecting scopes; appends framework
    /// defaults at the outermost end if provided. Mirrors
    /// `ActionDispatch.scopeChain` (which is private on the dispatcher).
    private func collectScopes(from node: AttributeNode, frameworkDefaults: ActionScope?) -> [ActionScope] {
        var scopes: [ActionScope] = []
        var current: AttributeNode? = node
        while let n = current {
            if let scope = n._actionScope {
                scopes.append(scope)
            }
            current = n.parent
        }
        if let defaults = frameworkDefaults {
            scopes.append(defaults)
        }
        return scopes
    }

    /// Build a map ActionID → [BindingRemoteInfo] by walking every
    /// scope and grouping bound actions by their action ID.
    /// Innermost-first: the first scope mentioning an action owns its
    /// bindings list; outer-scope rebindings of the same ID are
    /// shadowed (matches dispatch precedence).
    private func bindingsByActionID(scopes: [ActionScope]) -> [ActionID: [ActionBindingRemoteInfo]] {
        var ownedBy: [ActionID: Int] = [:]  // first scope index that owns this ID
        var out: [ActionID: [ActionBindingRemoteInfo]] = [:]
        for (i, scope) in scopes.enumerated() {
            for bound in scope.boundActions {
                let id = bound.action.id
                if ownedBy[id] == nil {
                    ownedBy[id] = i
                }
                if ownedBy[id] == i {
                    out[id, default: []].append(serializeBinding(bound.binding))
                }
                // Outer scopes that re-bind a shadowed ID contribute nothing.
            }
        }
        return out
    }

    private func serializeBinding(_ binding: InputBinding) -> ActionBindingRemoteInfo {
        switch binding {
        case .keyboard(let key, let mods):
            return ActionBindingRemoteInfo(
                kind: "keyboard",
                key: serializeKey(key),
                modifiers: serializeModifiers(mods),
                button: nil,
                payload: nil
            )
        case .mouse(let button, let mods):
            return ActionBindingRemoteInfo(
                kind: "mouse",
                key: nil,
                modifiers: serializeModifiers(mods),
                button: serializeMouseButton(button),
                payload: nil
            )
        case .gesture(let id):
            return ActionBindingRemoteInfo(kind: "gesture", payload: id.raw)
        case .voice(let phrase):
            return ActionBindingRemoteInfo(kind: "voice", payload: phrase)
        case .accessibility(let label):
            return ActionBindingRemoteInfo(kind: "accessibility", payload: label)
        }
    }

    private func serializeKey(_ key: Key) -> String {
        switch key {
        case .character(let c): return String(c)
        case .enter: return "enter"
        case .tab: return "tab"
        case .escape: return "escape"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        case .f(let n): return "f\(n)"
        case .unknown: return "unknown"
        case .activate: return "activate"
        }
    }

    private func serializeModifiers(_ mods: KeyModifiers) -> [String]? {
        var out: [String] = []
        if mods.contains(.shift) { out.append("shift") }
        if mods.contains(.alt) { out.append("alt") }
        if mods.contains(.ctrl) { out.append("ctrl") }
        return out.isEmpty ? nil : out
    }

    private func serializeMouseButton(_ button: MouseButton) -> String {
        switch button {
        case .left: return "left"
        case .middle: return "middle"
        case .right: return "right"
        }
    }

    // MARK: Helpers

    /// A key by the name ``KeyCombo`` gives it, or a single character, kept
    /// in its case: `send-key A` types a capital.
    private func parseKey(_ name: String) -> Key? {
        if name.count == 1, let character = name.first { return .character(character) }
        return KeyCombo.keyName(named: name).map(Key.init)
    }

    /// Modifiers by the names ``KeyCombo`` gives them; nil if one is not a
    /// modifier.
    private func parseModifiers(_ names: [String]) -> KeyModifiers? {
        var modifiers: KeyModifiers = []
        for name in names {
            guard let modifier = KeyCombo.modifier(named: name) else { return nil }
            modifiers.insert(KeyModifiers(modifier))
        }
        return modifiers
    }

    private func parseRect(_ raw: [Int]?, defaultWidth: Int, defaultHeight: Int) -> (Int, Int, Int, Int) {
        guard let r = raw, r.count >= 4 else {
            return (0, 0, defaultWidth, defaultHeight)
        }
        return (r[0], r[1], r[2], r[3])
    }

    /// Normalise a remote-supplied rect to non-negative, buffer-relative
    /// coordinates. The dispatcher treats rect arguments as hints, never
    /// preconditions — any adversarial or buggy client that sends a
    /// negative origin or a width larger than the buffer ends up with an
    /// ok response containing the intersection with the buffer, not a
    /// panic. Returns (x, y, w, h) after clamping but preserves the
    /// caller's requested (w, h) in the response so they can verify clip.
    private func clampRect(_ raw: [Int]?, bufferWidth: Int, bufferHeight: Int) -> (Int, Int, Int, Int) {
        let (rx, ry, rw, rh) = parseRect(raw, defaultWidth: bufferWidth, defaultHeight: bufferHeight)
        let x = max(0, min(bufferWidth, rx))
        let y = max(0, min(bufferHeight, ry))
        let w = max(0, rw)
        let h = max(0, rh)
        return (x, y, w, h)
    }

    private func nodeValue(_ node: AttributeNode) -> String? {
        if case .primitive(.text(let spans)) = node.kind {
            return spans.map(\.text).joined()
        }
        return nil
    }

    /// Match a node by its stringified `NodeID`. Walks the tree because
    /// `NodeID` isn't a `String` primitive and we don't ship a lookup map
    /// yet. For the expected usage — a test that just retrieved the id via
    /// `query_tree` and wants to focus it — linear scan is fine.
    private func findNodeByDescribedID(_ described: String, in node: AttributeNode) -> AttributeNode? {
        if String(describing: node.id) == described { return node }
        for child in node.children {
            if let m = findNodeByDescribedID(described, in: child) { return m }
        }
        return nil
    }
}

// MARK: - POSIX shim

// Some platforms don't expose `read` / `write` as the raw C names in Swift;
// provide a tiny wrapper matching the `posix*` naming used elsewhere in the
// module (see `DebugStream.posixWrite`).
@inlinable
func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return read(fd, buf, count)
    #else
    return read(fd, buf, count)
    #endif
}

#endif
