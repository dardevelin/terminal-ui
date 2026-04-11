#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation

// MARK: - Events

public enum TerminalEvent: Sendable {
    case key(KeyEvent)
    case resize(Int, Int)
    case timer(String)
}

// SIGWINCH flag
nonisolated(unsafe) private var _resizeFlag: Bool = false

/// Current frame stats — updated by the runtime each frame.
nonisolated(unsafe) public var frameStats = FrameStats.zero

// MARK: - Event Queue

/// Thread-safe event queue. Producers push, main actor drains.
final class EventQueue: @unchecked Sendable {
    private var buffer: [TerminalEvent] = []
    private let lock = NSLock()

    func push(_ event: TerminalEvent) {
        lock.lock()
        buffer.append(event)
        lock.unlock()
    }

    func drain() -> [TerminalEvent] {
        lock.lock()
        let events = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return events
    }
}

// MARK: - Timer

public struct TerminalTimer: Sendable {
    public let name: String
    public let interval: Duration

    public init(_ name: String, every interval: Duration) {
        self.name = name
        self.interval = interval
    }
}

// MARK: - Render Mode

public enum RenderMode: Sendable {
    /// Render as fast as possible — no sleep between frames.
    case uncapped
    /// Cap at a specific frame interval.
    case capped(Duration)
    /// Only render when an event arrives — no frame clock.
    case onDemand

    /// Common presets
    public static var fps30: RenderMode { .capped(.milliseconds(33)) }
    public static var fps60: RenderMode { .capped(.milliseconds(16)) }
    public static var fps120: RenderMode { .capped(.milliseconds(8)) }
}

// MARK: - Runtime

@MainActor
public final class TerminalRuntime<RootView: TerminalView> {
    private let buildView: @Sendable () -> RootView
    private let onEvent: @Sendable (TerminalEvent) -> Bool
    private let timers: [TerminalTimer]
    private let renderMode: RenderMode
    private let tracer: DevTracer

    private var size: TerminalSize
    private var previousBuffer: CellBuffer?
    private var needsRender: Bool = true
    private let frameCounter = FrameCounter()
    private let eventQueue = EventQueue()
    private var outputBuffer = OutputBuffer()
    nonisolated(unsafe) private let graph = AttributeGraph()
    private let debugPanel = DebugPanel()
    private let debugOverlay = DebugOverlay()
    private let inspector = Inspector()

    public nonisolated init(
        renderMode: RenderMode = .fps60,
        timers: [TerminalTimer] = [],
        devTrace: DevTraceConfig? = nil,
        onEvent: @escaping @Sendable (TerminalEvent) -> Bool = { event in
            if case .key(let k) = event, k.key == .character("q") { return false }
            if case .key(let k) = event, k.key == .escape { return false }
            return true
        },
        @TerminalViewBuilder content: @escaping @Sendable () -> RootView
    ) {
        self.buildView = content
        self.onEvent = onEvent
        self.timers = timers
        self.renderMode = renderMode
        self.tracer = DevTracer.shared
        self.size = Terminal.size()

        if let devTrace {
            tracer.configure(devTrace)
        }
    }

    public func run() async {
        Terminal.installResizeHandler {
            _resizeFlag = true
        }
        Terminal.enableRawMode()
        Terminal.enterAlternateScreen()

        defer {
            tracer.writeSummary()
            Terminal.exitAlternateScreen()
            Terminal.disableRawMode()
        }

        renderFullFrame()

        let queue = self.eventQueue

        // Input reader
        let inputTask = Task.detached {
            while !Task.isCancelled {
                if let key = InputParser.readKey() {
                    queue.push(.key(key))
                }
            }
        }

        // Named timers
        var timerTasks: [Task<Void, Never>] = []
        for timer in timers {
            let task = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: timer.interval)
                    if !Task.isCancelled {
                        queue.push(.timer(timer.name))
                    }
                }
            }
            timerTasks.append(task)
        }

        // Resize poller
        let resizeTask = Task.detached {
            while !Task.isCancelled {
                if _resizeFlag {
                    _resizeFlag = false
                    let newSize = Terminal.size()
                    queue.push(.resize(newSize.cols, newSize.rows))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        // Frame loop
        var running = true

        while running {
            // Drain all queued events
            let events = eventQueue.drain()
            for event in events {
                let shouldContinue = onEvent(event)

                switch event {
                case .key(let keyEvent):
                    tracer.traceInput(keyEvent)
                    #if DEBUG
                    debugPanel.recordInput(
                        describeKeyEvent(keyEvent),
                        timestamp: ProcessInfo.processInfo.systemUptime
                    )
                    // ctrl+d = toggle bottom overlay
                    if keyEvent.key == .character("d") && keyEvent.modifiers.contains(.ctrl) {
                        debugOverlay.toggle()
                    }
                    // ctrl+f = cycle side panel
                    if keyEvent.key == .character("f") && keyEvent.modifiers.contains(.ctrl) {
                        debugPanel.toggle()
                    }
                    // ctrl+i = toggle inspector
                    if keyEvent.key == .character("i") && keyEvent.modifiers.contains(.ctrl) {
                        inspector.toggle()
                    }
                    // Arrow keys move inspector cursor when active
                    if inspector.active {
                        switch keyEvent.key {
                        case .up:    inspector.moveCursor(dx: 0, dy: -1, maxX: size.cols, maxY: size.rows)
                        case .down:  inspector.moveCursor(dx: 0, dy: 1, maxX: size.cols, maxY: size.rows)
                        case .left:  inspector.moveCursor(dx: -1, dy: 0, maxX: size.cols, maxY: size.rows)
                        case .right: inspector.moveCursor(dx: 1, dy: 0, maxX: size.cols, maxY: size.rows)
                        default: break
                        }
                    }
                    #endif
                    needsRender = true

                case .resize(let cols, let rows):
                    size = TerminalSize(cols: cols, rows: rows)
                    tracer.traceResize(cols: cols, rows: rows)
                    Terminal.write("\u{1B}[2J")
                    renderFullFrame()
                    needsRender = false

                case .timer:
                    needsRender = true
                    #if DEBUG
                    debugPanel.markGraphDirty()
                    #endif
                }

                if !shouldContinue {
                    running = false
                    break
                }
            }

            // Render
            if running {
                switch renderMode {
                case .uncapped:
                    // Always render — for benchmarking max throughput
                    renderDiffFrame()
                    needsRender = false
                    await Task.yield()

                case .capped(let interval):
                    if needsRender {
                        renderDiffFrame()
                        needsRender = false
                    }
                    try? await Task.sleep(for: interval)

                case .onDemand:
                    // Wait until something arrives
                    while eventQueue.drain().isEmpty && running {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
            }
        }

        inputTask.cancel()
        for t in timerTasks { t.cancel() }
        resizeTask.cancel()
    }

    // MARK: - Rendering (@MainActor)

    private func renderFullFrame() {
        frameCounter.beginFrame()
        tracer.beginFrame()

        let buildStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        // Build/update the attribute graph from the view tree
        let view = buildView()
        graph.update(from: view)

        // Render from graph — no Any, no as?, enum dispatch only
        var buffer = CellBuffer(width: size.cols, height: size.rows)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: size.cols, height: size.rows))
        if let root = graph.root {
            GraphRenderer.render(root, into: &buffer, context: context)
        }

        // Debug overlays — render directly into buffer, bypass graph
        #if DEBUG
        debugOverlay.render(into: &buffer, stats: frameStats)
        debugPanel.render(into: &buffer, graph: graph, stats: frameStats)
        inspector.render(into: &buffer, graph: graph)
        #endif

        buffer.renderFull(into: &outputBuffer)
        let buildEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        outputBuffer.flush()
        let flushEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        let totalCells = buffer.width * buffer.height
        tracer.endFrame(buffer: buffer, previousBuffer: previousBuffer)
        let stats = frameCounter.endFrame(
            cellsChanged: totalCells, totalCells: totalCells,
            buildNs: buildEnd - buildStart, flushNs: flushEnd - buildEnd,
            bytesWritten: outputBuffer.size
        )
        frameStats = stats
        #if DEBUG
        let buildMs = Double(buildEnd - buildStart) / 1_000_000.0
        debugPanel.recordFrameTime(buildMs)
        #endif
        previousBuffer = buffer
    }

    private func renderDiffFrame() {
        frameCounter.beginFrame()
        tracer.beginFrame()

        let buildStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        // Only rebuild if the graph has dirty nodes or we have no previous buffer.
        // On idle frames, this skips buildView() entirely — zero view construction.
        let needsWork = graph.hasDirtyNodes || previousBuffer == nil || needsRender

        if needsWork {
            let view = buildView()
            let graphChanged = graph.update(from: view)

            // Render if graph changed OR if we were explicitly told to (key press, etc.)
            if graphChanged || previousBuffer == nil || needsRender {
                var buffer = CellBuffer(width: size.cols, height: size.rows)
                let context = RenderContext(rect: Rect(x: 0, y: 0, width: size.cols, height: size.rows))
                if let root = graph.root {
                    GraphRenderer.render(root, into: &buffer, context: context)
                }

                #if DEBUG
                debugOverlay.render(into: &buffer, stats: frameStats)
                debugPanel.render(into: &buffer, graph: graph, stats: frameStats)
                #endif

                let changedCells = buffer.countDiff(from: previousBuffer)
                buffer.renderDiff(from: previousBuffer, into: &outputBuffer)
                let buildEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

                outputBuffer.flush()
                let flushEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

                tracer.endFrame(buffer: buffer, previousBuffer: previousBuffer)
                frameStats = frameCounter.endFrame(
                    cellsChanged: changedCells, totalCells: buffer.width * buffer.height,
                    buildNs: buildEnd - buildStart, flushNs: flushEnd - buildEnd,
                    bytesWritten: outputBuffer.size
                )
                #if DEBUG
                debugPanel.recordFrameTime(Double(buildEnd - buildStart) / 1_000_000.0)
                #endif
                previousBuffer = buffer
                return
            }
        }

        // Nothing changed — skip everything
        let buildEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        tracer.endFrame(buffer: previousBuffer!, previousBuffer: previousBuffer)
        frameStats = frameCounter.endFrame(
            cellsChanged: 0, totalCells: size.cols * size.rows,
            buildNs: buildEnd - buildStart, flushNs: 0,
            bytesWritten: 0
        )
        #if DEBUG
        debugPanel.recordFrameTime(Double(buildEnd - buildStart) / 1_000_000.0)
        #endif
    }

    #if DEBUG
    private func cycleDebugMode() {
        if !debugOverlay.visible && debugPanel.mode == .hidden {
            // hidden → overlay
            debugOverlay.visible = true
        } else if debugOverlay.visible && debugPanel.mode == .hidden {
            // overlay → overlay + graph
            debugPanel.toggle()
        } else if debugPanel.mode == .inputLog {
            // last panel mode → all hidden
            debugOverlay.visible = false
            debugPanel.mode = .hidden
        } else {
            // cycle panel modes
            debugPanel.toggle()
        }
    }

    private func describeKeyEvent(_ event: KeyEvent) -> String {
        var parts: [String] = []
        if event.modifiers.contains(.ctrl) { parts.append("C") }
        if event.modifiers.contains(.alt) { parts.append("A") }
        if event.modifiers.contains(.shift) { parts.append("S") }
        switch event.key {
        case .character(let c): parts.append(String(c))
        case .enter: parts.append("ret")
        case .tab: parts.append("tab")
        case .backspace: parts.append("bsp")
        case .escape: parts.append("esc")
        case .up: parts.append("↑")
        case .down: parts.append("↓")
        case .left: parts.append("←")
        case .right: parts.append("→")
        case .home: parts.append("home")
        case .end: parts.append("end")
        case .pageUp: parts.append("pgup")
        case .pageDown: parts.append("pgdn")
        case .delete: parts.append("del")
        case .f(let n): parts.append("F\(n)")
        case .unknown(let b): parts.append("?\(b)")
        }
        return parts.joined(separator: "-")
    }
    #endif
}

// MARK: - @main entry point protocol

public protocol TerminalAppProtocol {
    associatedtype Content: TerminalView
    static var renderMode: RenderMode { get }
    static var timers: [TerminalTimer] { get }
    static var devTrace: DevTraceConfig? { get }
    static func onEvent(_ event: TerminalEvent) -> Bool
    @TerminalViewBuilder static func content() -> Content
}

extension TerminalAppProtocol {
    public static var renderMode: RenderMode { .fps60 }
    public static var timers: [TerminalTimer] { [] }
    public static var devTrace: DevTraceConfig? { nil }

    public static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event, k.key == .character("q") { return false }
        if case .key(let k) = event, k.key == .escape { return false }
        return true
    }

    public static func main() async {
        let onEventFn: @Sendable (TerminalEvent) -> Bool = { onEvent($0) }
        let contentFn: @Sendable () -> Content = { content() }
        let runtime = TerminalRuntime(
            renderMode: renderMode,
            timers: timers,
            devTrace: devTrace,
            onEvent: onEventFn,
            content: contentFn
        )
        await runtime.run()
    }
}

// MARK: - Inline printing (no event loop)

public enum TerminalApp {
    public static func print<V: TerminalView>(_ view: V, width: Int? = nil) {
        let size = Terminal.size()
        let cols = width ?? size.cols
        let height = max(Int(Renderer.measureHeight(view, proposedWidth: Double(cols)).rounded(.up)), 1)

        var buffer = CellBuffer(width: cols, height: height)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: cols, height: height))
        Renderer.render(view, into: &buffer, context: context)

        for y in 0..<height {
            var line = ""
            var lastStyle = Style.plain
            for x in 0..<cols {
                let cell = buffer[x, y]
                if cell.style != lastStyle {
                    line += buffer.styleToAnsi(cell.style)
                    lastStyle = cell.style
                }
                line += String(cell.character)
            }
            line += "\u{1B}[0m"
            Swift.print(line)
        }
    }
}
