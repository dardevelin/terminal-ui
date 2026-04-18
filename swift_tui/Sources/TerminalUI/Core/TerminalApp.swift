#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import TerminalUIConfig

// MARK: - Events

public enum TerminalEvent: Sendable {
    case key(KeyEvent)
    case mouse(MouseEvent)
    case resize(Int, Int)
    case timer(String)
}

/// Current frame stats — updated by the runtime each frame.
/// MainActor-isolated to prevent torn reads from concurrent access.
@MainActor public var frameStats = FrameStats.zero

// MARK: - Event Queue

/// Thread-safe event queue. Producers push, main actor drains.
final class EventQueue: @unchecked Sendable {
    private var buffer: [TerminalEvent] = []
    private let lock = NSLock()

    func push(_ event: TerminalEvent) {
        lock.withLock { buffer.append(event) }
    }

    func drain() -> [TerminalEvent] {
        lock.withLock {
            let events = buffer
            buffer.removeAll(keepingCapacity: true)
            return events
        }
    }

    var hasEvents: Bool {
        lock.withLock { !buffer.isEmpty }
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
    private let buildView: () -> RootView
    private let onEvent: (TerminalEvent) -> Bool
    private let timers: [TerminalTimer]
    private let renderMode: RenderMode
    private let tracer: DevTracer

    private var size: TerminalSize
    private var previousBuffer: CellBuffer?
    private var needsRender: Bool = true
    private var captureCurrentFrame: Bool = false
    private let frameCounter = FrameCounter()
    private let eventQueue = EventQueue()
    private var outputBuffer = OutputBuffer()
    private let graph = AttributeGraph()
    private let debugPanel = DebugPanel()
    private let debugOverlay = DebugOverlay()
    private let inspector = Inspector()
    private let keyBindings = KeyBindings()
    public let focusEngine = FocusEngine()

    public init(
        renderMode: RenderMode = .fps60,
        timers: [TerminalTimer] = [],
        devTrace: DevTraceConfig? = nil,
        onEvent: @escaping (TerminalEvent) -> Bool = { event in
            if case .key(let k) = event, k.key == .character("q") { return false }
            if case .key(let k) = event, k.key == .escape { return false }
            return true
        },
        @TerminalViewBuilder content: @escaping () -> RootView
    ) {
        self.buildView = content
        self.onEvent = onEvent
        self.timers = timers
        self.renderMode = renderMode
        self.tracer = DevTracer.shared
        self.size = Terminal.size()

        #if DEBUG
        // Load .terminalui/terminalui.toml and merge with programmatic overrides
        let fileConfig = DiagPaths.loadConfig()
        DiagPaths.ensureDirectories(config: fileConfig)

        if let devTrace {
            tracer.configure(devTrace, diagConfig: fileConfig)
        } else {
            tracer.configure(
                DevTraceConfig(
                    enabled: fileConfig.traceEnabled,
                    screenshotDir: DiagPaths.screenshotsDir(useTmp: fileConfig.useTmp),
                    traceDir: DiagPaths.tracesDir(useTmp: fileConfig.useTmp),
                    captureScreenshots: fileConfig.captureScreenshots,
                    captureTrace: fileConfig.traceEnabled,
                    captureEvents: fileConfig.captureEvents,
                    frameLimit: fileConfig.frameLimit
                )
            )
        }
        #else
        if let devTrace {
            tracer.configure(devTrace)
        }
        #endif
    }

    public func run() async {
        Terminal.installResizeHandler()
        Terminal.enableRawMode()
        Terminal.enterAlternateScreen()
        Terminal.enableMouseTracking()

        // Self-pipe for shutdown signaling (HYP-41).
        // A blocked read() on STDIN doesn't respect Task.cancel() on Linux;
        // we wake it by writing a byte to this pipe, which poll() sees.
        var shutdownPipeFDs: [Int32] = [-1, -1]
        let pipeResult = shutdownPipeFDs.withUnsafeMutableBufferPointer { buf in
            pipe(buf.baseAddress)
        }
        if pipeResult == 0 {
            StdinByteSource.shutdownReadFD = shutdownPipeFDs[0]
        }

        defer {
            tracer.writeSummary()
            Terminal.exitAlternateScreen()
            Terminal.disableRawMode()

            // Tear down shutdown pipe. Clear the FD first so any lingering
            // readByte() call falls back to the plain read() path instead of
            // polling a closed fd.
            StdinByteSource.shutdownReadFD = nil
            if shutdownPipeFDs[0] >= 0 { close(shutdownPipeFDs[0]) }
            if shutdownPipeFDs[1] >= 0 { close(shutdownPipeFDs[1]) }
        }

        // Make focus engine accessible during graph construction
        GraphContext.currentFocusEngine = focusEngine

        renderFullFrame()

        let queue = self.eventQueue

        // Concurrent producers push events into the shared queue.
        // Task.detached runs off MainActor — these are the only threads that
        // touch the EventQueue (which is NSLock-protected).
        // The main loop below drains the queue on MainActor.

        let inputTask = Task.detached {
            while !Task.isCancelled {
                if let event = InputParser.readEvent() {
                    queue.push(event)
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

        // Resize poller — uses atomic flag set by SIGWINCH handler
        let resizeTask = Task.detached {
            while !Task.isCancelled {
                if Terminal.checkResize() {
                    let newSize = Terminal.size()
                    queue.push(.resize(newSize.cols, newSize.rows))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        // Frame loop — runs on MainActor.
        // Each iteration: drain events → handle → render → pace.
        // Event priority: view handlers first, then focus navigation, then debug tools.
        var running = true

        while running {
            let events = eventQueue.drain()
            for event in events {
                // Universal Ctrl+C — equivalent to the SIGINT we disabled via
                // `ISIG` in raw mode. Users expect Ctrl+C to kill any TUI;
                // apps can still intercept it before this check by returning
                // true from onEvent for `.character("c")` with `.ctrl` — but
                // the default has to be "it quits".
                if case .key(let k) = event,
                   k.key == .character("c"),
                   k.modifiers.contains(.ctrl) {
                    running = false
                    break
                }
                let shouldContinue = onEvent(event)

                switch event {
                case .key(let keyEvent):
                    tracer.traceInput(keyEvent)
                    handleKeyEvent(keyEvent)
                    needsRender = true

                case .mouse(let mouseEvent):
                    #if DEBUG
                    // Debug panel click handling (collapse/expand nodes)
                    if mouseEvent.kind == .press(.left) {
                        if debugPanel.handleClick(x: mouseEvent.x, y: mouseEvent.y, graph: graph, bufferWidth: size.cols, bufferHeight: size.rows) {
                            needsRender = true
                            break
                        }
                    }
                    // Debug panel scroll handling
                    if debugPanel.mode == .graphTree {
                        if case .scrollUp = mouseEvent.kind {
                            debugPanel.scrollGraphUp(amount: 3)
                            needsRender = true
                            break
                        }
                        if case .scrollDown = mouseEvent.kind {
                            debugPanel.scrollGraphDown(amount: 3)
                            needsRender = true
                            break
                        }
                    }
                    #endif
                    switch mouseEvent.kind {
                    case .press(.left):
                        focusEngine.handleMouseClick(x: mouseEvent.x, y: mouseEvent.y, root: graph.root)
                    case .moved, .drag:
                        focusEngine.updateMouseHover(x: mouseEvent.x, y: mouseEvent.y, root: graph.root)
                    case .scrollUp:
                        // Route scroll to focused view as synthetic up arrow (3 lines)
                        for _ in 0..<3 {
                            _ = focusEngine.routeKeyEvent(KeyEvent(key: .up), root: graph.root)
                        }
                    case .scrollDown:
                        // Route scroll to focused view as synthetic down arrow (3 lines)
                        for _ in 0..<3 {
                            _ = focusEngine.routeKeyEvent(KeyEvent(key: .down), root: graph.root)
                        }
                    default:
                        break
                    }
                    needsRender = true

                case .resize(let cols, let rows):
                    size = TerminalSize(cols: cols, rows: rows)
                    tracer.traceResize(cols: cols, rows: rows)
                    previousBuffer = nil  // nil previous forces full render (no diff base to compare against)
                    needsRender = true

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
                    let frameStart = ContinuousClock.now
                    if needsRender {
                        renderDiffFrame()
                        needsRender = false
                    }
                    // Sleep only the remaining budget (interval minus work done)
                    let elapsed = ContinuousClock.now - frameStart
                    let remaining = interval - elapsed
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                    }

                case .onDemand:
                    // Render if dirty, then wait for next event
                    if needsRender {
                        renderDiffFrame()
                        needsRender = false
                    }
                    // Block until an event arrives — zero CPU when idle
                    while running && !eventQueue.hasEvents {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
            }
        }

        inputTask.cancel()
        // Wake the input task out of any blocked read() — HYP-41.
        if shutdownPipeFDs[1] >= 0 {
            var wake: UInt8 = 1
            _ = write(shutdownPipeFDs[1], &wake, 1)
        }
        for t in timerTasks { t.cancel() }
        resizeTask.cancel()
    }

    // MARK: - Key Event Handling

    private func handleKeyEvent(_ keyEvent: KeyEvent) {
        #if DEBUG
        debugPanel.recordInput(
            describeKeyEvent(keyEvent),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        // Handle debug key bindings
        if let action = keyBindings.action(for: keyEvent) {
            switch action {
            case .toggleDebugOverlay: debugOverlay.toggle()
            case .toggleDebugPanel: debugPanel.toggle()
            case .toggleInspector: inspector.toggle()
            case .captureFrame: captureCurrentFrame = true
            default: break
            }
        }
        // Inspector takes over arrow keys when active
        if inspector.active {
            switch keyEvent.key {
            case .up:    inspector.moveCursor(dx: 0, dy: -1, maxX: size.cols, maxY: size.rows); return
            case .down:  inspector.moveCursor(dx: 0, dy: 1, maxX: size.cols, maxY: size.rows); return
            case .left:  inspector.moveCursor(dx: -1, dy: 0, maxX: size.cols, maxY: size.rows); return
            case .right: inspector.moveCursor(dx: 1, dy: 0, maxX: size.cols, maxY: size.rows); return
            default: break
            }
        }
        #endif

        // Route key events to the focused view's handler FIRST.
        // If the handler consumes it (e.g., List handles arrow keys), stop.
        // Only if unhandled do we use arrow keys for focus navigation.
        let handledByView = focusEngine.routeKeyEvent(keyEvent, root: graph.root)

        if !handledByView {
            // Focus navigation — Tab/Shift+Tab always navigate. Arrows only
            // move focus when the current subtree opts in via the
            // `allowArrowFocusNavigation` environment value. Default is OFF:
            // arrows pressed while a view is focused stay inside that view
            // (or bubble to a parent handler) rather than yanking focus to
            // a sibling. Matches the user's 2026-04-18 direction: "tab is
            // the focus changer, unless marked as allow".
            if keyEvent.key == .tab && keyEvent.modifiers.contains(.shift) {
                focusEngine.focusPrevious()
            } else if keyEvent.key == .tab {
                focusEngine.focusNext()
            } else if GraphContext.currentEnvironment?.allowArrowFocusNavigation == true {
                if keyEvent.key == .up {
                    focusEngine.focusInDirection(.up, root: graph.root)
                } else if keyEvent.key == .down {
                    focusEngine.focusInDirection(.down, root: graph.root)
                } else if keyEvent.key == .left {
                    focusEngine.focusInDirection(.left, root: graph.root)
                } else if keyEvent.key == .right {
                    focusEngine.focusInDirection(.right, root: graph.root)
                }
            }

            #if DEBUG
            // Debug panel scroll — only if no view consumed the event
            if debugPanel.mode == .graphTree {
                let visibleLines = size.rows - 5
                switch keyEvent.key {
                case .pageUp: debugPanel.scrollGraphPageUp(visibleLines: visibleLines)
                case .pageDown: debugPanel.scrollGraphPageDown(visibleLines: visibleLines)
                default: break
                }
            }
            #endif
        }
    }

    // MARK: - Rendering (@MainActor)

    private func renderFullFrame() {
        frameCounter.beginFrame()
        tracer.beginFrame()

        let buildStart = monotonicNanoseconds()

        // Set environment for body evaluation
        var env = GraphContext.currentEnvironment ?? EnvironmentValues()
        env.terminalSize = size
        GraphContext.currentEnvironment = env
        GraphContext.currentProposedSize = Size(width: size.cols, height: size.rows)

        // Build/update the attribute graph from the view tree
        let view = buildView()
        graph.update(from: view)

        // Adjust scroll offsets to keep focused child visible — must run before render
        GraphRenderer.adjustScrollForFocus(
            root: graph.root, focusedID: focusEngine.keyboardFocusID,
            viewportWidth: size.cols, viewportHeight: size.rows
        )

        // Render from graph — no Any, no as?, enum dispatch only
        var buffer = CellBuffer(width: size.cols, height: size.rows)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: size.cols, height: size.rows))
        if let root = graph.root {
            GraphRenderer.render(root, into: &buffer, context: context)
        }

        // Focus indicators
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: focusEngine, root: graph.root)

        // Debug overlays — render directly into buffer, bypass graph
        #if DEBUG
        debugOverlay.render(into: &buffer, stats: frameStats)
        debugPanel.render(into: &buffer, graph: graph, stats: frameStats)
        inspector.render(into: &buffer, graph: graph)
        #endif

        buffer.renderFull(into: &outputBuffer)
        let buildEnd = monotonicNanoseconds()

        outputBuffer.flush()
        let flushEnd = monotonicNanoseconds()

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

        let buildStart = monotonicNanoseconds()

        let needsWork = graph.hasDirtyNodes || previousBuffer == nil || needsRender

        if needsWork {
            focusEngine.clearHandlers()

            // Set environment for body evaluation
            var env = GraphContext.currentEnvironment ?? EnvironmentValues()
            env.terminalSize = size
            GraphContext.currentEnvironment = env
            GraphContext.currentProposedSize = Size(width: size.cols, height: size.rows)

            let view = buildView()
            let graphChanged = graph.update(from: view)

            // Rebuild focus index after graph changes
            if let root = graph.root {
                focusEngine.rebuildIndex(root: root)
                // Auto-focus the first focusable on startup (HYP-82 #4). With
                // arrows no longer moving focus by default, an app whose
                // arrow handler lives on a `.focusable()` view would receive
                // nothing until the user pressed Tab. Mirrors SwiftUI's
                // implicit first-responder — the app boots with a focused
                // element so per-view handlers fire on the very first key.
                if focusEngine.keyboardFocusID == nil {
                    focusEngine.focusNext()
                }
            }

            // Render if graph changed OR if we were explicitly told to (key press, etc.)
            if graphChanged || previousBuffer == nil || needsRender {
                // Adjust scroll offsets to keep focused child visible
                GraphRenderer.adjustScrollForFocus(
                    root: graph.root, focusedID: focusEngine.keyboardFocusID,
                    viewportWidth: size.cols, viewportHeight: size.rows
                )

                var buffer = CellBuffer(width: size.cols, height: size.rows)
                let context = RenderContext(rect: Rect(x: 0, y: 0, width: size.cols, height: size.rows))
                if let root = graph.root {
                    GraphRenderer.render(root, into: &buffer, context: context)
                }

                // Focus indicators
                GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: focusEngine, root: graph.root)

                #if DEBUG
                debugOverlay.render(into: &buffer, stats: frameStats)
                debugPanel.render(into: &buffer, graph: graph, stats: frameStats)
                inspector.render(into: &buffer, graph: graph)

                if captureCurrentFrame {
                    captureCurrentFrame = false
                    captureFrame(buffer: buffer)
                }
                #endif

                let changedCells = buffer.countDiff(from: previousBuffer)
                buffer.renderDiff(from: previousBuffer, into: &outputBuffer)
                let buildEnd = monotonicNanoseconds()

                outputBuffer.flush()
                let flushEnd = monotonicNanoseconds()

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
        let buildEnd = monotonicNanoseconds()
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

    private func captureFrame(buffer: CellBuffer) {
        let fileConfig = DiagPaths.loadConfig()
        let captureDir = DiagPaths.capturesDir(useTmp: fileConfig.useTmp)
        try? FileManager.default.createDirectory(atPath: captureDir, withIntermediateDirectories: true)
        let ts = Int(ProcessInfo.processInfo.systemUptime * 1000)

        var text = "capture: \(ts)\nsize: \(buffer.width)x\(buffer.height)\n---\n"
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                text += String(buffer[x, y].character)
            }
            text += "\n"
        }
        try? text.write(toFile: "\(captureDir)/\(ts).txt", atomically: true, encoding: .utf8)
        try? buffer.fullRender().write(toFile: "\(captureDir)/\(ts).ansi", atomically: true, encoding: .utf8)

        if let root = graph.root {
            var graphDump = "graph capture: \(ts)\n"
            dumpNode(root, depth: 0, into: &graphDump)
            try? graphDump.write(toFile: "\(captureDir)/\(ts).graph", atomically: true, encoding: .utf8)
        }
    }

    private func dumpNode(_ node: AttributeNode, depth: Int, into output: inout String) {
        let indent = String(repeating: "  ", count: depth)
        let r = node.rect
        let kind: String
        switch node.kind {
        case .primitive(let c):
            switch c {
            case .text(let spans): kind = "Text(\(spans.map(\.text).joined().prefix(20)))"
            case .spacer: kind = "Spacer"
            case .divider: kind = "Divider"
            case .progressBar(let v, _, _, _): kind = "ProgressBar(\(Int(v*100))%)"
            case .spinner(let f, _): kind = "Spinner(f:\(f))"
            case .empty: kind = "Empty"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: kind = "VStack[\(node.children.count)]"
            case .hstack: kind = "HStack[\(node.children.count)]"
            case .zstack: kind = "ZStack[\(node.children.count)]"
            case .scroll(let axis):
                kind = "ScrollView(\(axis == .horizontal ? "H" : "V"))[\(node.children.count)]"
            }
        case .modifier(let effect):
            kind = ".\(effect)"
        case .viewBody(let info):
            kind = info.viewTypeName
        }
        output += "\(indent)\(kind) @ (\(r.x),\(r.y) \(r.width)x\(r.height))\n"
        for child in node.children {
            dumpNode(child, depth: depth + 1, into: &output)
        }
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
    public static var devTrace: DevTraceConfig? {
        #if DEBUG
        var config = DevTraceConfig.default
        config.enabled = true
        config.frameLimit = 100
        return config
        #else
        return nil
        #endif
    }

    public static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event, k.key == .character("q") { return false }
        if case .key(let k) = event, k.key == .escape { return false }
        return true
    }

    @MainActor public static func main() async {
        let runtime = TerminalRuntime(
            renderMode: renderMode,
            timers: timers,
            devTrace: devTrace,
            onEvent: { onEvent($0) },
            content: { content() }
        )
        await runtime.run()
    }
}

// MARK: - Inline printing (no event loop)

public enum TerminalApp {
    public static func print<V: TerminalView>(_ view: V, width: Int? = nil) {
        let size = Terminal.size()
        let cols = width ?? size.cols

        let graph = AttributeGraph()
        graph.update(from: view)

        guard let root = graph.root else { return }

        let measuredHeight = GraphMeasurer.measureHeight(root, proposedWidth: cols)
        let height = max(measuredHeight, 1)

        var buffer = CellBuffer(width: cols, height: height)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: cols, height: height))
        GraphRenderer.render(root, into: &buffer, context: context)

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
