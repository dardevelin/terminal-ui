#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import TerminalUIConfig
import TerminalLog

// Module-level logger for framework warnings that fall through when no
// inspector sink is attached. Routes via TerminalLog so capability
// detection (NO_COLOR / piped) and SGR coloring come for free; warn
// level routes to stderr so CI / oncall greps still see the message.
private let log = Log("TerminalUI")

// MARK: - Debug Protocol

/// Structured debug events emitted by the framework.
/// Consumed by in-app overlay, file logger, or external tools via socket.
/// JSON-lines format — one JSON object per line, easy to parse from any language.

#if DEBUG

public enum DebugEvent: Sendable {
    case frameStart(FrameDebugInfo)
    case frameEnd(FrameDebugInfo)
    case nodeUpdate(NodeDebugInfo)
    case inputEvent(InputDebugInfo)
    case stateChange(StateDebugInfo)
    case resize(Int, Int)
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
}

public struct FrameworkWarningInfo: Sendable, Codable {
    public var code: FrameworkWarningCode
    public var message: String
    /// Path-formatted node ID (e.g. `"0.1.2"`) so users can grep for a
    /// specific offending view. May be empty when the warning fires
    /// outside graph construction.
    public var nodeID: String

    public init(code: FrameworkWarningCode, message: String, nodeID: String) {
        self.code = code
        self.message = message
        self.nodeID = nodeID
    }
}

public struct FrameDebugInfo: Codable, Sendable {
    public var frameNumber: Int
    public var timestamp: Double
    public var buildTimeMs: Double
    public var flushTimeMs: Double
    public var bytesWritten: Int
    public var cellsChanged: Int
    public var totalCells: Int
    public var fps: Double
    public var nodeCount: Int
    public var dirtyNodeCount: Int
}

public struct NodeDebugInfo: Codable, Sendable {
    public var id: String
    public var kind: String
    public var rect: [Int]    // [x, y, w, h]
    public var isDirty: Bool
    public var childCount: Int
    public var value: String  // text content, progress %, spinner frame, etc.
}

public struct InputDebugInfo: Codable, Sendable {
    public var timestamp: Double
    public var key: String
    public var modifiers: String
}

public struct StateDebugInfo: Codable, Sendable {
    public var timestamp: Double
    public var property: String
    public var viewType: String
    public var oldValue: String
    public var newValue: String
}

public struct GraphDebugSnapshot: Codable, Sendable {
    public var frameNumber: Int
    public var nodes: [GraphDebugNode]
}

public struct GraphDebugNode: Codable, Sendable {
    public var id: String
    public var kind: String
    public var depth: Int
    public var rect: [Int]
    public var isDirty: Bool
    public var childCount: Int
    public var value: String
    public var children: [GraphDebugNode]
}

// MARK: - Debug Stream

/// Emits debug events to one or more sinks.
/// Sinks can be: in-memory buffer (for overlay), file, socket.
public final class DebugStream: @unchecked Sendable {
    public static let shared = DebugStream()

    private var sinks: [any DebugSink] = []
    private let lock = NSLock()
    private var enabled = false
    private var suppressedWarnings: Set<FrameworkWarningCode> = []
    /// Set when a `TerminalApp` is in raw mode and OWNS the visible
    /// terminal. While true, `emitWarning`'s stderr fallback is
    /// disabled — printing to stderr would corrupt the rendered
    /// viewport. Warnings still reach in-process sinks (debug panel,
    /// remote socket) and the on-disk warnings log.
    private var isLiveTUI = false
    /// Dedupe set for `emitWarning`. A misbehaving node typically
    /// re-fires the same `(code, message)` every frame; flooding the
    /// terminal (or a log file) at 60+ Hz is unusable. Each unique
    /// pair fires AT MOST ONCE per session — same posture as SwiftUI
    /// runtime warnings. Cleared by `resetWarningDedup()` for tests.
    private var seenWarnings: Set<String> = []
    /// Path to the warnings log file (set when DiagPaths reports a
    /// data dir). Lazily appended via `Foundation.FileHandle`.
    private var warningsLogURL: URL?

    private init() {}

    public func addSink(_ sink: any DebugSink) {
        lock.lock()
        sinks.append(sink)
        enabled = true
        lock.unlock()
    }

    /// Detach every sink. Used by tests between cases so probe sinks
    /// from one test don't leak into the next.
    public func removeAllSinks() {
        lock.lock()
        sinks.removeAll(keepingCapacity: true)
        // `enabled` stays true so framework warnings still fire to the
        // stderr fallback when no sinks are attached. The fallback is
        // what makes warnings reach developers who never wired up an
        // inspector — same posture as SwiftUI's os_log reaching Console.
        lock.unlock()
    }

    /// Suppress a framework warning by code. Subsequent emits with
    /// that code are dropped before reaching any sink or stderr.
    /// Mirrors SwiftUI's per-warning silencing pattern. Idempotent.
    public func suppressWarning(_ code: FrameworkWarningCode) {
        lock.lock()
        suppressedWarnings.insert(code)
        lock.unlock()
    }

    /// Re-enable a previously-suppressed warning code.
    public func unsuppressWarning(_ code: FrameworkWarningCode) {
        lock.lock()
        suppressedWarnings.remove(code)
        lock.unlock()
    }

    /// Clear all suppressions. Used by tests between cases.
    public func unsuppressAllWarnings() {
        lock.lock()
        suppressedWarnings.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func isWarningSuppressed(_ code: FrameworkWarningCode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressedWarnings.contains(code)
    }

    /// Mark the runtime as in-or-out of the "owns the terminal" state.
    /// Called by `TerminalApp.run()` around its raw-mode lifetime.
    /// While true, framework warnings DO NOT fall back to stderr —
    /// they'd corrupt the rendered viewport. They route to the
    /// `.terminalui/data/warnings.log` file instead so developers can
    /// grep them after exit (or during, via `tail -f`).
    public func setLiveTUI(_ live: Bool, logFileURL: URL? = nil) {
        lock.lock()
        isLiveTUI = live
        warningsLogURL = logFileURL
        lock.unlock()
    }

    /// Clear the per-session warning dedupe set. Tests call this
    /// between cases so a warning fired in one test doesn't get
    /// dropped as "already seen" in the next.
    public func resetWarningDedup() {
        lock.lock()
        seenWarnings.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func emit(_ event: DebugEvent) {
        guard enabled else { return }
        lock.lock()
        let currentSinks = sinks
        lock.unlock()
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
        lock.lock()
        let suppressed = suppressedWarnings.contains(code)
        let currentSinks = sinks
        let live = isLiveTUI
        let logURL = warningsLogURL
        // Dedupe: each (code, nodeID, message-hash) fires at most once
        // per session. A misbehaving node otherwise re-emits the same
        // warning every frame and floods stderr / the log file. The
        // dedupe key is broader than `code` alone so warnings about
        // different nodes are still distinct, narrower than the full
        // message so wording-only changes don't break the dedupe.
        let dedupeKey = "\(code.rawValue)\u{1F}\(nodeID)\u{1F}\(message.hashValue)"
        let alreadySeen = seenWarnings.contains(dedupeKey)
        if !alreadySeen { seenWarnings.insert(dedupeKey) }
        lock.unlock()
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

    public func emitFrameStart(info: FrameDebugInfo) {
        emit(.frameStart(info))
    }

    public func emitFrameEnd(info: FrameDebugInfo) {
        emit(.frameEnd(info))
    }

    public func emitGraphSnapshot(from root: AttributeNode?, frameNumber: Int) {
        guard enabled, let root else { return }
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
            case .border(let s): kind = "border"; value = "\(s)"
            case .frame(let w, let h, _, _, _, _): kind = "frame"; value = "\(w ?? 0)x\(h ?? 0)"
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

public protocol DebugSink: AnyObject, Sendable {
    func receive(_ event: DebugEvent)
}

// MARK: - Built-in Sinks

/// Keeps last N events in memory — the in-app overlay reads from this.
public final class MemoryDebugSink: DebugSink, @unchecked Sendable {
    private var events: [DebugEvent] = []
    private var lastSnapshot: GraphDebugSnapshot?
    private let lock = NSLock()
    public let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func receive(_ event: DebugEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        if case .graphSnapshot(let snap) = event {
            lastSnapshot = snap
        }
        lock.unlock()
    }

    public var latestSnapshot: GraphDebugSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return lastSnapshot
    }

    public var recentEvents: [DebugEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(events.suffix(100))
    }
}

/// Writes JSON-lines to a file — external tools read this.
public final class FileDebugSink: DebugSink, @unchecked Sendable {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    public init(path: String) throws {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        self.handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
    }

    deinit {
        handle.closeFile()
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
        guard let data = try? encoder.encode(value) else { return }
        handle.write(data)
        handle.write("\n".data(using: .utf8)!)
    }
}

/// Writes to a Unix socket — external tools connect live.
public final class SocketDebugSink: DebugSink, @unchecked Sendable {
    private var fd: Int32 = -1
    private var clientFd: Int32 = -1
    private let encoder = JSONEncoder()
    private let path: String

    public init(path: String = DiagPaths.socketPath(useTmp: DiagPaths.loadConfig().useTmp)) {
        self.path = path
        // Socket setup is deferred to avoid blocking
        setupSocket()
    }

    private func setupSocket() {
        unlink(path)
        #if canImport(Glibc)
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return }

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
            fd = -1
            return
        }

        listen(fd, 1)

        // Non-blocking accept
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    public func receive(_ event: DebugEvent) {
        // Try to accept a client if we don't have one
        if clientFd < 0 && fd >= 0 {
            clientFd = accept(fd, nil, nil)
        }
        guard clientFd >= 0 else { return }

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
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A) // newline
        let result = data.withUnsafeBytes { buf in
            posixWrite(clientFd, buf.baseAddress!, buf.count)
        }
        if result <= 0 {
            close(clientFd)
            clientFd = -1
        }
    }

    deinit {
        if clientFd >= 0 { close(clientFd) }
        if fd >= 0 { close(fd) }
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
public final class MemoryDebugSink: @unchecked Sendable {
    public init(capacity: Int = 1000) {}
    public var latestSnapshot: Int? { nil }
}

#endif
