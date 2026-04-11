import Foundation

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

    private var sinks: [DebugSink] = []
    private let lock = NSLock()
    private var enabled = false

    private init() {}

    public func addSink(_ sink: DebugSink) {
        lock.lock()
        sinks.append(sink)
        enabled = true
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
            case .text(let s):
                kind = "text"
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
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: kind = "vstack"
            case .hstack: kind = "hstack"
            case .zstack: kind = "zstack"
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
            case .frame(let w, let h): kind = "frame"; value = "\(w ?? 0)x\(h ?? 0)"
            case .explicitID(let id): kind = "id"; value = "\(id)"
            case .overlay: kind = "overlay"; value = ""
            case .backgroundView: kind = "bgView"; value = ""
            case .modal(let p): kind = "modal"; value = p ? "shown" : "hidden"
            }
        case .viewBody(let info):
            kind = "view"
            value = info.viewTypeName
        }

        return GraphDebugNode(
            id: node.id.path.map { "\($0)" }.joined(separator: "."),
            kind: kind,
            depth: depth,
            rect: [node.rect.intX, node.rect.intY, node.rect.intWidth, node.rect.intHeight],
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
        FileManager.default.createFile(atPath: path, contents: nil)
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

    public init(path: String = "/tmp/swift_tui_debug.sock") {
        self.path = path
        // Socket setup is deferred to avoid blocking
        setupSocket()
    }

    private func setupSocket() {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        fcntl(fd, F_SETFL, O_NONBLOCK)
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
            Darwin.write(clientFd, buf.baseAddress!, buf.count)
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
public final class DebugStream: Sendable {
    public static let shared = DebugStream()
    @inline(__always) public func addSink(_ sink: Any) {}
    @inline(__always) public func emit(_ event: DebugEvent) {}
    @inline(__always) public func emitGraphSnapshot(from root: AttributeNode?, frameNumber: Int) {}
}
public protocol DebugSink: AnyObject {}
public final class MemoryDebugSink: @unchecked Sendable {
    public init(capacity: Int = 1000) {}
    public var latestSnapshot: Int? { nil }
}

#endif
