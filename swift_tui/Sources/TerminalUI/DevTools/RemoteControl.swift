#if DEBUG

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation

// MARK: - Wire protocol (JSON lines)

/// HYP-71 remote control protocol. A unix-domain socket accepts one JSON
/// request per line and writes one JSON response per line back. The protocol
/// is intentionally plain so smoke tests can be shell scripts and external
/// MCP servers don't need a vendored Swift client.
///
/// Every request carries `id` (echoed by the response) and `cmd`. Responses
/// are `{id, ok, result?, error?}`. Commands that mutate runtime state
/// (`send_key`, `focus_set`) return `{ok: true}` with no result.
public enum RemoteControlProtocol {
    public static let newline: UInt8 = 0x0A
}

/// A request body. Additional cmd-specific fields ride on the same struct
/// via optional properties — keeps the wire flat for easy hand-authoring.
public struct RemoteRequest: Codable, Sendable {
    public var id: Int
    public var cmd: String
    // send_key / send_text payloads
    public var key: String?
    public var modifiers: [String]?
    public var text: String?
    // query_cells + inspector_probe + inspect_range payload
    public var rect: [Int]?  // [x, y, w, h]
    public var x: Int?
    public var y: Int?
    // wait_for_frame payload
    public var frames: Int?
    // grid overlay for query_cells / screenshot (coordinate rulers)
    public var grid: Bool?
    // scan criteria — first non-nil match wins. `match_kind` e.g. "Text",
    // "Button"; `match_text` substring match on a text node; `match_focused`
    // finds the currently-focused node.
    public var matchKind: String?
    public var matchText: String?
    public var matchFocused: Bool?
}

public struct RemoteResponse: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var result: RemoteResult?
    public var error: String?

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
    public var focus: FocusInfo?
    public var cells: CellSlice?
    public var tree: GraphDebugNode?
    public var frame: Int?
    public var screenshotPath: String?
    public var inspector: InspectorProbe?
    /// Multiple probes — one per cell in the requested range. Used by
    /// `inspect_range` so a single round trip covers a whole rect.
    public var probes: [InspectorProbe]?

    public init(focus: FocusInfo? = nil,
                cells: CellSlice? = nil,
                tree: GraphDebugNode? = nil,
                frame: Int? = nil,
                screenshotPath: String? = nil,
                inspector: InspectorProbe? = nil,
                probes: [InspectorProbe]? = nil) {
        self.focus = focus
        self.cells = cells
        self.tree = tree
        self.frame = frame
        self.screenshotPath = screenshotPath
        self.inspector = inspector
        self.probes = probes
    }
}

/// Inspector probe result — what the in-app inspector shows for the node at
/// a given cell. Same data the crosshair renders, so MCP-driven smoke tests
/// see exactly what a user with Ctrl+I open would see.
public struct InspectorProbe: Codable, Sendable {
    public var cursorX: Int
    public var cursorY: Int
    public var active: Bool
    public var nodeKind: String?
    public var nodeRect: [Int]?
    public var declared: [String: String]
    public var modifierChain: [String]

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

public struct FocusInfo: Codable, Sendable {
    public var nodeID: String?
    public var kind: String?
    public var rect: [Int]  // [x, y, w, h], empty if no focus
    public var value: String?  // text content, label, etc.
}

public struct CellSlice: Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
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
    public var rulerLeft: [String]?
}

// MARK: - Server

/// Accepts JSON commands over an AF_UNIX socket and applies them to a
/// running `TerminalRuntime`. Called by the runtime via `pump()` once per
/// frame — non-blocking so the event loop keeps running when no client is
/// connected.
///
/// One client at a time. Reconnects are supported: if the accepted client
/// disconnects the server goes back to waiting for the next `accept()`.
public final class RemoteControlServer: @unchecked Sendable {
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var readBuffer = Data()
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

    public init(path: String, dispatcher: any RemoteControlDispatcher) {
        self.path = path
        self.dispatcher = dispatcher
        setupSocket()
    }

    private func setupSocket() {
        unlink(path)
        #if canImport(Glibc)
        listenFd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard listenFd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            _ = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
                strncpy(buf, path, 103)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult < 0 {
            close(listenFd)
            listenFd = -1
            return
        }
        listen(listenFd, 1)
        _ = fcntl(listenFd, F_SETFL, O_NONBLOCK)
    }

    /// Runtime hook — call once per frame BEFORE draining the event queue.
    /// Accepts a new client if one is waiting, reads any pending bytes,
    /// dispatches newline-separated JSON commands. Never blocks.
    @MainActor
    public func pump() {
        acceptIfReady()
        guard clientFd >= 0 else { return }
        readAvailable()
        processCompleteLines()
    }

    @MainActor
    private func acceptIfReady() {
        guard listenFd >= 0, clientFd < 0 else { return }
        let accepted = accept(listenFd, nil, nil)
        guard accepted >= 0 else { return }
        _ = fcntl(accepted, F_SETFL, O_NONBLOCK)
        clientFd = accepted
        readBuffer.removeAll(keepingCapacity: true)
    }

    @MainActor
    private func readAvailable() {
        // Read up to 4 KiB per pump; the buffer keeps partial lines between
        // pumps so fragmented commands assemble correctly.
        var scratch = [UInt8](repeating: 0, count: 4096)
        let n = scratch.withUnsafeMutableBufferPointer { buf in
            posixRead(clientFd, buf.baseAddress!, buf.count)
        }
        if n > 0 {
            readBuffer.append(scratch, count: n)
        } else if n == 0 {
            // EOF — client closed.
            disconnect()
        }
        // n < 0 with EAGAIN is the normal "no data yet" case — ignore.
    }

    @MainActor
    private func processCompleteLines() {
        while let newlineIdx = readBuffer.firstIndex(of: RemoteControlProtocol.newline) {
            let line = readBuffer[..<newlineIdx]
            readBuffer.removeSubrange(...newlineIdx)
            guard !line.isEmpty else { continue }
            handleLine(Data(line))
        }
    }

    @MainActor
    private func handleLine(_ line: Data) {
        let response: RemoteResponse
        do {
            let request = try decoder.decode(RemoteRequest.self, from: line)
            response = dispatcher.dispatch(request)
        } catch {
            response = RemoteResponse(id: -1, ok: false, error: "decode: \(error)")
        }
        send(response)
    }

    private func send(_ response: RemoteResponse) {
        guard var data = try? encoder.encode(response) else { return }
        data.append(RemoteControlProtocol.newline)
        let result = data.withUnsafeBytes { buf in
            posixWrite(clientFd, buf.baseAddress!, buf.count)
        }
        if result <= 0 {
            disconnect()
        }
    }

    private func disconnect() {
        if clientFd >= 0 {
            close(clientFd)
            clientFd = -1
        }
        readBuffer.removeAll(keepingCapacity: true)
    }

    deinit {
        if clientFd >= 0 { close(clientFd) }
        if listenFd >= 0 { close(listenFd) }
        unlink(path)
    }
}

// MARK: - Dispatcher

/// Abstracts the runtime bits the server mutates so tests can swap in a
/// mock without spinning up a whole `TerminalRuntime`. The real
/// implementation lives inside the runtime (see `RuntimeRemoteDispatcher`).
@MainActor
public protocol RemoteControlDispatcher: AnyObject {
    func dispatch(_ request: RemoteRequest) -> RemoteResponse
}

/// Protocol for runtime surfaces the dispatcher calls. Keeps RemoteControl
/// free of the `TerminalRuntime<RootView>` generic.
@MainActor
public protocol RemoteControlRuntime: AnyObject {
    func enqueueEvent(_ event: TerminalEvent)
    func remoteCurrentGraphRoot() -> AttributeNode?
    func remoteFocusEngine() -> FocusEngine
    func remoteInspector() -> Inspector
    func remotePreviousBuffer() -> CellBuffer?
    func remoteRequestCapture()
    func remoteCurrentFrameNumber() -> Int
}

/// Concrete dispatcher that translates `RemoteRequest` → actions on the
/// runtime. Owned by the server; weakly references the runtime so the
/// runtime's lifetime controls ours.
@MainActor
public final class RuntimeRemoteDispatcher: RemoteControlDispatcher {
    private weak var runtime: (any RemoteControlRuntime)?

    public init(runtime: any RemoteControlRuntime) {
        self.runtime = runtime
    }

    public func dispatch(_ request: RemoteRequest) -> RemoteResponse {
        guard let runtime else {
            return RemoteResponse(id: request.id, ok: false, error: "runtime deallocated")
        }
        switch request.cmd {
        case "send_key":    return sendKey(request, runtime: runtime)
        case "send_text":   return sendText(request, runtime: runtime)
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
        case "screenshot":  return screenshot(request, runtime: runtime)
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
        let modifiers = parseModifiers(request.modifiers ?? [])
        runtime.enqueueEvent(.key(KeyEvent(key: key, modifiers: modifiers)))
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
            runtime.enqueueEvent(.key(KeyEvent(key: key)))
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
        return RemoteResponse(id: request.id, ok: true)
    }

    private func inspectorToggle(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        runtime.remoteInspector().toggle()
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Misc

    private func frameNumber(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        let n = runtime.remoteCurrentFrameNumber()
        return RemoteResponse(id: request.id, ok: true, result: RemoteResult(frame: n))
    }

    private func screenshot(_ request: RemoteRequest, runtime: any RemoteControlRuntime) -> RemoteResponse {
        runtime.remoteRequestCapture()
        // Path isn't known until captureFrame fires — client polls `query_cells`
        // or uses `frame_number` + filesystem sidechannel to locate the file.
        return RemoteResponse(id: request.id, ok: true)
    }

    // MARK: Helpers

    private func parseKey(_ name: String) -> Key? {
        switch name.lowercased() {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "backspace": return .backspace
        case "delete", "del": return .delete
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            // Function keys — "f1".."f12"
            if name.hasPrefix("f"), let n = Int(name.dropFirst()) {
                return .f(n)
            }
            // Single-character form — "a", "A", " ", etc.
            if name.count == 1 { return .character(name.first!) }
            return nil
        }
    }

    private func parseModifiers(_ names: [String]) -> KeyModifiers {
        var mods: KeyModifiers = []
        for name in names {
            switch name.lowercased() {
            case "shift": mods.insert(.shift)
            case "alt", "option", "meta": mods.insert(.alt)
            case "ctrl", "control": mods.insert(.ctrl)
            default: break
            }
        }
        return mods
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
