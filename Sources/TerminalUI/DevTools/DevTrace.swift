import Foundation
import Synchronization
import TerminalUIConfig

// Development-only instrumentation.
// Everything in this file compiles to nothing in release builds.

// MARK: - Trace configuration

/// Capture configuration for ``DevTracer``.
///
/// Apps rarely build one by hand: the runtime derives it from the
/// `.terminalui/terminalui.toml` file (via `DiagConfig`) at startup and
/// passes it to ``DevTracer/configure(_:)``. Build one directly only when a
/// test or harness wants tracing without a config file — set ``enabled``,
/// point ``screenshotDir``/``traceDir`` at a scratch location, and cap the
/// run with ``frameLimit`` so the capture doesn't grow unbounded.
public struct DevTraceConfig: Sendable {
    /// Master switch. When false every `DevTracer` call is a cheap early return.
    public var enabled: Bool
    /// Directory receiving per-frame screenshot files (`frame_NNNN.txt` / `.ansi`).
    public var screenshotDir: String
    /// Directory receiving per-frame trace files (`frame_NNNN.trace`) and `summary.txt`.
    public var traceDir: String
    /// Whether ``DevTracer/endFrame(buffer:previousBuffer:)`` writes a screenshot per frame.
    public var captureScreenshots: Bool
    /// Whether layout/body/state trace points are recorded and written per frame.
    public var captureTrace: Bool
    /// Whether input events (parsed keys, raw bytes, action dispatches) are recorded.
    public var captureEvents: Bool
    /// Stop capturing after this many frames; nil captures for the whole session.
    public var frameLimit: Int?  // stop capturing after N frames

    /// Disabled configuration with output directories resolved from the
    /// `.terminalui/` diagnostic config (per-process dir under `/tmp` by default).
    public static let `default`: DevTraceConfig = {
        #if DEBUG
        let config = DiagPaths.loadConfig()
        return DevTraceConfig(
            enabled: false,
            screenshotDir: DiagPaths.screenshotsDir(useTmp: config.useTmp),
            traceDir: DiagPaths.tracesDir(useTmp: config.useTmp),
            captureScreenshots: true,
            captureTrace: true,
            captureEvents: true,
            frameLimit: nil
        )
        #else
        return DevTraceConfig(
            enabled: false,
            screenshotDir: ".terminalui/screenshots",
            traceDir: ".terminalui/traces",
            captureScreenshots: true,
            captureTrace: true,
            captureEvents: true,
            frameLimit: nil
        )
        #endif
    }()
}

// MARK: - Trace entry types

/// One recorded event inside a frame's trace, written by ``DevTracer`` to
/// the per-frame `.trace` files that `swtui` and the harness read.
public enum TraceEntry: Sendable {
    /// Frame began. `timestamp` is process uptime in seconds.
    case renderStart(frame: Int, timestamp: Double)
    /// Frame finished. `duration` is wall-clock seconds from ``renderStart(frame:timestamp:)``.
    case renderEnd(frame: Int, duration: Double)
    /// A view's `body` was evaluated this frame — the count per frame is
    /// the "how much did this state change rebuild?" signal.
    case bodyEvaluated(viewType: String, frame: Int)
    /// Layout pass proposed a size to a view; `proposed` is `"WxH"` in cells.
    case layoutPropose(viewType: String, proposed: String)
    /// The view answered the proposal; `result` is `"WxH"` in cells.
    case layoutRespond(viewType: String, result: String)
    /// The view was placed; `rect` is `"(x,y WxH)"` in cell coordinates.
    case layoutPlace(viewType: String, rect: String)
    /// Compositor delta for the frame: cells rewritten vs. the grid total.
    case bufferDiff(cellsChanged: Int, totalCells: Int)
    /// A parsed input event, human-readable (e.g. `"ctrl+c"`, `"F5"`).
    case inputEvent(description: String)
    /// Raw bytes consumed by InputParser to produce ONE TerminalEvent.
    /// Recorded BEFORE the parser interprets them, so we can see e.g.
    /// `c2 ae` (UTF-8 ®) → `Alt+r` (after decode) — the diagnostic
    /// path for terminal-key bugs.
    case inputBytes(hex: String, decoded: String)
    /// One ActionDispatch.dispatch attempt. Records the focused node
    /// id, the binding, the active ActionContext stack, and whether
    /// any action matched (by id) — diagnoses why a
    /// chord didn't fire when the user expected it to.
    case actionDispatch(fromNode: String, binding: String, context: String, matchedActionID: String?)
    /// An `@Observable` / `@TerminalState` property mutated, naming the
    /// owning view type — the "why did this frame happen?" record.
    case stateChange(property: String, viewType: String)
    /// The terminal was resized to `cols` x `rows` cells.
    case resize(cols: Int, rows: Int)
}

// MARK: - The tracer

#if DEBUG

/// File-based frame recorder: writes per-frame screenshots and
/// ``TraceEntry`` logs to the `.terminalui/` data directory for offline
/// inspection by `swtui`, the PTY harness, and humans with `cat`.
///
/// The runtime calls the `trace*` hooks from inside the render loop, and the
/// input task calls the input hooks from its own thread as it parses; apps
/// and tests only ever call ``configure(_:)``. The recording is one value
/// behind a lock, so every hook is safe from any thread. Disabled it costs
/// one locked bool check per hook; in release builds the whole class
/// compiles to no-ops.
public final class DevTracer: Sendable {
    /// Process-wide instance the runtime's trace hooks report to.
    public static let shared = DevTracer()

    private struct Recording {
        var config = DevTraceConfig.default
        var frameCount = 0
        var traces: [[TraceEntry]] = []
        /// Entries for the frame being drawn — and, between frames, for the
        /// next one: input parsed while no frame is open is what that frame
        /// will draw.
        var currentFrame: [TraceEntry] = []
        var frameStart: Double = 0

        /// Whether capture is on and the frame limit not yet reached — past
        /// it nothing closes the open frame, so nothing may be added to it.
        var isCapturing: Bool {
            guard config.enabled else { return false }
            if let limit = config.frameLimit, frameCount >= limit { return false }
            return true
        }
    }

    /// The input task and the render loop record concurrently; unguarded,
    /// a burst of wheel events crashed in the array's reallocation.
    private let recording = Mutex(Recording())

    init() {}

    /// Replace the active configuration; creates the output directories
    /// when the new configuration enables capture.
    public func configure(_ config: DevTraceConfig) {
        recording.withLock { $0.config = config }
        if config.enabled {
            setupDirectories(config)
        }
    }

    /// Configure from programmatic DevTraceConfig with DiagConfig for path resolution.
    /// Programmatic values win, DiagConfig provides output directory paths.
    public func configure(_ programmatic: DevTraceConfig, diagConfig: DiagConfig) {
        var merged = programmatic
        merged.screenshotDir = DiagPaths.screenshotsDir(useTmp: diagConfig.useTmp)
        merged.traceDir = DiagPaths.tracesDir(useTmp: diagConfig.useTmp)
        configure(merged)
    }

    /// Whether capture is currently on — mirrors the configured `enabled` flag.
    public var isEnabled: Bool { recording.withLock { $0.config.enabled } }

    /// Every frame recorded so far, the open one last.
    func recordedFrames() -> [[TraceEntry]] {
        recording.withLock { $0.traces + [$0.currentFrame] }
    }

    // MARK: - Frame lifecycle

    /// Runtime hook: open a new frame's trace and stamp its start time.
    public func beginFrame() {
        let now = timestamp()
        recording.withLock { recording in
            guard recording.isCapturing else { return }
            recording.frameStart = now
            recording.currentFrame.insert(.renderStart(frame: recording.frameCount, timestamp: now), at: 0)
        }
    }

    /// Runtime hook: close the frame's trace, then write its screenshot
    /// and `.trace` file to disk per the configured capture flags.
    public func endFrame(buffer: CellBuffer, previousBuffer: CellBuffer?) {
        let now = timestamp()
        let closed: (config: DevTraceConfig, frame: Int, entries: [TraceEntry])? = recording.withLock { recording in
            guard recording.isCapturing else { return nil }
            let frame = recording.frameCount
            recording.currentFrame.append(.renderEnd(frame: frame, duration: now - recording.frameStart))
            let entries = recording.currentFrame
            recording.traces.append(entries)
            recording.frameCount += 1
            recording.currentFrame = []
            return (recording.config, frame, entries)
        }
        // Files are written after the lock is let go: the input task should
        // not wait on the disk to record a keystroke.
        guard let closed else { return }
        if closed.config.captureScreenshots {
            captureScreenshot(buffer: buffer, frame: closed.frame, config: closed.config)
        }
        if closed.config.captureTrace {
            writeFrameTrace(closed.entries, frame: closed.frame, config: closed.config)
        }
    }

    // MARK: - Trace points

    /// Append `entry` to the open frame when `wanted` says the configuration
    /// records it; `entry` is built only then.
    private func record(when wanted: (DevTraceConfig) -> Bool, _ entry: () -> TraceEntry) {
        recording.withLock { recording in
            guard recording.isCapturing, wanted(recording.config) else { return }
            recording.currentFrame.append(entry())
        }
    }

    /// Graph hook: record that `viewType`'s body was evaluated this frame.
    public func traceBodyEvaluated(_ viewType: String) {
        recording.withLock { recording in
            guard recording.isCapturing, recording.config.captureTrace else { return }
            recording.currentFrame.append(.bodyEvaluated(viewType: viewType, frame: recording.frameCount))
        }
    }

    /// Layout hook: record the size (in cells) proposed to `viewType`.
    public func traceLayoutPropose(_ viewType: String, width: Int, height: Int) {
        record(when: \.captureTrace) { .layoutPropose(viewType: viewType, proposed: "\(width)x\(height)") }
    }

    /// Layout hook: record the size (in cells) `viewType` answered with.
    public func traceLayoutRespond(_ viewType: String, width: Int, height: Int) {
        record(when: \.captureTrace) { .layoutRespond(viewType: viewType, result: "\(width)x\(height)") }
    }

    /// Layout hook: record the final rect (cell coordinates) `viewType` was placed in.
    public func traceLayoutPlace(_ viewType: String, rect: Rect) {
        record(when: \.captureTrace) {
            .layoutPlace(viewType: viewType, rect: "(\(rect.x),\(rect.y) \(rect.width)x\(rect.height))")
        }
    }

    /// Compositor hook: record the frame's delta — cells rewritten out of the grid total.
    public func traceBufferDiff(changed: Int, total: Int) {
        record(when: \.captureTrace) { .bufferDiff(cellsChanged: changed, totalCells: total) }
    }

    /// Input hook: record a parsed key event in human-readable form.
    public func traceInput(_ event: KeyEvent) {
        record(when: \.captureEvents) { .inputEvent(description: Self.describeKey(event)) }
    }

    /// Raw input-byte trace. `bytes` is the exact byte sequence the
    /// parser consumed to produce ONE TerminalEvent; `decoded` is the
    /// human-readable form of the resulting event — so terminal-key bugs
    /// can be diagnosed at the byte level, not just the parsed-event level.
    /// Called from the input task.
    public func traceInputBytes(_ bytes: [UInt8], decoded: String) {
        record(when: \.captureEvents) {
            .inputBytes(hex: bytes.map { String(format: "%02x", $0) }.joined(separator: " "), decoded: decoded)
        }
    }

    /// Record one `ActionDispatch.dispatch` attempt. Lets the trace
    /// show whether a chord was matched and against which action ID,
    /// or — when matchedActionID is nil — that the dispatch missed
    /// ("why didn't my binding fire?").
    public func traceActionDispatch(
        fromNode: String,
        binding: String,
        context: String,
        matchedActionID: String?
    ) {
        record(when: \.captureEvents) {
            .actionDispatch(fromNode: fromNode, binding: binding, context: context,
                            matchedActionID: matchedActionID)
        }
    }

    /// Runtime hook: record a terminal resize to `cols` x `rows` cells.
    public func traceResize(cols: Int, rows: Int) {
        record(when: { _ in true }) { .resize(cols: cols, rows: rows) }
    }

    /// State hook: record a property mutation and the view type that owns it.
    public func traceStateChange(property: String, in viewType: String) {
        record(when: \.captureTrace) { .stateChange(property: property, viewType: viewType) }
    }

    // MARK: - Screenshot capture

    private func captureScreenshot(buffer: CellBuffer, frame: Int, config: DevTraceConfig) {
        // Plain text representation — readable by humans and AI
        var output = "frame: \(frame)\n"
        output += "size: \(buffer.width)x\(buffer.height)\n"
        output += "---\n"

        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let cell = buffer[x, y]
                output += String(cell.character)
            }
            output += "\n"
        }

        let path = "\(config.screenshotDir)/frame_\(String(format: "%04d", frame)).txt"
        try? output.write(toFile: path, atomically: true, encoding: .utf8)

        // Also write a styled version with ANSI for terminal viewing
        let ansiPath = "\(config.screenshotDir)/frame_\(String(format: "%04d", frame)).ansi"
        try? buffer.fullRender().write(toFile: ansiPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Trace output

    private func writeFrameTrace(_ entries: [TraceEntry], frame: Int, config: DevTraceConfig) {
        var output = ""

        for entry in entries {
            switch entry {
            case .renderStart(let f, let ts):
                output += "[\(String(format: "%.3f", ts))] frame \(f) render start\n"
            case .renderEnd(let f, let duration):
                output += "[\(String(format: "%.3f", duration * 1000))]ms frame \(f) render end\n"
            case .bodyEvaluated(let viewType, _):
                output += "  body evaluated: \(viewType)\n"
            case .layoutPropose(let viewType, let proposed):
                output += "  layout propose: \(viewType) <- \(proposed)\n"
            case .layoutRespond(let viewType, let result):
                output += "  layout respond: \(viewType) -> \(result)\n"
            case .layoutPlace(let viewType, let rect):
                output += "  layout place:   \(viewType) @ \(rect)\n"
            case .bufferDiff(let changed, let total):
                output += "  buffer diff: \(changed)/\(total) cells changed\n"
            case .inputEvent(let desc):
                output += "  input: \(desc)\n"
            case .inputBytes(let hex, let decoded):
                output += "  input bytes: [\(hex)] -> \(decoded)\n"
            case .actionDispatch(let fromNode, let binding, let context, let matchedActionID):
                let outcome = matchedActionID.map { "matched \($0)" } ?? "MISSED"
                let ctxStr = context.isEmpty ? "default" : context
                output += "  dispatch: \(binding) from \(fromNode) ctx=\(ctxStr) -> \(outcome)\n"
            case .stateChange(let prop, let viewType):
                output += "  state change: \(viewType).\(prop)\n"
            case .resize(let cols, let rows):
                output += "  resize: \(cols)x\(rows)\n"
            }
        }

        let path = "\(config.traceDir)/frame_\(String(format: "%04d", frame)).trace"
        try? output.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Summary

    /// Write `summary.txt` — per-frame durations and body-evaluation counts
    /// for the whole capture. The runtime calls this at shutdown.
    public func writeSummary() {
        let (config, frameCount, traces) = recording.withLock { ($0.config, $0.frameCount, $0.traces) }
        guard config.enabled else { return }
        var output = "TerminalUI dev trace summary\n"
        output += "============================\n"
        output += "total frames: \(frameCount)\n\n"

        for (i, entries) in traces.enumerated() {
            output += "--- frame \(i) ---\n"
            if let start = entries.first, case .renderStart(_, let ts) = start {
                output += "  timestamp: \(String(format: "%.3f", ts))\n"
            }
            if let end = entries.last, case .renderEnd(_, let duration) = end {
                output += "  duration: \(String(format: "%.3f", duration * 1000))ms\n"
            }
            let bodyCount = entries.filter {
                if case .bodyEvaluated = $0 { return true }
                return false
            }.count
            output += "  bodies evaluated: \(bodyCount)\n"
        }

        let path = "\(config.traceDir)/summary.txt"
        try? output.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Utilities

    private func setupDirectories(_ config: DevTraceConfig) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: config.screenshotDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: config.traceDir, withIntermediateDirectories: true)
    }

    private func timestamp() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    static func describeKey(_ event: KeyEvent) -> String {
        var parts: [String] = []
        if event.modifiers.contains(.ctrl) { parts.append("ctrl") }
        if event.modifiers.contains(.alt) { parts.append("alt") }
        if event.modifiers.contains(.shift) { parts.append("shift") }

        switch event.key {
        case .character(let c): parts.append(String(c))
        case .enter: parts.append("enter")
        case .tab: parts.append("tab")
        case .backspace: parts.append("backspace")
        case .escape: parts.append("esc")
        case .up: parts.append("up")
        case .down: parts.append("down")
        case .left: parts.append("left")
        case .right: parts.append("right")
        case .home: parts.append("home")
        case .end: parts.append("end")
        case .pageUp: parts.append("pageUp")
        case .pageDown: parts.append("pageDown")
        case .delete: parts.append("delete")
        case .f(let n): parts.append("F\(n)")
        case .unknown(let bytes): parts.append("unknown(\(bytes))")
        case .activate: parts.append("activate")
        }

        return parts.joined(separator: "+")
    }
}

#else

// Release build — DevTracer is a no-op that the compiler will eliminate entirely

public final class DevTracer: Sendable {
    public static let shared = DevTracer()
    private init() {}

    @inline(__always) public var isEnabled: Bool { false }
    @inline(__always) public func configure(_ config: DevTraceConfig) {}
    @inline(__always) public func configure(_ programmatic: DevTraceConfig, diagConfig: DiagConfig) {}
    @inline(__always) public func beginFrame() {}
    @inline(__always) public func endFrame(buffer: CellBuffer, previousBuffer: CellBuffer?) {}
    @inline(__always) public func traceBodyEvaluated(_ viewType: String) {}
    @inline(__always) public func traceLayoutPropose(_ viewType: String, width: Int, height: Int) {}
    @inline(__always) public func traceLayoutRespond(_ viewType: String, width: Int, height: Int) {}
    @inline(__always) public func traceLayoutPlace(_ viewType: String, rect: Rect) {}
    @inline(__always) public func traceBufferDiff(changed: Int, total: Int) {}
    @inline(__always) public func traceInput(_ event: KeyEvent) {}
    @inline(__always) public func traceResize(cols: Int, rows: Int) {}
    @inline(__always) public func traceStateChange(property: String, in viewType: String) {}
    @inline(__always) public func writeSummary() {}
}

#endif
