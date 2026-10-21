#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import TerminalUIConfig
import TerminalLog
import Synchronization

// Module-level logger for framework warnings that fall through when no
// inspector sink is attached. Routes via TerminalLog so capability
// detection (NO_COLOR / piped) and SGR coloring come for free; warn
// level routes to stderr so CI / oncall greps still see the message.
private let log = Log("TerminalUI")

// MARK: - Debug Protocol

// Structured debug events emitted by the framework.
// Consumed by in-app overlay, file logger, or external tools via socket.
// JSON-lines format — one JSON object per line, easy to parse from any language.

#if DEBUG

/// A structured debug event flowing through ``DebugStream`` to every
/// attached ``DebugSink`` — the in-app panel, file loggers, and the
/// remote-control socket all consume this one type. Payload structs are
/// `Codable` so sinks can serialize them as JSON lines.
public enum DebugEvent: Sendable {
    /// A frame is about to build; payload carries the previous frame's stats.
    case frameStart(FrameDebugInfo)
    /// A frame finished; payload carries its measured timings and delta sizes.
    case frameEnd(FrameDebugInfo)
    /// A single graph node changed — finer-grained than a full ``graphSnapshot(_:)``.
    case nodeUpdate(NodeDebugInfo)
    /// A parsed input event (key plus modifiers) reached the runtime.
    case inputEvent(InputDebugInfo)
    /// An observed state property changed, with old and new values stringified.
    case stateChange(StateDebugInfo)
    /// The terminal was resized; payload is (columns, rows) in cells.
    case resize(Int, Int)
    /// A full attribute-graph tree dump for one frame — what `swtui ctl tree` shows.
    case graphSnapshot(GraphDebugSnapshot)
    /// Framework-emitted warning about a knowable composition bug or
    /// suspicious modifier pairing. SwiftUI's analog: runtime warnings
    /// via `os_log`. See `FrameworkWarningCode` for stable identifiers
    /// users can grep CI output for or suppress per-app.
    case frameworkWarning(FrameworkWarningInfo)
}

/// Stable identifiers for framework warnings. Strings are the on-wire
/// form (in JSON-lines logs and remote-control payloads) so adding
/// cases is backward-compatible.
public enum FrameworkWarningCode: String, Sendable, Hashable, Codable {
    /// `.onHover` is registered on a node whose effective
    /// `MouseFocusPolicy` is `.hoverFollows`. The framework will move
    /// keyboard focus on hover AND fire the user callback. Almost
    /// always means the user wanted `.disabled` for full SwiftUI-style
    /// control. Suppress with
    /// `DebugStream.shared.suppressWarning(.onHoverWithHoverFollows)`
    /// if the duplication is intentional.
    case onHoverWithHoverFollows
    /// `@TerminalState`'s `$projectedValue` was read at a moment when
    /// `GraphContext.currentNode` was nil. The binding falls back to
    /// the initial value and writes will silently no-op. Almost always
    /// means the user projected `$state` inside a deferred closure
    /// (e.g. inside `GeometryReader { ... }`) — project in `body`
    /// outside the closure and capture the binding instead. The
    /// canary case was TreeView before its body bindings were lifted
    /// out of its `GeometryReader` closure.
    case bindingProjectedWithoutNode
    /// A child node tried to write cells outside its assigned rect.
    /// The framework silently dropped them (clip enforcement) but
    /// dropping cells in production is almost always a layout bug.
    /// Suppress per-subtree with `.overflowOK()` when the escape is
    /// intentional (shadows, popovers, edge-to-edge banners).
    case componentOverflow
    /// A presented modal's content does not fit the terminal and was
    /// clipped. Dangerous rather than merely ugly: controls scrolled out
    /// of the visible area remain focusable, so Tab reaches buttons the
    /// user cannot see. Terminal size is a runtime value — the same
    /// dialog fits one window and not another, and the user can resize
    /// mid-session — so this cannot be caught at compile time.
    /// Shrink the content, or gate presentation on available size.
    case modalDoesNotFit
    /// An alert declared more than one `.default` action. Return activates
    /// the focused button, so a second default is unreachable by the key
    /// users expect to trigger it — and which of the two takes initial
    /// focus becomes declaration-order trivia. Give the secondary actions
    /// `.cancel` or `.destructive`.
    case alertMultipleDefaultActions
    /// An alert was presented with no actions. Nothing would be focusable
    /// inside it, so Tab and Return have no target; the framework renders a
    /// lone dismiss button rather than leave an inescapable box on screen.
    case alertHasNoActions
    /// An Option/Alt-modified binding was registered on a terminal that does
    /// not report whether Option arrives as a Meta prefix. On stock Apple
    /// Terminal it does not — Option+R composes to `®` and the binding can
    /// never fire — and the setting is not exposed to any escape query, so the
    /// framework cannot tell a configured terminal from an unconfigured one.
    /// Suppress with
    /// `DebugStream.shared.suppressWarning(.optionAsMetaUnconfirmed)` once the
    /// app has explained the requirement its own way.
    case optionAsMetaUnconfirmed
    /// A `Picker` declared the same tag on more than one option. The first
    /// declaration wins, which leaves the later rows unreachable: selecting
    /// them would commit a value already owned by an earlier row. Silently
    /// rendering both would show a list where two rows appear identical to
    /// the selection logic but distinct to the user.
    case pickerDuplicateTags
    /// A bounded-value control (`Slider`, `Stepper`, `Gauge`) was given an
    /// upper bound below its lower bound. That is a programmer error rather
    /// than user input, so the control renders disabled instead of guessing
    /// which end was intended — silently swapping them would show a range the
    /// caller never asked for.
    case boundedValueInvertedBounds
    /// A `NavigationStack` was handed a value whose type has no matching
    /// `.navigationDestination(for:)`. The screen cannot be built, so the
    /// framework shows a placeholder rather than a blank screen the user would
    /// read as a crash. Register a destination for that type.
    case navigationNoDestination
}

/// One emitted framework warning — the payload of
/// `DebugEvent.frameworkWarning`.
public struct FrameworkWarningInfo: Sendable, Codable {
    /// Which misuse fired; see ``FrameworkWarningCode``.
    public var code: FrameworkWarningCode
    /// Human-readable explanation with the suggested fix.
    public var message: String
    /// Path-formatted node ID (e.g. `"0.1.2"`) so users can grep for a
    /// specific offending view. May be empty when the warning fires
    /// outside graph construction.
    public var nodeID: String

    /// Creates a warning record; `(code, nodeID, message)` is also the
    /// dedupe key emit uses.
    public init(code: FrameworkWarningCode, message: String, nodeID: String) {
        self.code = code
        self.message = message
        self.nodeID = nodeID
    }
}

/// Per-frame performance record carried by ``DebugEvent/frameStart(_:)``
/// and ``DebugEvent/frameEnd(_:)``.
public struct FrameDebugInfo: Codable, Sendable {
    /// Monotonic frame counter since app start.
    public var frameNumber: Int
    /// When the frame was recorded — process uptime, in seconds.
    public var timestamp: Double
    /// Time to rebuild the view value, update the graph, and render into
    /// the cell buffer, in milliseconds.
    public var buildTimeMs: Double
    /// Time spent writing the frame's delta to the terminal, in milliseconds.
    public var flushTimeMs: Double
    /// Bytes of ANSI output written for this frame's delta.
    public var bytesWritten: Int
    /// Cells that differed from the previous frame and were rewritten.
    public var cellsChanged: Int
    /// Total cells in the grid (columns x rows) — the denominator for ``cellsChanged``.
    public var totalCells: Int
    /// Measured frames per second at the time of recording.
    public var fps: Double
    /// Nodes in the attribute graph this frame.
    public var nodeCount: Int
    /// Graph nodes marked dirty going into this frame — how much of the
    /// tree the update pass actually had to touch.
    public var dirtyNodeCount: Int
}

/// Flat serialized record of one graph node, for debug event payloads.
public struct NodeDebugInfo: Codable, Sendable {
    /// Path-formatted node ID (e.g. `"0.1.2"`).
    public var id: String
    /// The node's kind name (`Text`, `VStack`, modifier name…).
    public var kind: String
    /// Laid-out rect as `[x, y, width, height]` in cells.
    public var rect: [Int]
    /// Whether the node was marked dirty when recorded.
    public var isDirty: Bool
    /// Number of direct children.
    public var childCount: Int
    /// Kind-specific payload summary — text content, progress fraction,
    /// spinner frame…
    public var value: String
}

/// One parsed input event, as logged by the debug input trail.
public struct InputDebugInfo: Codable, Sendable {
    /// Process uptime when the event arrived, in seconds.
    public var timestamp: Double
    /// The parsed key's name.
    public var key: String
    /// Modifier names held with it; empty for a bare key.
    public var modifiers: String
}

/// One recorded `@TerminalState` mutation, for the debug state trail.
public struct StateDebugInfo: Codable, Sendable {
    /// Process uptime at mutation, in seconds.
    public var timestamp: Double
    /// The mutated property's name.
    public var property: String
    /// The Swift type name of the view owning the property.
    public var viewType: String
    /// String rendering of the value before the mutation.
    public var oldValue: String
    /// String rendering of the value after the mutation.
    public var newValue: String
}

/// A whole-graph capture at one frame — the payload of
/// `DebugEvent.graphSnapshot`.
public struct GraphDebugSnapshot: Codable, Sendable {
    /// The frame the snapshot was taken on.
    public var frameNumber: Int
    /// The root-level nodes; each nests its subtree.
    public var nodes: [GraphDebugNode]
}

/// Serializable snapshot of one attribute-graph node, nested to form the
/// tree returned by the `query_tree` socket command and shown in the F2
/// panel's graph view.
public struct GraphDebugNode: Codable, Sendable {
    /// Path-formatted node ID (e.g. `"0.1.2"`) — stable across frames while
    /// the node persists, greppable in warnings and traces.
    public var id: String
    /// Short kind tag: `"text"`, `"vstack"`, `"padding"`, `"view"`, etc.
    public var kind: String
    /// Depth in the tree; the root is 0.
    public var depth: Int
    /// Layout rect as `[x, y, width, height]` in cell coordinates.
    public var rect: [Int]
    /// Whether the node was marked dirty when the snapshot was taken.
    public var isDirty: Bool
    /// Number of direct children (same as `children.count`, kept flat for
    /// consumers that strip the nested array).
    public var childCount: Int
    /// Kind-specific summary: truncated text content, `"75%"` for progress,
    /// child count for stacks, modifier argument for modifiers.
    public var value: String
    /// Child snapshots in layout order.
    public var children: [GraphDebugNode]
}

// MARK: - Debug Stream

/// Emits debug events to one or more sinks.
/// Sinks can be: in-memory buffer (for overlay), file, socket.
///
/// The hub of the debug pipeline: framework code emits ``DebugEvent``s and
/// framework warnings into ``shared``, and whatever sinks are attached
/// receive them synchronously on the render thread. The runtime attaches
/// the built-in sinks per the `.terminalui/terminalui.toml` config; a
/// harness or test attaches its own probe via ``addSink(_:)`` (and detaches
/// it with `removeAllSinks()` between cases). Warnings additionally have a
/// no-sink fallback — stderr normally, the `warnings.log` file while a live
/// TUI owns the terminal — plus per-code suppression and per-session
/// dedupe. In release builds the class is a stub and every call disappears.
public final class DebugStream: Sendable {
    /// Process-wide instance every framework emit site reports to.
    public static let shared = DebugStream()

    /// Everything the stream knows, behind one lock: emit sites run on the
    /// render path, the input task and tests running in parallel.
    private struct State {
        var sinks: [any DebugSink] = []
        var enabled = false
        var suppressedWarnings: Set<FrameworkWarningCode> = []
        /// Set when a `TerminalApp` is in raw mode and OWNS the visible
        /// terminal. While true, `emitWarning`'s stderr fallback is
        /// disabled — printing to stderr would corrupt the rendered
        /// viewport. Warnings still reach in-process sinks (debug panel,
        /// remote socket) and the on-disk warnings log.
        var isLiveTUI = false
        /// Dedupe set for `emitWarning`. A misbehaving node typically
        /// re-fires the same `(code, message)` every frame; flooding the
        /// terminal (or a log file) at 60+ Hz is unusable. Each unique
        /// pair fires AT MOST ONCE per session — same posture as SwiftUI
        /// runtime warnings. Cleared by `resetWarningDedup()` for tests.
        var seenWarnings: Set<String> = []
        /// Path to the warnings log file (set when DiagPaths reports a
        /// data dir). Lazily appended via `Foundation.FileHandle`.
        var warningsLogURL: URL?
    }

    private let state = Mutex(State())

    private init() {}

    /// Attach a sink and enable the stream. Every subsequent event reaches
    /// this sink until `removeAllSinks()` — there is no per-sink removal.
    public func addSink(_ sink: any DebugSink) {
        state.withLock { state in
            state.sinks.append(sink)
            state.enabled = true
        }
    }

    /// Detach every sink. Used by tests between cases so probe sinks
    /// from one test don't leak into the next.
    public func removeAllSinks() {
        // `enabled` stays true so framework warnings still fire to the
        // stderr fallback when no sinks are attached. The fallback is
        // what makes warnings reach developers who never wired up an
        // inspector — same posture as SwiftUI's os_log reaching Console.
        state.withLock { $0.sinks.removeAll(keepingCapacity: true) }
    }

    /// Suppress a framework warning by code. Subsequent emits with
    /// that code are dropped before reaching any sink or stderr.
    /// Mirrors SwiftUI's per-warning silencing pattern. Idempotent.
    public func suppressWarning(_ code: FrameworkWarningCode) {
        _ = state.withLock { $0.suppressedWarnings.insert(code) }
    }

    /// Re-enable a previously-suppressed warning code.
    public func unsuppressWarning(_ code: FrameworkWarningCode) {
        _ = state.withLock { $0.suppressedWarnings.remove(code) }
    }

    /// Clear all suppressions. Used by tests between cases.
    public func unsuppressAllWarnings() {
        state.withLock { $0.suppressedWarnings.removeAll(keepingCapacity: true) }
    }

    /// Whether ``suppressWarning(_:)`` is currently in effect for `code`.
    public func isWarningSuppressed(_ code: FrameworkWarningCode) -> Bool {
        state.withLock { $0.suppressedWarnings.contains(code) }
    }

    /// Mark the runtime as in-or-out of the "owns the terminal" state.
    /// Called by `TerminalApp.run()` around its raw-mode lifetime.
    /// While true, framework warnings DO NOT fall back to stderr —
    /// they'd corrupt the rendered viewport. They route to the
    /// `warnings.log` in the app's data dir instead so developers can
    /// grep them after exit (or during, via `tail -f`).
    public func setLiveTUI(_ live: Bool, logFileURL: URL? = nil) {
        state.withLock { state in
            state.isLiveTUI = live
            state.warningsLogURL = logFileURL
        }
    }

    /// Clear the per-session warning dedupe set. Tests call this
    /// between cases so a warning fired in one test doesn't get
    /// dropped as "already seen" in the next.
    public func resetWarningDedup() {
        state.withLock { $0.seenWarnings.removeAll(keepingCapacity: true) }
    }

    /// Deliver an event synchronously to every attached sink. No-op until
    /// the first ``addSink(_:)`` enables the stream.
    public func emit(_ event: DebugEvent) {
        let currentSinks = state.withLock { $0.enabled ? $0.sinks : [] }
        for sink in currentSinks {
            sink.receive(event)
        }
    }

    /// Emit a framework warning. SwiftUI ships these for known-bad
    /// modifier compositions (e.g. `.searchable` outside
    /// `NavigationSplitView`); ours go through the same DebugStream
    /// pipeline so the F2 panel, remote socket, and file logs all
    /// surface them with stable codes. When no sinks are attached
    /// AND the code isn't suppressed, the warning is also written to
    /// stderr — that's the path that reaches developers who haven't
    /// wired up an inspector, matching SwiftUI's os_log → Console.app.
    public func emitWarning(_ code: FrameworkWarningCode, message: String, nodeID: String = "") {
        // Dedupe: each (code, nodeID, message-hash) fires at most once
        // per session. A misbehaving node otherwise re-emits the same
        // warning every frame and floods stderr / the log file. The
        // dedupe key is broader than `code` alone so warnings about
        // different nodes are still distinct, narrower than the full
        // message so wording-only changes don't break the dedupe.
        let dedupeKey = "\(code.rawValue)\u{1F}\(nodeID)\u{1F}\(message.hashValue)"
        let (suppressed, alreadySeen, currentSinks, live, logURL) = state.withLock { state in
            (state.suppressedWarnings.contains(code),
             !state.seenWarnings.insert(dedupeKey).inserted,
             state.sinks, state.isLiveTUI, state.warningsLogURL)
        }
        guard !suppressed else { return }
        guard !alreadySeen else { return }

        let info = FrameworkWarningInfo(code: code, message: message, nodeID: nodeID)
        let event = DebugEvent.frameworkWarning(info)
        for sink in currentSinks {
            sink.receive(event)
        }
        if currentSinks.isEmpty {
            // No inspector attached. Two paths:
            // * Live TUI: write to the warnings log file so the
            //   rendered viewport stays uncorrupted. Developers grep
            //   the file after exit, or `tail -f` during.
            // * Not live (CLI tool, unit test, swift run swtui): use
            //   TerminalLog's stderr fallback — same as before — so
            //   CI / oncall greps still see the message.
            if live, let logURL {
                appendWarningToLog(code: code, message: message, nodeID: nodeID, url: logURL)
            } else if !live {
                log.warn("\(code.rawValue): \(message)")
            }
            // else: live TUI with no log URL configured → drop. Better
            // a silent drop than corrupting the user's terminal.
        }
    }

    /// Append a single line to the warnings log file. Best-effort —
    /// errors are swallowed because warning emission must never throw
    /// or crash the runtime. File grows unbounded across sessions
    /// (clean via `swtui clean` or manual rm).
    private func appendWarningToLog(code: FrameworkWarningCode,
                                    message: String,
                                    nodeID: String,
                                    url: URL) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let nodeTag = nodeID.isEmpty ? "" : " (node \(nodeID))"
        let line = "[\(String(format: "%.3f", timestamp))] \(code.rawValue): \(message)\(nodeTag)\n"
        guard let data = line.data(using: .utf8) else { return }
        // Ensure file exists, then append.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Explicitly discarded, matching the `try?` posture of the rest
            // of this function: a diagnostics write must never disturb the
            // app it is observing. The `FileHandle` guard below turns a
            // failed creation into a silent no-op. Linux diagnoses the
            // unused result, which the warnings-as-errors gate rejects.
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Convenience emitters

    /// Shorthand for `emit(.frameStart(info))`.
    public func emitFrameStart(info: FrameDebugInfo) {
        emit(.frameStart(info))
    }

    /// Shorthand for `emit(.frameEnd(info))`.
    public func emitFrameEnd(info: FrameDebugInfo) {
        emit(.frameEnd(info))
    }

    /// Serialize the attribute graph under `root` into ``GraphDebugNode``s
    /// and emit it as a ``DebugEvent/graphSnapshot(_:)``. No-op when the
    /// stream is disabled or the graph has no root yet.
    public func emitGraphSnapshot(from root: AttributeNode?, frameNumber: Int) {
        guard state.withLock({ $0.enabled }), let root else { return }
        let snapshot = GraphDebugSnapshot(
            frameNumber: frameNumber,
            nodes: [buildDebugNode(root, depth: 0)]
        )
        emit(.graphSnapshot(snapshot))
    }

    func buildDebugNode(_ node: AttributeNode, depth: Int) -> GraphDebugNode {
        let kind: String
        let value: String

        switch node.kind {
        case .primitive(let content):
            switch content {
            case .text(let spans):
                kind = "text"
                let s = spans.map(\.text).joined()
                value = s.count > 40 ? String(s.prefix(40)) + "..." : s
            case .spacer:
                kind = "spacer"
                value = ""
            case .progressBar(let v, _, _, _):
                kind = "progress"
                value = "\(Int(v * 100))%"
            case .spinner(let frame, _):
                kind = "spinner"
                value = "frame:\(frame)"
            case .divider:
                kind = "divider"
                value = ""
            case .empty:
                kind = "empty"
                value = ""
            case .cellBuffer(let buf):
                kind = "bufferView"
                value = "\(buf.width)x\(buf.height)"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: kind = "vstack"
            case .hstack: kind = "hstack"
            case .zstack: kind = "zstack"
            case .scroll(let axis): kind = axis == .horizontal ? "scroll(h)" : "scroll(v)"
            case .split(let axis): kind = axis == .horizontal ? "split(h)" : "split(v)"
            }
            value = "\(node.children.count) children"
        case .modifier(let effect):
            switch effect {
            case .foreground(let c): kind = "fg"; value = "\(c)"
            case .background(let c): kind = "bg"; value = "\(c)"
            case .bold: kind = "bold"; value = ""
            case .italic: kind = "italic"; value = ""
            case .underline: kind = "underline"; value = ""
            case .padding(let n): kind = "padding"; value = "\(n)"
            case .border(let s, _, _): kind = "border"; value = "\(s)"
            case .frame(let w, let h, _, _, _, _, _): kind = "frame"; value = "\(w ?? 0)x\(h ?? 0)"
            case .flexible(let axes, let grow): kind = "flexible"; value = "axes=\(axes.rawValue) grow=\(grow)"
            case .explicitID(let id): kind = "id"; value = "\(id)"
            case .overlay: kind = "overlay"; value = ""
            case .backgroundView: kind = "bgView"; value = ""
            case .modal(let p): kind = "modal"; value = p ? "shown" : "hidden"
            case .focusable: kind = "focusable"; value = ""
            case .focusScope(let id): kind = "focusScope"; value = id
            case .onKeyPress: kind = "onKeyPress"; value = ""
            case .onAppear: kind = "onAppear"; value = ""
            case .onChange: kind = "onChange"; value = ""
            case .onDisappear: kind = "onDisappear"; value = ""
            case .task: kind = "task"; value = ""
            case .onClick: kind = "onClick"; value = ""
            case .onHover: kind = "onHover"; value = ""
            case .onPaste: kind = "onPaste"; value = ""
            case .environment: kind = "environment"; value = ""
            case .actions(let scope): kind = "actions"; value = "bound=\(scope.boundActions.count)"
            }
        case .viewBody(let info):
            kind = "view"
            value = info.viewTypeName
        }

        return GraphDebugNode(
            id: node.id.path.map { "\($0)" }.joined(separator: "."),
            kind: kind,
            depth: depth,
            rect: [node.rect.x, node.rect.y, node.rect.width, node.rect.height],
            isDirty: node.isDirty,
            childCount: node.children.count,
            value: value,
            children: node.children.map { buildDebugNode($0, depth: depth + 1) }
        )
    }
}

// MARK: - Sink Protocol

/// A consumer of ``DebugEvent``s attached to ``DebugStream`` via
/// ``DebugStream/addSink(_:)``.
///
/// Implement this to capture framework events in a test or harness: the
/// built-in `MemoryDebugSink` (backs the in-app panel), `FileDebugSink`
/// (JSON lines for external tools), and `SocketDebugSink` are the shipped
/// conformances. ``receive(_:)`` is called synchronously on the render
/// thread for every event, so implementations must be fast and must never
/// write to the terminal — printing would corrupt the rendered viewport.
/// Detach test probes with `DebugStream.shared.removeAllSinks()` between
/// cases so one test's sink doesn't observe the next.
public protocol DebugSink: AnyObject, Sendable {
    /// Handle one event. Called on the render thread; do not block.
    func receive(_ event: DebugEvent)
}

// MARK: - Built-in Sinks

/// Keeps last N events in memory — the in-app overlay reads from this.
public final class MemoryDebugSink: DebugSink, Sendable {
    private struct Retained {
        var events: [DebugEvent] = []
        var lastSnapshot: GraphDebugSnapshot?
    }
    private let retained = Mutex(Retained())
    /// Maximum events retained; older events drop off the front.
    public let capacity: Int

    /// Creates an empty ring of at most `capacity` events.
    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    /// Appends the event (evicting the oldest past capacity) and caches
    /// graph snapshots for ``latestSnapshot``.
    public func receive(_ event: DebugEvent) {
        retained.withLock { retained in
            retained.events.append(event)
            if retained.events.count > capacity {
                retained.events.removeFirst(retained.events.count - capacity)
            }
            if case .graphSnapshot(let snap) = event {
                retained.lastSnapshot = snap
            }
        }
    }

    /// The most recent graph snapshot seen, or `nil` before the first
    /// one arrives.
    public var latestSnapshot: GraphDebugSnapshot? {
        retained.withLock { $0.lastSnapshot }
    }

    /// The newest 100 retained events, oldest first.
    public var recentEvents: [DebugEvent] {
        retained.withLock { Array($0.events.suffix(100)) }
    }
}

/// Writes JSON-lines to a file — external tools read this.
public final class FileDebugSink: DebugSink, Sendable {
    private struct Output {
        let handle: FileHandle
        let encoder = JSONEncoder()
    }
    /// One lock around encoding and both writes, so concurrent events land
    /// as whole lines rather than a line and someone else's newline.
    private let output: Mutex<Output>

    /// Opens (truncating/creating) the JSON-lines file at `path`; throws
    /// when the file cannot be opened for writing.
    public init(path: String) throws {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        self.output = Mutex(Output(handle: handle))
    }

    deinit {
        output.withLock { $0.handle.closeFile() }
    }

    public func receive(_ event: DebugEvent) {
        // Only write frame-end and snapshots to file to avoid flooding
        switch event {
        case .frameEnd(let info):
            writeJSON(info)
        case .graphSnapshot(let snap):
            writeJSON(snap)
        case .inputEvent(let info):
            writeJSON(info)
        default:
            break
        }
    }

    private func writeJSON<T: Encodable>(_ value: T) {
        output.withLock { output in
            guard var data = try? output.encoder.encode(value) else { return }
            data.append(0x0A)
            output.handle.write(data)
        }
    }
}

/// Writes to a Unix socket — external tools connect live.
public final class SocketDebugSink: DebugSink, Sendable {
    private struct Connection {
        var listenFd: Int32
        var clientFd: Int32 = -1
        let encoder = JSONEncoder()
    }
    /// Events can arrive from more than one thread, and each may accept,
    /// write to and close the client: all of that happens under this lock.
    private let connection: Mutex<Connection>
    private let path: String

    /// Binds a listening AF_UNIX socket at `path` (default: the
    /// process's diagnostic socket path). Bind failure leaves an inert
    /// sink rather than throwing.
    public init(path: String = DiagPaths.socketPath(useTmp: DiagPaths.loadConfig().useTmp)) {
        self.path = path
        self.connection = Mutex(Connection(listenFd: Self.listeningSocket(at: path)))
    }

    /// A non-blocking listening socket bound at `path`, or -1 when it
    /// cannot be created or bound.
    private static func listeningSocket(at path: String) -> Int32 {
        unlink(path)
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                strncpy(buf, path, 103)
            }
            _ = bound
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if bindResult < 0 {
            close(fd)
            return -1
        }

        listen(fd, 1)

        // Non-blocking accept
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    public func receive(_ event: DebugEvent) {
        switch event {
        case .frameEnd(let info):
            sendJSON(info)
        case .graphSnapshot(let snap):
            sendJSON(snap)
        default:
            break
        }
    }

    private func sendJSON<T: Encodable>(_ value: T) {
        connection.withLock { connection in
            if connection.clientFd < 0 && connection.listenFd >= 0 {
                connection.clientFd = accept(connection.listenFd, nil, nil)
            }
            guard connection.clientFd >= 0,
                  var data = try? connection.encoder.encode(value) else { return }
            data.append(0x0A) // newline
            let clientFd = connection.clientFd
            let result = data.withUnsafeBytes { buf in
                socketWrite(clientFd, buf.baseAddress!, buf.count)
            }
            if result <= 0 {
                close(connection.clientFd)
                connection.clientFd = -1
            }
        }
    }

    deinit {
        connection.withLock { connection in
            if connection.clientFd >= 0 { close(connection.clientFd) }
            if connection.listenFd >= 0 { close(connection.listenFd) }
        }
        unlink(path)
    }
}

#else

// Release stubs — everything compiles away

public enum DebugEvent: Sendable {}
// Cases mirror the DEBUG enum exactly. Warnings never fire in release, but
// `suppressWarning(_:)` call sites must still compile there — a consumer who
// silences a warning during development would otherwise break their release
// build on a name that no longer exists.
public enum FrameworkWarningCode: String, Sendable, Hashable, Codable {
    case onHoverWithHoverFollows
    case bindingProjectedWithoutNode
    case componentOverflow
    case modalDoesNotFit
    case alertMultipleDefaultActions
    case alertHasNoActions
    case optionAsMetaUnconfirmed
    case pickerDuplicateTags
    case boundedValueInvertedBounds
    case navigationNoDestination
}
public final class DebugStream: Sendable {
    public static let shared = DebugStream()
    @inline(__always) public func addSink(_ sink: Any) {}
    @inline(__always) public func removeAllSinks() {}
    @inline(__always) public func emit(_ event: DebugEvent) {}
    @inline(__always) public func emitGraphSnapshot(from root: AttributeNode?, frameNumber: Int) {}
    @inline(__always) public func emitWarning(_ code: FrameworkWarningCode, message: String, nodeID: String = "") {}
    @inline(__always) public func suppressWarning(_ code: FrameworkWarningCode) {}
    @inline(__always) public func unsuppressWarning(_ code: FrameworkWarningCode) {}
    @inline(__always) public func unsuppressAllWarnings() {}
    @inline(__always) public func isWarningSuppressed(_ code: FrameworkWarningCode) -> Bool { false }
}
public protocol DebugSink: AnyObject {}
/// Release stub — retains nothing.
public final class MemoryDebugSink: Sendable {
    /// Creates the inert stub; `capacity` is ignored.
    public init(capacity: Int = 1000) {}
    /// Always `nil` in release builds.
    public var latestSnapshot: Int? { nil }
}

#endif
