#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Foundation
import TerminalUIConfig
import TerminalLog
import Synchronization

// MARK: - Events

/// Everything the runtime can deliver to `onEvent(_:)` — one enum, one
/// handler.
///
/// Events are produced off the main actor (the input task, which also turns
/// SIGWINCH into a resize, and timer tasks), queued, and drained on the
/// MainActor once per frame. Returning
/// `false` from `onEvent(_:)` for any event quits the app; view-level
/// handlers still run for events the app-level handler lets through.
public enum TerminalEvent: Sendable {
    /// A key press, already decoded from raw bytes. See ``KeyEvent``.
    case key(KeyEvent)
    /// A mouse press/release/drag/move/scroll at a cell position. See
    /// ``MouseEvent``.
    case mouse(MouseEvent)
    /// The terminal was resized to (columns, rows). The runtime has already
    /// scheduled a full redraw at the new geometry before the app sees this.
    case resize(Int, Int)
    /// A named ``TerminalTimer`` fired; the payload is the timer's name, so
    /// one handler can distinguish multiple timers.
    case timer(String)
    /// Bracketed-paste payload — the bytes between an `ESC[200~ ... ESC[201~`
    /// pair, decoded as UTF-8. Control sequences inside the wrapper are
    /// NOT interpreted as keys; the payload is the unmodified user content.
    /// xterm DEC private mode 2004 must be enabled for the terminal to
    /// produce the wrappers — `Terminal.enableBracketedPaste()` does that.
    case paste(String)
}

/// Current frame stats — updated by the runtime each frame.
/// MainActor-isolated to prevent torn reads from concurrent access.
@MainActor public var frameStats = FrameStats.zero

// MARK: - Termination

/// Why a running app ended. ``TerminalRuntime/run()`` returns it once the
/// runtime has torn down, and ``TerminalAppProtocol/willTerminate(_:)`` is
/// handed it before the process ends.
public enum TerminationReason: Sendable, Equatable {
    /// The app quit: `onEvent` returned `false`, or an action asked.
    case quit
    /// A terminating signal — SIGINT or SIGTERM — asked the app to quit.
    case signal(Int32)
    /// The terminal went away: its window closed, its connection dropped.
    /// Covers a SIGHUP, which POSIX defines as exactly this, and a hang-up
    /// an app that is not the terminal's controlling process reads from its
    /// input instead.
    case terminalHungUp

    init(terminationSignal: Int32?) {
        switch terminationSignal {
        case nil: self = .quit
        case SIGHUP: self = .terminalHungUp
        case let signum?: self = .signal(signum)
        }
    }

    /// Ends the process as `ending` says for this reason. A hand-written
    /// `main()` calls it with what ``TerminalRuntime/run()`` returned.
    public func end(_ ending: TerminationEnding = .conventional) -> Never {
        switch ProcessEnding(self, ending) {
        case .exit(let status):
            exit(status)
        case .signal(let signum):
            Terminal.end(bySignal: signum)
        }
    }
}

/// How the process ends, chosen by ``TerminalAppProtocol/willTerminate(_:)``.
public enum TerminationEnding: Sendable, Equatable {
    /// As the parent would have seen without the runtime: a quit exits 0, a
    /// signal is re-raised, a hung-up terminal ends the process by SIGHUP.
    case conventional
    /// Exit with `code`, whatever the reason — for a parent that reads exit
    /// statuses rather than signals.
    case exit(code: Int32)
}

/// What ``TerminationReason/end(_:)`` does, decided apart from doing it.
enum ProcessEnding: Equatable {
    case exit(Int32)
    case signal(Int32)

    init(_ reason: TerminationReason, _ ending: TerminationEnding) {
        switch (ending, reason) {
        case (.exit(let code), _): self = .exit(code)
        case (.conventional, .quit): self = .exit(0)
        case (.conventional, .signal(let signum)): self = .signal(signum)
        case (.conventional, .terminalHungUp): self = .signal(SIGHUP)
        }
    }
}

// MARK: - Event Queue

/// Thread-safe event queue. Producers push, main actor drains.
final class EventQueue: Sendable {
    private struct Contents {
        var events: [TerminalEvent] = []
        #if DEBUG
        var terminalInput = TerminalInputTaken()
        #endif
    }

    private let contents = Mutex(Contents())
    /// Raised on every push, so a frame loop with nothing to do sleeps until
    /// an event arrives.
    private let wake: WakeSignal

    init(wake: WakeSignal) {
        self.wake = wake
    }

    func push(_ event: TerminalEvent) {
        contents.withLock { $0.events.append(event) }
        wake.wake()
    }

    /// Queues what the terminal's input made of its bytes up to
    /// `bytesConsumed` — nothing, for a sequence the parser dropped — or of
    /// a resize. A debug build records both under the same lock as the
    /// event, so whoever reads a record that includes a byte or a size finds
    /// its event already queued.
    func pushTerminalInput(_ event: TerminalEvent?, bytesConsumed: Int) {
        #if DEBUG
        contents.withLock { contents in
            if let event {
                contents.events.append(event)
                if case .resize(let cols, let rows) = event {
                    contents.terminalInput.cols = cols
                    contents.terminalInput.rows = rows
                }
            }
            contents.terminalInput.bytes = bytesConsumed
        }
        if event != nil {
            wake.wake()
        }
        #else
        if let event {
            push(event)
        }
        #endif
    }

    func drain() -> [TerminalEvent] {
        contents.withLock { contents in
            let events = contents.events
            contents.events.removeAll(keepingCapacity: true)
            return events
        }
    }

    var hasEvents: Bool {
        contents.withLock { !$0.events.isEmpty }
    }

    #if DEBUG
    /// What the queue has taken from the terminal: its events are queued or
    /// drained.
    var terminalInputTaken: TerminalInputTaken {
        contents.withLock { $0.terminalInput }
    }
    #endif
}

/// A wheel notch scrolls three lines, as terminals and most platforms do.
private let linesPerWheelNotch = 3

/// Pointer events held back while a batch is drained. A trackpad sends
/// hundreds a second, and finding what is under the cursor is the cost, so
/// a run of them is routed once: wheel notches at one cell together, and of
/// a run of moves only the last — as AppKit coalesces mouse-moved events.
/// Any other event ends the run first, so order is kept.
private enum PendingPointer {
    case wheel(key: Key, x: Int, y: Int, notches: Int)
    case motion(MouseEvent)
}

extension PendingPointer {
    /// Whether `event` belongs to the run held back, rather than ending it.
    fileprivate func continues(with event: TerminalEvent) -> Bool {
        guard case .mouse(let mouse) = event else { return false }
        switch self {
        case .wheel: return mouse.kind.isWheel
        case .motion: return mouse.kind.isMotion
        }
    }
}

// MARK: - Timer

/// A named repeating tick delivered to the app as `TerminalEvent.timer(name)`.
///
/// Declare timers via `TerminalAppProtocol.timers`; the runtime runs each on
/// its own task and pushes a tick into the event queue every `interval`.
/// Ticks mark the frame dirty, so a timer is the simplest way to animate
/// without touching observable state.
public struct TerminalTimer: Sendable {
    /// Identifies this timer in the `.timer(String)` events it produces.
    public let name: String
    /// Time between ticks. Delivery aligns to the frame loop, so effective
    /// resolution is bounded by the render mode's frame budget.
    public let interval: Duration

    /// Creates a timer that fires `.timer(name)` every `interval`.
    public init(_ name: String, every interval: Duration) {
        self.name = name
        self.interval = interval
    }
}

// MARK: - Render Mode

/// How the frame loop paces rendering — the CPU/latency trade-off knob.
///
/// Set via `TerminalAppProtocol.renderMode` (default `.fps60`). In every
/// mode but `.uncapped`, an app with nothing to do sleeps: the frame loop
/// waits until input, a resize, an `@Observable` change or a timer wakes it,
/// so an idle app is invisible in `top`. `.capped` then draws at most one
/// frame per interval, holding back a burst of changes; `.onDemand` draws as
/// soon as there is work. `.uncapped` exists for benchmarking, not
/// production.
public enum RenderMode: Sendable {
    /// Render as fast as possible — no sleep between frames.
    case uncapped
    /// Cap at a specific frame interval.
    case capped(Duration)
    /// Only render when an event arrives — no frame clock.
    case onDemand

    // Common presets
    /// Preset for ~30 fps: `.capped(.milliseconds(33))`.
    public static var fps30: RenderMode { .capped(.milliseconds(33)) }
    /// Preset for ~60 fps: `.capped(.milliseconds(16))`. The default render
    /// mode.
    public static var fps60: RenderMode { .capped(.milliseconds(16)) }
    /// Preset for ~120 fps: `.capped(.milliseconds(8))`.
    public static var fps120: RenderMode { .capped(.milliseconds(8)) }
}

// MARK: - Runtime

/// The event loop behind every TerminalUI app: raw-mode setup, input
/// parsing, graph reconciliation, delta rendering, and teardown.
///
/// Most apps never construct one — conforming to ``TerminalAppProtocol``
/// gets a runtime built and run by the default `main()`. Instantiate
/// directly only when you need a custom `@main` (for example, to catch
/// ``TerminalRuntimeError/rawModeUnavailable`` and fall back to
/// non-interactive output when stdin isn't a TTY):
///
/// ```swift
/// let runtime = TerminalRuntime(renderMode: .onDemand) { ContentView() }
/// let reason = try await runtime.run()
/// reason.end()   // die of the signal that ended it, as the parent expects
/// ```
///
/// MainActor-isolated end to end: events are produced on background tasks
/// but drained and dispatched on the MainActor, which is what lets handlers
/// touch `@Observable` app state without hops.
@MainActor
public final class TerminalRuntime<RootView: TerminalView> {
    private let buildView: () -> RootView
    private let onEvent: (TerminalEvent) -> Bool
    private let timers: [TerminalTimer]
    private let renderMode: RenderMode
    private let tracer: DevTracer

    private var size: TerminalSize
    private var previousBuffer: CellBuffer?
    /// Reused render target — one allocation at startup instead of one per
    /// frame. Cleared at the top of each render pass and resized
    /// when the terminal geometry changes.
    private var renderBuffer = CellBuffer(width: 0, height: 0)
    private var needsRender: Bool = true
    private var captureCurrentFrame: Bool = false
    private let frameCounter = FrameCounter()
    /// Raised by every source of work, so the frame loop sleeps while there
    /// is none.
    private let wake = WakeSignal()
    private let eventQueue: EventQueue
    /// Rung through ``bellAction``, sounded with the next frame.
    private let bell: TerminalBell
    /// The environment's `\.bell` in every frame this runtime draws. Built
    /// once, so the environment holds the same value frame to frame.
    private let bellAction: BellAction
    /// The environment's `\.killBuffer` in every frame: one for the app, so
    /// a kill in one input can be yanked into another.
    private let killBuffer = KillBuffer()
    /// The environment's `\.cursorFlash` in every frame.
    private let cursorFlash = CursorFlash()
    /// The user's own bindings, laid over every frame's keymap.
    private var userKeymap: UserKeymap
    private var outputBuffer = OutputBuffer()
    private let graph: AttributeGraph
    private let debugPanel = DebugPanel()
    private let debugOverlay = DebugOverlay()
    private let inspector = Inspector()
    private let keyBindings = KeyBindings()
    /// The runtime's focus engine — one per runtime, alive for the whole run.
    /// Public so tooling and tests can inspect or drive focus (focused node,
    /// Tab order, directional moves); apps normally interact with it through
    /// `.focusable` and the `@FocusState`-style modifiers instead.
    public let focusEngine = FocusEngine()

    /// Set to `true` by the framework's default `app.quit` action when
    /// it fires. The event loop polls this each iteration and exits
    /// the runtime cleanly. Surfaces as an instance var rather than a
    /// closure capture so action handlers (which are `@Sendable`) can
    /// signal without holding a reference to the loop's local `running`
    /// flag.
    private var quitRequested: Bool = false

    /// Build the framework's default action scope for this runtime.
    /// Quit actions write `pendingQuitSignal` so the event loop sees
    /// the signal on its next iteration. Built fresh per dispatch so
    /// the closures don't outlive the runtime instance.
    ///
    /// Implementation detail: the scope construction lives in a free
    /// helper (`makeFrameworkDefaultsScope`) rather than this generic
    /// method so the @Sendable closure inside doesn't capture the
    /// `RootView.Type` metatype from the runtime's generic context —
    /// which would be a Swift 6 sendability violation under the
    /// strict `TUI_WARNINGS_AS_ERRORS=1` gate.
    private func makeFrameworkDefaults() -> ActionScope {
        let signal = QuitSignal()
        // Stash the signal on self so the event loop can poll it.
        // Overwrites the previous one; only the last-dispatched
        // signal matters because the loop polls every iteration.
        self.pendingQuitSignal = signal
        return makeFrameworkDefaultsScope(
            signal: signal,
            isPresenting: focusEngine.isContainingFocus
        )
    }

    private var pendingQuitSignal: QuitSignal?

    #if DEBUG
    /// Remote-control server. Nil unless `.terminalui/terminalui.toml`
    /// enables the `remote_control` feature — zero overhead otherwise. Pumped
    /// before each event drain, so injected keystrokes land in the frame they
    /// arrive in, and whenever its socket wakes an idle loop.
    private var remoteControl: RemoteControlServer?
    /// Whether this run may write diagnostics: false when its `/tmp` data
    /// dir is not its owner's alone (see `DiagPaths.prepareDataDirectories`),
    /// and then nothing — trace, screenshots, captures, warnings, socket —
    /// goes there.
    private var diagnosticsAreWritable = true
    #endif

    /// Creates a runtime for `content` without starting it — call ``run()``
    /// to take over the terminal.
    ///
    /// Defaults mirror ``TerminalAppProtocol``'s: `.fps60` pacing, no timers,
    /// and an `onEvent` that quits on `q` or Escape (return `false` from your
    /// own closure to quit). `devTrace` overrides the `.terminalui/` file
    /// config when non-nil; nil means "use the file config in DEBUG, nothing
    /// in release." `userKeymap` says where the app's users keep their own
    /// key bindings; the file is read here, its problems logged to stderr
    /// before the app takes the terminal.
    public init(
        renderMode: RenderMode = .fps60,
        timers: [TerminalTimer] = [],
        devTrace: DevTraceConfig? = nil,
        userKeymap: UserKeymapSource = .none,
        onEvent: @escaping (TerminalEvent) -> Bool = { event in
            if case .key(let k) = event, k.key == .character("q") { return false }
            if case .key(let k) = event, k.key == .escape { return false }
            return true
        },
        @TerminalViewBuilder content: @escaping () -> RootView
    ) {
        self.eventQueue = EventQueue(wake: wake)
        let bell = TerminalBell(wake: wake)
        self.bell = bell
        self.bellAction = BellAction { bell.ring() }
        self.graph = AttributeGraph(wake: wake)
        self.buildView = content
        self.onEvent = onEvent
        self.timers = timers
        self.renderMode = renderMode
        let url = userKeymap.url()
        self.userKeymap = url.flatMap(UserKeymap.init(contentsOf:)) ?? .none
        if let url {
            let log = Log("TerminalUI")
            for problem in self.userKeymap.problems {
                log.warn("\(url.path): \(problem)")
            }
        }
        self.tracer = DevTracer.shared
        self.size = Terminal.size()

        #if DEBUG
        // Load .terminalui/terminalui.toml and merge with programmatic overrides
        let fileConfig = DiagPaths.loadConfig()
        diagnosticsAreWritable = DiagPaths.prepareDataDirectories(config: fileConfig)
        if !diagnosticsAreWritable {
            Log("TerminalUI").warn(
                "\(DiagPaths.tmpDataDir) is not yours alone — another user's, a link, or readable "
                + "by others — so this run writes no diagnostics and opens no control socket")
        }

        if !diagnosticsAreWritable {
            tracer.configure(.default)
        } else if let devTrace {
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

    /// Takes over the terminal and runs the event loop until the app quits.
    ///
    /// Entering: raw mode, alternate screen, mouse tracking, bracketed paste,
    /// and signal-cleanup handlers so escape state never leaks to the parent
    /// shell. Returns after `onEvent` returns `false` or a quit action fires;
    /// terminal state is restored on every path, including thrown errors.
    /// SIGINT, SIGTERM or SIGHUP quits the same way, then ends the process
    /// with that signal. Throws ``TerminalRuntimeError/rawModeUnavailable`` —
    /// before touching the screen — when stdin isn't a TTY.
    @discardableResult
    public func run() async throws -> TerminationReason {
        try await runUntilQuit()
        return TerminationReason(terminationSignal: Terminal.terminationSignal)
    }

    private func runUntilQuit() async throws {
        // Self-pipes wake the input task's poll(): one when the runtime
        // shuts down — a blocked read() on stdin doesn't respect
        // Task.cancel() on Linux — one the SIGWINCH handler writes to, and
        // one a terminating signal writes to. Made before anything touches
        // the terminal, so failing leaves it as it was.
        // Closed last, after the defer below has cleared the descriptors.
        let wakePipes = try InputWakePipes()
        defer { wakePipes.close() }
        Terminal.installResizeHandler()
        // Raw-mode setup can fail when stdin isn't a TTY (CI, headless,
        // shell pipe). Propagate as a typed error so callers — and the
        // default @main shim — can decide whether to abort or fall back.
        // Aborting before alternate-screen entry keeps the terminal
        // state pristine for the failure message.
        guard Terminal.enableRawMode() else {
            throw TerminalRuntimeError.rawModeUnavailable
        }
        Terminal.enterAlternateScreen()
        Terminal.enableMouseTracking()
        Terminal.enableBracketedPaste()

        // Install signal handlers + atexit hook so terminal
        // escape state never leaks to the parent on SIGINT/SIGTERM/
        // SIGHUP/exit(). Without this, a Ctrl+C exit leaves the
        // terminal stuck in SGR 1006 mouse-tracking mode (mouse
        // movements paint coordinate strings into the user's shell)
        // and alternate-screen mode (shell prompt invisible). Bad
        // escape state IS a security concern: shell pipelines and
        // log readers can be hijacked by lingering DCS / OSC
        // sequences that survive a crashed child. Installed AFTER
        // raw-mode entry so `originalTermios` is captured.
        Terminal.installSignalCleanup()

        #if DEBUG
        // Tell DebugStream the visible terminal is now ours. Framework
        // warnings will route to warnings.log in the app's data dir instead
        // of stderr — stderr writes corrupt the rendered viewport.
        let liveDiagConfig = DiagPaths.loadConfig()
        let warningsURL = URL(fileURLWithPath: DiagPaths.warningsLogPath(useTmp: liveDiagConfig.useTmp))
        DebugStream.shared.setLiveTUI(true, logFileURL: diagnosticsAreWritable ? warningsURL : nil)
        #endif

        #if DEBUG
        // Auto-attach the remote-control server. Every TerminalUI
        // debug build becomes MCP-drivable without any per-app setup. Socket
        // path is PID-scoped so multiple apps running concurrently don't
        // collide. The server is non-blocking: no client = no overhead.
        //
        // gated on `socket.enabled` in `.terminalui/terminalui.toml`.
        // Default is true (preserves prior behaviour); users who want to
        // suppress the socket — security review, noisy /tmp, locked-down
        // environments — set `enabled = false` under `[socket]`.
        let diagConfig = DiagPaths.loadConfig()
        if diagConfig.socketEnabled, diagnosticsAreWritable {
            let socketDir = DiagPaths.socketDir(useTmp: diagConfig.useTmp)
            try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
            let socketPath = "\(socketDir)/\(ProcessInfo.processInfo.processIdentifier).sock"
            attachRemoteControl(socketPath: socketPath)
        }
        #endif

        Terminal.resizeWakeFD = wakePipes.resize.write
        Terminal.terminateWakeFD = wakePipes.terminate.write

        defer {
            tracer.writeSummary()
            #if DEBUG
            // Hand the terminal back; warnings can return to stderr now.
            DebugStream.shared.setLiveTUI(false)
            // drop the remote-control server explicitly so its deinit
            // unlinks the PID socket. Without this, killing the app left
            // stale sockets that confused the next debug run. Clearing the
            // ref triggers deinit now rather than on class dealloc (which
            // can be delayed arbitrarily).
            remoteControl = nil
            // Remove this process's per-PID tmpDataDir on graceful exit.
            // Crashes leave the dir for the next `swtui ctl reap` to
            // handle — orphan dirs are recoverable, live ones are not,
            // so cleanupOwnDir intentionally only touches the dir whose
            // PID matches the calling process.
            // Both go while the terminate pipe is still set: until it is
            // cleared below, a terminating signal only asks the app to
            // quit, which it is doing. After, the signal ends the process
            // at once, and SIGTERM sent to an app quitting on its own left
            // the dir behind.
            if diagnosticsAreWritable { DiagPaths.cleanupOwnDir() }
            #endif
            Terminal.disableBracketedPaste()
            Terminal.exitAlternateScreen()
            Terminal.disableRawMode()

            // Cleared before the pipes close, so a late signal does not write
            // to a closed — or reopened — descriptor. The input task, which
            // reads them, has ended: the loop waits for it.
            Terminal.resizeWakeFD = nil
            Terminal.terminateWakeFD = nil
        }

        // Make focus engine accessible during graph construction.
        // The binding spans the entire run loop so handlers fired
        // between frames (focus navigation, mouse routing) still see
        // the engine. `@TaskLocal` requires writes to go through
        // `withValue`; the run-loop body runs inside this closure and
        // the binding restores on exit — no manual teardown needed.
        try await GraphContext.$currentFocusEngine.withValue(focusEngine) {
            try await runFrameLoop(wakePipes: wakePipes)
        }
    }

    /// Body of `run()` after raw-mode setup and the focus-engine
    /// binding. Extracted so `run()` can wrap it in
    /// `GraphContext.$currentFocusEngine.withValue`.
    private func runFrameLoop(wakePipes: InputWakePipes) async throws {
        // The first frame, drawn before the loop's first `pump()`: no remote
        // request is answered, and no key handled, before the app is on
        // screen with its first focusable focused. It takes the path every
        // frame takes; a separate one for the first skipped auto-focus, and
        // the app came up unfocused until the loop drew again.
        renderDiffFrame()
        needsRender = false

        let queue = self.eventQueue

        // Producers push into the queue from their own threads — the input
        // task, timers, the remote-control dispatcher — and the loop below
        // drains it on the MainActor.

        // Blocks in one poll() between events — no timeout — so an idle app's
        // input thread sleeps; a resize arrives the same way, from SIGWINCH.
        // Cancellation cannot interrupt poll(); the shutdown pipe ends it.
        let wake = self.wake
        let inputTask = Task.detached {
            // One source for the life of the task, reading in chunks: bytes a
            // read took past the event it was for are the next event's.
            var source = StdinByteSource(input: STDIN_FILENO, buffered: true, wakes: wakePipes.wakes)
            while true {
                let activity: InputActivity = source.hasBufferedInput ? .input : source.waitForActivity()
                switch activity {
                case .input:
                    let event = InputParser.readEvent(from: &source)
                    // A hang-up or a wake to stop part-way through a sequence
                    // ends it early, and the parser makes a key of what it
                    // had: one nobody pressed. The next wait reports which.
                    if source.cutShort {
                        continue
                    }
                    queue.pushTerminalInput(event, bytesConsumed: source.bytesConsumed)
                case .resize:
                    let newSize = Terminal.size()
                    queue.pushTerminalInput(.resize(newSize.cols, newSize.rows), bytesConsumed: source.bytesConsumed)
                case .hangUp:
                    Terminal.recordHangUp()
                    fallthrough
                case .terminate:
                    // The loop reads `Terminal.terminationSignal`.
                    wake.wake()
                    return
                case .shutdown:
                    return
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

        // Frame loop — runs on MainActor.
        // Each iteration: drain events → handle → render → pace.
        // Event priority: view handlers first, then focus navigation, then debug tools.
        var running = true

        while running {
            #if DEBUG
            // pump the remote-control server before draining events
            // so anything the MCP client just injected (send_key, send_text)
            // lands in this frame's event batch rather than the next frame.
            remoteControl?.pump()
            #endif
            let events = eventQueue.drain()
            var pendingPointer: PendingPointer?
            for event in events {
                if !(pendingPointer?.continues(with: event) ?? false) {
                    route(&pendingPointer)
                }
                // Universal Ctrl+C is now an action graph default —
                // `Action.quit` bound to `.keyboard(.character("c"), [.ctrl])`
                // in `ActionScope.frameworkDefaults`. The runtime polls
                // `pendingQuitSignal` after each event to see if the
                // action fired during dispatch and tears down cleanly.
                // A presented modal owns Escape. Apps commonly bind Escape to
                // quit at the top level; honouring that while a dialog is up
                // would tear the process down instead of closing the dialog,
                // which is the worst failure mode in a terminal — there is no
                // window chrome to fall back on. The dialog's own binding
                // runs below in `handleKeyEvent`.
                var shouldContinue = onEvent(event)
                if !shouldContinue,
                   case .key(let k) = event,
                   k.key == .escape,
                   focusEngine.isContainingFocus {
                    shouldContinue = true
                }

                switch event {
                case .key(let keyEvent):
                    tracer.traceInput(keyEvent)
                    handleKeyEvent(keyEvent)
                    needsRender = true
                    // Poll the framework-default quit signal — if the
                    // dispatch fired Action.quit (or Action.dismissOrQuit
                    // when no modal is up) we exit cleanly here.
                    if pendingQuitSignal?.fired == true {
                        running = false
                        break
                    }

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
                            debugPanel.scrollGraphUp(amount: linesPerWheelNotch)
                            needsRender = true
                            break
                        }
                        if case .scrollDown = mouseEvent.kind {
                            debugPanel.scrollGraphDown(amount: linesPerWheelNotch)
                            needsRender = true
                            break
                        }
                    }
                    #endif
                    switch mouseEvent.kind {
                    case .press(.left):
                        if mousePolicy(at: mouseEvent) == .disabled {
                            // .disabled: no auto-focus promotion. Fire any
                            // .onClick handler under the cursor, then stop.
                            if let root = graph.root {
                                focusEngine.fireClickHandlerOnly(x: mouseEvent.x, y: mouseEvent.y, root: root)
                            }
                        } else {
                            focusEngine.handleMouseClick(x: mouseEvent.x, y: mouseEvent.y, root: graph.root)
                        }
                    case .moved, .drag:
                        pendingPointer = .motion(mouseEvent)
                    case .scrollUp, .scrollDown:
                        let key: Key = mouseEvent.kind == .scrollUp ? .up : .down
                        if case .wheel(key, mouseEvent.x, mouseEvent.y, let notches) = pendingPointer {
                            pendingPointer = .wheel(key: key, x: mouseEvent.x, y: mouseEvent.y, notches: notches + 1)
                        } else {
                            route(&pendingPointer)
                            pendingPointer = .wheel(key: key, x: mouseEvent.x, y: mouseEvent.y, notches: 1)
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

                case .paste(let payload):
                    // Paste payloads route to the focused view via a paste
                    // handler (registered through `.onPaste`). Until any
                    // view declares paste interest, drop on the floor —
                    // safer than fanning out fast-typed character events
                    // that the user did NOT type.
                    handlePasteEvent(payload)
                    needsRender = true
                }

                if !shouldContinue {
                    running = false
                    break
                }
            }
            route(&pendingPointer)

            // A quit can arrive without a key: `invoke_action` from a remote
            // client fires one outside event handling, and a terminating
            // signal asks for one.
            if quitRequestedOutsideEvents {
                running = false
            }

            // Render
            if running {
                if case .uncapped = renderMode {
                    // Always render — for benchmarking max throughput
                    renderDiffFrame()
                    needsRender = false
                    soundPendingBell()
                    await Task.yield()
                    continue
                }
                let frameStart = ContinuousClock.now
                if needsFrame {
                    renderDiffFrame()
                    needsRender = false
                }
                soundPendingBell()
                await waitForWork()
                // `.capped` draws at most one frame per interval: woken early,
                // it waits out the rest. After a long idle there is none left.
                if case .capped(let interval) = renderMode {
                    let remaining = interval - (ContinuousClock.now - frameStart)
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                    }
                }
            }
        }

        // Wake the input task out of its blocked poll() so quit doesn't hang.
        wakePipes.shutdown.signal()
        // `run()` clears the pipe's descriptor and closes the pipe as soon as
        // this returns, and the input task reads both on its own thread.
        // Unwaited, it could poll a closed descriptor, or one the cleanup that
        // follows has reopened, or fall back to a blocking read of a stdin the
        // shell has taken back.
        await inputTask.value
        for t in timerTasks { t.cancel() }
    }

    /// Whether the next frame has anything to draw: input or a remote
    /// command asked for one, or `@Observable` state changed — from whatever
    /// thread changed it. Gating on input alone meant state mutated by a
    /// `Task` was not drawn until the user happened to press a key.
    private var needsFrame: Bool {
        needsRender || graph.hasDirtyNodes
    }

    /// Sleeps until there is something to do: an event, a frame to draw, a
    /// quit fired outside event handling or — in a debug build — a remote
    /// command, which the loop's one `pump()` serves before it drains events,
    /// so a query is answered only after the keys sent before it are drawn.
    private func waitForWork() async {
        // Wakes raised while the loop was busy were for work it has just
        // done; one left pending would only cost an empty pass.
        wake.discardPending()
        while !hasWork {
            await wake.wait()
            if Task.isCancelled { return }
        }
    }

    /// Writes BEL if the bell rang and no frame carried it — one that drew
    /// nothing, or none drawn at all, as when a background task rang.
    private func soundPendingBell() {
        guard bell.take() else { return }
        Terminal.writeRaw(TerminalBell.sequence)
    }

    private var quitRequestedOutsideEvents: Bool {
        pendingQuitSignal?.fired == true || Terminal.terminationSignal != nil
    }

    private var hasWork: Bool {
        if eventQueue.hasEvents || needsFrame || bell.isPending || quitRequestedOutsideEvents {
            return true
        }
        #if DEBUG
        return remoteControl?.hasPendingActivity ?? false
        #else
        return false
        #endif
    }

    // MARK: - Mouse-driven Routing

    /// Deliver the pointer events held back, and forget them. Where the
    /// wheel and the cursor land is `FocusEngine`'s to decide.
    private func route(_ pending: inout PendingPointer?) {
        defer { pending = nil }
        guard let root = graph.root else { return }
        switch pending {
        case .wheel(let key, let x, let y, let notches):
            let at = MouseEvent(kind: key == .up ? .scrollUp : .scrollDown, x: x, y: y)
            _ = focusEngine.routeWheel(KeyEvent(key: key), root: root, x: x, y: y,
                                       policy: mousePolicy(at: at), steps: notches * linesPerWheelNotch)
        case .motion(let mouseEvent):
            focusEngine.applyMouseMove(x: mouseEvent.x, y: mouseEvent.y, root: root,
                                       policy: mousePolicy(at: mouseEvent))
        case nil:
            break
        }
    }

    /// The mouse-focus policy at the cursor, from the deepest node under it
    /// rather than the app-level GraphContext (which is nil between
    /// renders). Lets a sub-view override the policy while the surrounding
    /// shell keeps the default — matches SwiftUI's per-subtree env model.
    private func mousePolicy(at mouseEvent: MouseEvent) -> MouseFocusPolicy {
        guard let root = graph.root else { return .clickToLock }
        return focusEngine.resolveEnv(x: mouseEvent.x, y: mouseEvent.y, root: root).mouseFocusPolicy
    }

    // MARK: - Paste Event Handling

    /// Route a bracketed-paste payload to whichever view has registered
    /// paste interest (via `.onPaste`). The dispatch is intentionally
    /// minimal here — paste routing lives at the focused-view level so
    /// per-component paste semantics (collapsed markers in PromptInput,
    /// raw insertion in TextArea, etc.) stay in those components.
    /// Until any view declares paste interest the payload is dropped.
    private func handlePasteEvent(_ payload: String) {
        #if DEBUG
        debugPanel.recordInput(
            "paste(\(payload.count) bytes)",
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        #endif
        // Route to the keyboard-focused subtree's `.onPaste` handler.
        // Drop on the floor when no view declares paste interest —
        // safer than fanning out fast-typed character events that
        // the user did NOT type.
        _ = focusEngine.routePasteEvent(payload, root: graph.root)
    }

    // MARK: - Key Event Handling

    private func handleKeyEvent(_ keyEvent: KeyEvent) {
        #if DEBUG
        let sourceTag: String
        switch keyEvent.source {
        case .stdin:  sourceTag = ""
        case .remote: sourceTag = "mcp "
        }
        debugPanel.recordInput(
            sourceTag + describeKeyEvent(keyEvent),
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

        // SECOND: action graph dispatch. Walks the focus chain from the
        // focused node up to the root, accumulating ActionScopes from
        // every `.actions { ... }` modifier; framework defaults
        // (Ctrl+C → quit, Esc → dismissOrQuit) sit outermost so user
        // scopes shadow them via the standard innermost-wins rule.
        // Mouse/gesture/voice/accessibility dispatch will route through
        // the same path with different InputBinding cases.
        if !handledByView,
           let focused = focusEngine.focusedNode(in: graph.root) {
            let binding: InputBinding = .keyboard(keyEvent.key, keyEvent.modifiers)
            let defaults = makeFrameworkDefaults()
            let firedAction = ActionDispatch.dispatch(
                binding: binding,
                from: focused,
                frameworkDefaults: defaults
            )
            if firedAction { return }
        }

        if !handledByView {
            // Focus navigation — Tab/Shift+Tab always navigate.
            //
            // Arrows traverse whichever container owns the focused node,
            // dispatched through `FocusableContainer` so every container kind
            // behaves consistently. Containers hold focus at their own edges
            // per the user's 2026-04-18 rule; only when no container claims
            // the direction at all may arrows fall through to global Tab
            // order, and that still requires `allowArrowFocusNavigation`.
            if keyEvent.key == .tab && keyEvent.modifiers.contains(.shift) {
                focusEngine.focusPrevious()
            } else if keyEvent.key == .tab {
                focusEngine.focusNext()
            } else if let direction = keyEvent.key.focusDirection, let root = graph.root {
                // Resolve `allowArrowFocusNavigation` from the focused
                // node's stamped `_resolvedEnv`, NOT from a global
                // `GraphContext.currentEnvironment`. The TaskLocal
                // binding is bound only for the duration of a frame's
                // render walk; key events run between frames where it
                // would read nil. `_resolvedEnv` is stamped during
                // every render (see `GraphRenderer.render`) and persists.
                let focused = focusEngine.focusedNode(in: graph.root)
                let crossStack = focused?._resolvedEnv?.allowArrowFocusNavigation == true
                let before = focusEngine.keyboardFocusID
                if focusEngine.move(direction, root: root) == .unhandled, crossStack {
                    switch direction {
                    case .up, .left: focusEngine.focusPrevious()
                    case .down, .right: focusEngine.focusNext()
                    }
                }
                // Focus had nowhere to go, but the region holding it may still
                // have something to show: the rows past the last control of a
                // form — a version string, a gauge, a footer — are laid out and
                // drawn and were unreachable, because scroll-to-focused only
                // ever follows focus.
                if focusEngine.keyboardFocusID == before {
                    _ = focusEngine.scrollFocusedRegion(direction, root: root)
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

    private func renderDiffFrame() {
        frameCounter.beginFrame()
        tracer.beginFrame()

        let buildStart = monotonicNanoseconds()

        // Three-way fork:
        //  1. First frame OR external structural signal (`needsRender`,
        //     resize) → root rebuild via `update(from:)`.
        //  2. Pure state mutation (Observation onChange fired,
        //     dirtyQueue non-empty) → in-place drain. Skips
        //     `buildView()` + reconciliation walk; only the affected
        //     subtrees re-evaluate.
        //  3. Nothing dirty → no graph work this frame.
        //
        // External review flagged that the runtime always took
        // path (1). The drain path was tested at the graph level
        // (verified at the graph level) but unreached on the production frame.
        // Focus moved since the last frame — by a key, a click, a focused
        // view leaving the tree — so the bodies that read it are due.
        graph.focusMoved(to: focusEngine.keyboardFocusID)
        let firstFrame = previousBuffer == nil
        let structuralRebuild = firstFrame || needsRender
        let stateOnlyDirty = graph.hasDirtyNodes && !structuralRebuild
        let needsWork = structuralRebuild || stateOnlyDirty

        // Bind environment + proposed size for the entire frame. The
        // bindings are observed by body evaluation, measurement,
        // layout, and render — all called from inside this closure.
        // Use the current binding (if any) as the base so settings
        // bound at run-loop scope (e.g., a future global env override)
        // still propagate.
        var env = GraphContext.currentEnvironment ?? EnvironmentValues()
        env.terminalSize = size
        env.bell = bellAction
        env.killBuffer = killBuffer
        env.cursorFlash = cursorFlash
        env.userKeymap = userKeymap
        env.focusedID = focusEngine.keyboardFocusID
        GraphContext.$currentEnvironment.withValue(env) {
            GraphContext.$currentProposedSize.withValue(Size(width: size.cols, height: size.rows)) {
                renderDiffFrameBody(
                    buildStart: buildStart,
                    structuralRebuild: structuralRebuild,
                    needsWork: needsWork
                )
            }
        }
    }

    private func renderDiffFrameBody(buildStart: UInt64, structuralRebuild: Bool, needsWork: Bool) {
        var graphChanged = false

        if needsWork {
            focusEngine.clearHandlers()

            if structuralRebuild {
                let view = buildView()
                graphChanged = graph.update(from: view)
            } else {
                // Pure state mutation — drain in place. Returns true
                // when at least one node re-evaluated, which means
                // the visible output may have changed.
                graphChanged = graph.drain()
            }

            // Rebuild focus index after graph changes
            if let root = graph.root {
                focusEngine.rebuildIndex(root: root)
                // Auto-focus on startup: the view that asked with
                // `.prefersDefaultFocus()`, else the first focusable. With
                // arrows no longer moving focus by default, an app whose
                // arrow handler lives on a `.focusable()` view would receive
                // nothing until the user pressed Tab. Mirrors SwiftUI's
                // implicit first-responder — the app boots with a focused
                // element so per-view handlers fire on the very first key.
                if focusEngine.keyboardFocusID == nil {
                    focusEngine.focusDefault()
                }
            }

            // The first focusable is chosen only once this frame's graph
            // exists — after its bodies ran in an environment that named no
            // focus. Re-run the bodies that read focus, and draw, in the
            // environment that names it, so the first frame already shows it.
            var drawEnvironment = GraphContext.currentEnvironment ?? EnvironmentValues()
            if drawEnvironment.focusedID != focusEngine.keyboardFocusID {
                drawEnvironment.focusedID = focusEngine.keyboardFocusID
                if graph.focusMoved(to: focusEngine.keyboardFocusID) {
                    GraphContext.$currentEnvironment.withValue(drawEnvironment) {
                        graphChanged = graph.drain() || graphChanged
                    }
                    if let root = graph.root {
                        focusEngine.rebuildIndex(root: root)
                    }
                }
            }

            // Render if graph changed OR if we were explicitly told to (key press, etc.)
            if graphChanged || previousBuffer == nil || needsRender {
                GraphContext.$currentEnvironment.withValue(drawEnvironment) {
                    drawDiffFrame(buildStart: buildStart)
                }
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

    /// Lay out, draw and flush a frame whose graph is settled — the second
    /// half of ``renderDiffFrameBody(buildStart:structuralRebuild:needsWork:)``.
    private func drawDiffFrame(buildStart: UInt64) {
        // Adjust scroll offsets to keep focused child visible
        GraphRenderer.adjustScrollForFocus(
            root: graph.root, focusedID: focusEngine.keyboardFocusID,
            viewportWidth: size.cols, viewportHeight: size.rows
        )
        GraphRenderer.adjustScrollForExplicitTarget(
            root: graph.root,
            viewportWidth: size.cols, viewportHeight: size.rows
        )

        // Reuse the render buffer across frames. Resize
        // is a no-op when geometry is stable; clear sets every
        // cell back to .empty so the renderer paints into a known
        // baseline. The post-render diff still produces minimal
        // ANSI output regardless.
        renderBuffer.resize(width: size.cols, height: size.rows)
        let context = RenderContext(rect: Rect(x: 0, y: 0, width: size.cols, height: size.rows))
        if let root = graph.root {
            // Phase separation: layout pass before render so
            // GR rebuilders + rect math run outside the render
            // walk. Render reads the resolved tree as a pure draw.
            Layout.measureAndPlace(graph: root, in: context.rect)
            GraphRenderer.render(root, into: &renderBuffer, context: context)
            GraphRenderer.reportScrollTargetVisibility(root: root)
        }

        // Focus indicators
        GraphRenderer.renderFocusIndicators(into: &renderBuffer, focusEngine: focusEngine, root: graph.root)

        #if DEBUG
        debugOverlay.render(into: &renderBuffer, stats: frameStats)
        debugPanel.render(into: &renderBuffer, graph: graph, stats: frameStats)
        inspector.render(into: &renderBuffer, graph: graph)

        if captureCurrentFrame {
            captureCurrentFrame = false
            captureFrame(buffer: renderBuffer)
        }
        #endif

        let changedCells = renderBuffer.countDiff(from: previousBuffer)
        renderBuffer.renderDiff(from: previousBuffer, into: &outputBuffer)
        if bell.take() { outputBuffer.write(TerminalBell.sequence) }
        let buildEnd = monotonicNanoseconds()

        outputBuffer.flush()
        let flushEnd = monotonicNanoseconds()

        tracer.endFrame(buffer: renderBuffer, previousBuffer: previousBuffer)
        frameStats = frameCounter.endFrame(
            cellsChanged: changedCells, totalCells: renderBuffer.width * renderBuffer.height,
            buildNs: buildEnd - buildStart, flushNs: flushEnd - buildEnd,
            bytesWritten: outputBuffer.size
        )
        #if DEBUG
        debugPanel.recordFrameTime(Double(buildEnd - buildStart) / 1_000_000.0)
        #endif
        previousBuffer = renderBuffer
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
        case .activate: parts.append("act")
        }
        return parts.joined(separator: "-")
    }

    private func captureFrame(buffer: CellBuffer) {
        guard diagnosticsAreWritable else { return }
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
            case .cellBuffer(let buf): kind = "BufferView(\(buf.width)x\(buf.height))"
            }
        case .layout(let info):
            switch info.kind {
            case .vstack: kind = "VStack[\(node.children.count)]"
            case .hstack: kind = "HStack[\(node.children.count)]"
            case .zstack: kind = "ZStack[\(node.children.count)]"
            case .scroll(let axis):
                kind = "ScrollView(\(axis == .horizontal ? "H" : "V"))[\(node.children.count)]"
            case .split(let axis):
                kind = "SplitView(\(axis == .horizontal ? "H" : "V"))[\(node.children.count)]"
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

    // MARK: - Remote control

    /// Attach a remote-control server to this runtime. Called by the runtime
    /// at startup in every debug build (zero opt-in) — the server is
    /// non-blocking, and an app with no connected client pays one `accept()`
    /// per frame it draws and nothing while idle.
    public func attachRemoteControl(socketPath: String) {
        let wake = self.wake
        remoteControl = RemoteControlServer(
            path: socketPath,
            dispatcher: RuntimeRemoteDispatcher(runtime: self),
            onActivity: { wake.wake() }
        )
    }

    /// Inject a `TerminalEvent` from outside the event loop. Called by the
    /// remote-control dispatcher so test scripts can drive keystrokes without
    /// a PTY. Goes through the same queue as real stdin input, so handlers
    /// run exactly as they would for a user press.
    ///
    /// Remote-origin events carry `KeyEvent.source == .remote`. The debug
    /// input log reads the source and prefixes the breadcrumb accordingly
    /// so the audit trail distinguishes MCP-injected keys from real stdin
    /// — critical when pairing a smoke-test failure with the captured frame.
    public func enqueueEvent(_ event: TerminalEvent) {
        eventQueue.push(event)
    }

    /// Expose the graph root for remote queries. Callers treat the returned
    /// node as read-only — mutating it would race the render pass.
    public func remoteCurrentGraphRoot() -> AttributeNode? { graph.root }

    /// Expose the focus engine for remote queries (focused node id, rect).
    public func remoteFocusEngine() -> FocusEngine { focusEngine }

    /// Expose the inspector for remote probing.
    public func remoteInspector() -> Inspector { inspector }

    /// Build the framework's default action scope so remote
    /// `list_actions` / `invoke_action` route through the same data
    /// the runtime's own dispatch uses. Each call yields a fresh
    /// scope wired to a new QuitSignal — the LLM-side invoke path
    /// fires the signal and the event loop's poll exits cleanly,
    /// matching the keyboard Ctrl+C path exactly.
    public func remoteFrameworkDefaultsScope() -> ActionScope {
        let signal = QuitSignal()
        self.pendingQuitSignal = signal
        return makeFrameworkDefaultsScope(
            signal: signal,
            isPresenting: focusEngine.isContainingFocus
        )
    }

    /// Expose the last rendered buffer for `query_cells`. The runtime keeps
    /// `previousBuffer` around between frames; after the first render it
    /// mirrors what's on screen.
    public func remotePreviousBuffer() -> CellBuffer? { previousBuffer }

    /// Ask for a full-frame capture on the next render. The dispatcher
    /// returns the file path once the capture flushes. Matches the F4 debug
    /// key binding that already exists.
    public func remoteRequestCapture() {
        captureCurrentFrame = true
        needsRender = true
    }

    /// A remote command changed what is drawn — focus, the inspector, an
    /// action's effects — without an event or observed state to say so.
    public func remoteRequestFrame() { needsRender = true }

    /// Current frame number — the dispatcher reports it for `wait_for_frame`
    /// bookkeeping on the client side. Pulled from the global `frameStats`
    /// updated once per frame by `FrameCounter.endFrame`.
    public func remoteCurrentFrameNumber() -> Int { frameStats.frameCount }

    public func remoteTerminalInputTaken() -> TerminalInputTaken { eventQueue.terminalInputTaken }
    #endif
}

#if DEBUG
extension TerminalRuntime: RemoteControlRuntime {}
#endif

// MARK: - Runtime errors

/// Thrown by ``TerminalRuntime/run()`` when the framework can't bring
/// the terminal up cleanly.
///
/// App templates that always run on a TTY can let it propagate to `@main`;
/// apps that handle non-TTY environments (CI, headless tests, pipe stdin)
/// catch it and fall back to a non-interactive mode. It is thrown before
/// alternate-screen entry, so on failure the terminal is untouched and a
/// plain error message prints cleanly — the default
/// ``TerminalAppProtocol/main()`` shim does exactly that (logs and exits 1).
/// Write a custom `@main` that catches it when you want richer fallback,
/// e.g. rendering once via `TerminalApp.print(_:width:)` and exiting 0.
public enum TerminalRuntimeError: Error, Equatable {
    /// `pipe(2)` failed — the process is out of file descriptors. The runtime
    /// needs two self-pipes to wake its input task.
    case wakePipeUnavailable
    /// `Terminal.enableRawMode()` returned false — `tcgetattr` or
    /// `tcsetattr` failed (typically because stdin isn't a TTY).
    /// Without raw mode the input parser can't deliver per-keystroke
    /// events; running the loop anyway would silently break input.
    case rawModeUnavailable
}

// MARK: - Quit signal + framework defaults helper
//
// Lifted out of `TerminalRuntime<RootView>` so the @Sendable closure
// inside `makeFrameworkDefaultsScope` doesn't capture `RootView.Type`
// from the runtime's generic context. Without this split,
// TUI_WARNINGS_AS_ERRORS=1 fails with #SendableMetatypes on
// "capture of non-Sendable type 'RootView.Type' in an isolated closure".

/// Lock-protected one-shot quit flag. The framework default
/// `Action.quit` perform closure fires this; the event loop polls
/// `fired` once per iteration and tears down the runtime on `true`.
final class QuitSignal: Sendable {
    private let state = Atomic<Bool>(false)
    func fire() { state.store(true, ordering: .releasing) }
    var fired: Bool { state.load(ordering: .acquiring) }
}

/// Build the framework's default ActionScope. Free helper, no
/// generics. The @Sendable closure captures only `signal`, which is
/// a concrete reference type — no metatype involvement, so the
/// strict-sendability gate accepts this.
///
/// `isPresenting` gates the Esc default: a presented screen owns
/// Escape even when its own handlers ignored the key. Quitting out
/// from under a presentation is the worst failure mode in a
/// terminal — there is no window chrome to recover from — so the
/// dismiss-or-quit default only quits when nothing is presented.
/// A plain Bool suffices: the scope is built fresh per dispatch, so
/// the value is current for exactly the event being dispatched.
@MainActor
func makeFrameworkDefaultsScope(signal: QuitSignal, isPresenting: Bool) -> ActionScope {
    let quit: @Sendable () -> Void = { signal.fire() }
    let ownedByPresentation: @Sendable () -> Void = {}
    return ActionScope.frameworkDefaults(
        quit: quit,
        dismissOrQuit: isPresenting ? ownedByPresentation : quit
    )
}

// MARK: - @main entry point protocol

/// The app entry point: conform with `@main`, implement `content()`, done.
///
/// This is the TerminalUI equivalent of SwiftUI's `App`. Everything except
/// `content()` has a default — `.fps60` pacing, no timers, quit on `q` or
/// Escape — so a minimal app is:
///
/// ```swift
/// @main
/// struct HelloApp: TerminalAppProtocol {
///     static func content() -> some TerminalView {
///         Text("Hello, terminal").padding().border()
///     }
/// }
/// ```
///
/// Requirements are `static` because `@main` needs a callable `main()`
/// without an instance; app state belongs in `@Observable` models the views
/// reference, not on the conforming type. Note the entry point is this
/// protocol — ``TerminalApp`` is an enum namespace for non-interactive
/// helpers like `TerminalApp.print(_:width:)`, not something you run.
public protocol TerminalAppProtocol {
    /// The root view type, inferred from `content()`'s return type.
    associatedtype Content: TerminalView
    /// Frame pacing for the runtime. Defaults to `.fps60`; use `.onDemand`
    /// for zero idle CPU.
    static var renderMode: RenderMode { get }
    /// Named repeating timers, delivered as `.timer(name)` events. Defaults
    /// to none.
    static var timers: [TerminalTimer] { get }
    /// Diagnostic trace configuration. `nil` defers to the `.terminalui/`
    /// file config; the default provides a trace-enabled config in DEBUG and
    /// `nil` in release.
    static var devTrace: DevTraceConfig? { get }
    /// App-level event hook, called before view-level handlers for every
    /// ``TerminalEvent``. Return `false` to quit the app. The default quits
    /// on `q` or Escape.
    static func onEvent(_ event: TerminalEvent) -> Bool
    /// Called once the app has torn down — the terminal handed back, its
    /// per-process files removed — with why it ended: the place to save what
    /// must outlive the process, such as an unsent draft when the connection
    /// drops. Returns how the process ends. The default is `.conventional`.
    static func willTerminate(_ reason: TerminationReason) -> TerminationEnding
    /// Where the app's users keep their own key bindings — see
    /// ``UserKeymap``. The default, `.none`, reads no file: an app opts
    /// in, and says where. Read once, before the app takes the terminal;
    /// what cannot be read is printed to stderr and the rest applies.
    static var userKeymap: UserKeymapSource { get }
    /// Builds the root view. Re-invoked whenever the runtime needs a
    /// structural rebuild; keep it a pure function of app state.
    @TerminalViewBuilder static func content() -> Content
}

extension TerminalAppProtocol {
    /// Default: `.fps60`.
    public static var renderMode: RenderMode { .fps60 }
    /// Default: no timers.
    public static var timers: [TerminalTimer] { [] }
    /// Default: in DEBUG, tracing enabled with a 100-frame limit; in
    /// release, `nil` (no diagnostic machinery exists in release builds).
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

    /// Default: quit on `q` or Escape, pass everything else through. Apps
    /// with text input almost always override this — a typed `q` would
    /// otherwise end the process.
    public static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event, k.key == .character("q") { return false }
        if case .key(let k) = event, k.key == .escape { return false }
        return true
    }

    /// Default: no user keymap.
    public static var userKeymap: UserKeymapSource { .none }

    /// Default: end as the parent would have seen without the runtime.
    public static func willTerminate(_ reason: TerminationReason) -> TerminationEnding {
        .conventional
    }

    /// The `@main` entry: builds a ``TerminalRuntime`` from the static
    /// requirements and runs it. On ``TerminalRuntimeError/rawModeUnavailable``
    /// (stdin not a TTY) it logs to stderr and exits 1; write your own
    /// `main()` to handle non-TTY environments differently.
    @MainActor public static func main() async {
        let runtime = TerminalRuntime(
            renderMode: renderMode,
            timers: timers,
            devTrace: devTrace,
            userKeymap: userKeymap,
            onEvent: { onEvent($0) },
            content: { content() }
        )
        // Default @main shim: surface raw-mode failure via TerminalLog
        // (auto-routes to stderr for warn/error/critical) and exit
        // with status 1. App authors who want richer non-TTY handling
        // can implement their own @main calling runtime.run() and
        // catching TerminalRuntimeError directly.
        let log = Log("TerminalUI")
        let reason: TerminationReason
        do {
            reason = try await runtime.run()
        } catch TerminalRuntimeError.rawModeUnavailable {
            log.error("stdin is not a TTY; raw mode unavailable. Run from a terminal.")
            exit(1)
        } catch {
            log.error("runtime error: \(error)")
            exit(1)
        }
        reason.end(willTerminate(reason))
    }
}

// MARK: - Inline printing (no event loop)

/// Namespace for rendering views outside the interactive runtime.
///
/// This is not the app entry point — apps conform to
/// `TerminalAppProtocol` with `@main`. `TerminalApp` serves non-render
/// contexts: one-shot styled output to stdout with no event loop, no raw
/// mode, no alternate screen.
public enum TerminalApp {
    /// Renders `view` once and prints it to stdout as ANSI-styled lines.
    ///
    /// `width` `nil` uses the terminal's current column count; height is
    /// whatever the view measures at that width. Interactive features
    /// (focus, handlers, timers) are inert here.
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
