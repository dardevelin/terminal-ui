#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import TerminalUIConfig

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
        lock.unlock()
        guard !suppressed else { return }
        let info = FrameworkWarningInfo(code: code, message: message, nodeID: nodeID)
        let event = DebugEvent.frameworkWarning(info)
        for sink in currentSinks {
            sink.receive(event)
        }
        if currentSinks.isEmpty {
            // No inspector attached — fall back to stderr so the
            // warning still reaches the developer. Format matches
            // the "[TerminalUI warning] code: message" prefix users
            // can grep for in CI logs.
            let line = "[TerminalUI warning] \(code.rawValue): \(message)\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
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
public enum FrameworkWarningCode: String, Sendable, Hashable, Codable {
    case onHoverWithHoverFollows
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
