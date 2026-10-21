#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Synchronization

// MARK: - ANSI Escape Sequences
// Reference: ECMA-48, xterm ctlseqs (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

/// DEC private modes for alternate screen, cursor visibility, and mouse tracking.
/// These are xterm extensions adopted by virtually all modern terminal emulators.
/// Terminals that don't support them will silently ignore the sequences.
private enum ANSIMode {
    /// DEC private mode: alternate screen buffer (saves/restores main screen)
    static let alternateScreen = 1049
    /// DECTCEM: text cursor enable mode (show/hide cursor)
    static let cursorVisible = 25
    /// xterm: basic mouse click tracking
    static let mouseBasic = 1000
    /// xterm: button-event (drag) tracking
    static let mouseDrag = 1002
    /// xterm: any-event tracking (includes mouse motion without buttons)
    static let mouseMotion = 1003
    /// SGR 1006: extended mouse coordinate format — supports positions beyond column 223
    /// where the legacy X10 encoding breaks (single-byte limit)
    static let mouseSGR = 1006
    /// xterm bracketed paste mode (2004): the terminal wraps pasted content
    /// in `ESC[200~ ... ESC[201~` so the InputParser can disambiguate a
    /// real paste burst from very fast typed input. Without this, pasted
    /// content arrives byte-by-byte indistinguishable from keyboard input.
    static let bracketedPaste = 2004
}

private let csi = "\u{1B}["

/// Enable a DEC private mode
private func enableMode(_ mode: Int) -> String { "\(csi)?\(mode)h" }
/// Disable a DEC private mode
private func disableMode(_ mode: Int) -> String { "\(csi)?\(mode)l" }

/// Platform-agnostic POSIX write — resolves ambiguity between Darwin.write and Glibc.write
/// that arises when both `Foundation` and platform modules are imported.
@inline(__always)
internal func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buf, count)
    #elseif canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #endif
}

/// `write` for a socket whose peer may already have gone. A plain `write` to
/// a stream socket the peer closed raises SIGPIPE, and its default action
/// ends the process inside the call: no handler runs, so the terminal stays
/// in raw mode on the alternate screen with mouse tracking on. A client that
/// hangs up before reading its reply is ordinary (`swtui ctl kill` does), so
/// the failure has to come back as `EPIPE` instead. `MSG_NOSIGNAL` does that
/// per call (POSIX.1-2008 `send`, defined by both Glibc and Darwin), without taking
/// SIGPIPE away from the app that owns the process.
@inline(__always)
internal func socketWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.send(fd, buf, count, Int32(MSG_NOSIGNAL))
    #elseif canImport(Darwin)
    return Darwin.send(fd, buf, count, MSG_NOSIGNAL)
    #endif
}

/// Atomic flag set by SIGWINCH handler, polled by resize task.
/// Atomic<Bool> is async-signal-safe and eliminates TOCTOU races
/// between the signal handler (any thread) and the main loop polling.
private let _resizeFlag = Atomic<Bool>(false)

// MARK: - Crash-path signal cleanup (HYP-324)
//
// Signal handlers and atexit hooks must be `@convention(c)` and
// non-capturing. Swift forbids forming C function pointers from
// closures that close over Self or any state, so these live at
// file scope and call into `Terminal`'s static surface directly.
// Both handlers are async-signal-safe: they only invoke
// `posix_write` and `tcsetattr`, both on POSIX.1's signal-safe list.

@_cdecl("_terminalSignalHandler")
internal func _terminalSignalHandler(signum: Int32) {
    Terminal.runCleanup()
    // Restore default disposition + re-raise so the parent shell
    // sees the conventional exit code (130 for SIGINT, 143 for
    // SIGTERM, 129 for SIGHUP).
    #if canImport(Darwin)
    _ = Darwin.signal(signum, SIG_DFL)
    _ = Darwin.raise(signum)
    #elseif canImport(Glibc)
    _ = Glibc.signal(signum, SIG_DFL)
    _ = Glibc.raise(signum)
    #endif
}

/// Signals that end the process because something went wrong in it rather
/// than because it was asked to stop: a bad memory access, a Swift runtime
/// trap (`brk` on arm64 raises SIGTRAP, `ud2` on x86-64 SIGILL), an
/// arithmetic fault, `abort()`.
private let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT]

/// What each of ``fatalSignals`` did before the terminal took it over —
/// usually the Swift runtime's backtracer. Allocated once at install so the
/// handler reads it without allocating, which a signal handler must not do.
nonisolated(unsafe) private let previousFatalActions =
    UnsafeMutablePointer<sigaction>.allocate(capacity: fatalSignals.count)

/// Set once ``previousFatalActions`` holds what came before the terminal's
/// handlers. Installing again must not record those handlers as their own
/// predecessors: a crash would then hand the signal back to the handler
/// that was running, forever.
private let fatalHandlersInstalled = Atomic<Bool>(false)

/// Restore the terminal, then hand the signal back to whoever had it.
///
/// A crash used to leave raw mode, the alternate screen and mouse tracking
/// on: the backtrace printed as a staircase over the app's last frame, and
/// every mouse movement afterwards typed SGR coordinates into the shell.
/// Restoring the previous action and raising again keeps the backtrace — the
/// re-raised signal stays pending while this handler runs, and is delivered
/// to the restored handler, in the faulting thread, when it returns.
@_cdecl("_terminalFatalSignalHandler")
internal func _terminalFatalSignalHandler(signum: Int32) {
    Terminal.runCleanup()
    if let index = fatalSignals.firstIndex(of: signum) {
        _ = sigaction(signum, previousFatalActions + index, nil)
    } else {
        #if canImport(Darwin)
        _ = Darwin.signal(signum, SIG_DFL)
        #elseif canImport(Glibc)
        _ = Glibc.signal(signum, SIG_DFL)
        #endif
    }
    #if canImport(Darwin)
    _ = Darwin.raise(signum)
    #elseif canImport(Glibc)
    _ = Glibc.raise(signum)
    #endif
}

@_cdecl("_terminalAtExitHandler")
internal func _terminalAtExitHandler() {
    Terminal.runCleanup()
}

// MARK: - Terminal Size

private let vt100DefaultCols = 80
private let vt100DefaultRows = 24

/// The terminal window's dimensions in character cells.
public struct TerminalSize: Sendable {
    /// Width in columns.
    public var cols: Int
    /// Height in rows.
    public var rows: Int

    /// VT100 default (80x24) — fallback when ioctl(TIOCGWINSZ) fails
    /// (e.g. stdout is piped, not a TTY, or running in CI).
    public static let `default` = TerminalSize(cols: vt100DefaultCols, rows: vt100DefaultRows)
}

// MARK: - POSIX Syscall Injection
//
// `Terminal` calls `tcgetattr`, `tcsetattr`, and `ioctl(TIOCGWINSZ)`
// directly. Failure paths (non-TTY stdin, headless CI, ioctl returning
// 0×0) couldn't be exercised under the real test runner because the
// runner happens to be a TTY. This protocol lets tests inject a
// `FailingPosixSyscalls` mock and pin the failure-mode contract at
// the unit boundary. Production code uses `RealPosixSyscalls` which
// delegates straight through to libc with no overhead.

/// Injection seam for the three libc calls `Terminal` makes — exists so
/// tests can fault-inject syscall failures (non-TTY stdin, headless CI,
/// a 0x0 window size) that a real TTY test runner can never produce.
/// Production uses `RealPosixSyscalls`; tests use ``FailingPosixSyscalls``.
public protocol PosixSyscalls: Sendable {
    /// `tcgetattr(3)`: read `fd`'s termios state into `termiosOut`;
    /// 0 on success, -1 on failure.
    func tcgetattr(_ fd: Int32, _ termiosOut: UnsafeMutablePointer<termios>) -> Int32
    /// `tcsetattr(3)`: apply `termiosIn` to `fd` per `optAct`;
    /// 0 on success, -1 on failure.
    func tcsetattr(_ fd: Int32, _ optAct: Int32, _ termiosIn: UnsafePointer<termios>) -> Int32
    /// `ioctl(2)` with a `winsize` out-parameter (`TIOCGWINSZ`);
    /// 0 on success, -1 on failure.
    func ioctl(_ fd: Int32, _ request: UInt, _ winsizeOut: UnsafeMutablePointer<winsize>) -> Int32
}

/// The production ``PosixSyscalls``: delegates straight through to libc
/// with no overhead.
public struct RealPosixSyscalls: PosixSyscalls {
    /// Creates the pass-through implementation. Stateless.
    public init() {}

    public func tcgetattr(_ fd: Int32, _ termiosOut: UnsafeMutablePointer<termios>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.tcgetattr(fd, termiosOut)
        #elseif canImport(Glibc)
        return Glibc.tcgetattr(fd, termiosOut)
        #endif
    }

    public func tcsetattr(_ fd: Int32, _ optAct: Int32, _ termiosIn: UnsafePointer<termios>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.tcsetattr(fd, optAct, termiosIn)
        #elseif canImport(Glibc)
        return Glibc.tcsetattr(fd, optAct, termiosIn)
        #endif
    }

    public func ioctl(_ fd: Int32, _ request: UInt, _ winsizeOut: UnsafeMutablePointer<winsize>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.ioctl(fd, request, winsizeOut)
        #elseif canImport(Glibc)
        return Glibc.ioctl(fd, request, winsizeOut)
        #endif
    }
}

#if DEBUG
/// Test-only failing implementation. Records call counts, returns -1
/// on any flagged syscall, and can simulate the ioctl 0×0 fallback.
///
/// Fault-injection mock for ``PosixSyscalls``: a test flips the
/// `...ShouldFail` flags, hands the instance to the code under test, and
/// asserts on the `...CallCount` counters afterward. Unflagged calls
/// succeed with deterministic values (zeroed termios, 80x24 window) so a
/// test only ever exercises the failure it asked for. Debug builds only.
public final class FailingPosixSyscalls: PosixSyscalls, @unchecked Sendable {
    /// Make ``tcgetattr(_:_:)`` return -1 — simulates a non-TTY stdin.
    public var tcgetattrShouldFail: Bool = false
    /// Make ``tcsetattr(_:_:_:)`` return -1 — simulates raw mode failing to apply.
    public var tcsetattrShouldFail: Bool = false
    /// Make ``ioctl(_:_:_:)`` return -1 — simulates the size query failing outright.
    public var ioctlShouldFail: Bool = false
    /// Make ``ioctl(_:_:_:)`` succeed but report a 0x0 window — the
    /// headless-CI case the size-fallback path must survive.
    public var ioctlReturnsZeroSize: Bool = false

    /// Times ``tcgetattr(_:_:)`` was called — assert on it to pin retry/skip behavior.
    public var tcgetattrCallCount: Int = 0
    /// Times ``tcsetattr(_:_:_:)`` was called — assert on it to pin retry/skip behavior.
    public var tcsetattrCallCount: Int = 0
    /// Times ``ioctl(_:_:_:)`` was called — assert on it to pin retry/skip behavior.
    public var ioctlCallCount: Int = 0

    /// Creates a mock with every failure flag off and counters at zero.
    public init() {}

    public func tcgetattr(_ fd: Int32, _ termiosOut: UnsafeMutablePointer<termios>) -> Int32 {
        tcgetattrCallCount += 1
        if tcgetattrShouldFail { return -1 }
        // Zero out so the real flag-clearing logic in enableRawMode
        // operates on a deterministic input rather than uninitialized
        // memory.
        termiosOut.pointee = termios()
        return 0
    }

    public func tcsetattr(_ fd: Int32, _ optAct: Int32, _ termiosIn: UnsafePointer<termios>) -> Int32 {
        tcsetattrCallCount += 1
        if tcsetattrShouldFail { return -1 }
        return 0
    }

    public func ioctl(_ fd: Int32, _ request: UInt, _ winsizeOut: UnsafeMutablePointer<winsize>) -> Int32 {
        ioctlCallCount += 1
        if ioctlShouldFail { return -1 }
        if ioctlReturnsZeroSize {
            winsizeOut.pointee = winsize()
            return 0
        }
        // Default success path returns a non-zero size so the caller
        // gets a usable answer if a test forgets to flag a failure mode.
        var ws = winsize()
        ws.ws_col = 80
        ws.ws_row = 24
        winsizeOut.pointee = ws
        return 0
    }
}
#endif

// MARK: - Terminal Control

/// Static control surface for the physical terminal: raw mode,
/// alternate screen, mouse tracking, bracketed paste, size queries, and
/// crash-path cleanup.
///
/// This is the pipeline's boundary with the outside world. Everything
/// above it (graph, renderer, compositor) works on in-memory cells;
/// `Terminal` owns the stateful device modes those frames assume —
/// `TerminalApp.run()` enables them at startup, and
/// `installSignalCleanup()` guarantees they are unwound on any exit
/// path, because a terminal left in raw mode + mouse tracking corrupts
/// the user's shell. A namespace enum (no instances): a process has one
/// controlling terminal, and the mode changes are process-global
/// termios/escape-sequence state. All sequences are xterm/DEC private
/// modes that unsupporting terminals ignore silently.
public enum Terminal {
    nonisolated(unsafe) private static var originalTermios: termios?

    /// POSIX syscall implementation used by `enableRawMode`, `disableRawMode`,
    /// and `size`. Production builds default to `RealPosixSyscalls`; tests
    /// swap in a `FailingPosixSyscalls` to drive failure modes that the
    /// real test runner can't reach (because the runner is a TTY).
    nonisolated(unsafe) public static var posix: any PosixSyscalls = RealPosixSyscalls()

    #if DEBUG
    /// Debug-only geometry override consulted by ``size()`` when ioctl
    /// reports 0×0 columns or rows — lets headless tests pin a specific
    /// simulated size instead of the VT100 fallback. Set to `nil` to
    /// exercise the release fallback path. Compiled out of release
    /// builds.
    nonisolated(unsafe) public static var debugMinSize: TerminalSize? = .default
    #endif

    /// Current terminal dimensions in cells, via `ioctl(TIOCGWINSZ)` on
    /// stdout. Falls back to ``TerminalSize/default`` (80×24) when the
    /// query fails or reports zero — piped stdout, headless CI — so
    /// callers always get a renderable, non-zero geometry. Re-queried
    /// after SIGWINCH (see `checkResize()`).
    public static func size() -> TerminalSize {
        var windowSize = winsize()
        let ioctlResult = posix.ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize)
        var size = TerminalSize(cols: Int(windowSize.ws_col), rows: Int(windowSize.ws_row))

        // in release builds, ioctl can fail (stdout piped, headless
        // CI without a TTY) or report `0×0` (some shell harnesses, broken
        // terminal emulators). Falling back to the VT100 default keeps the
        // renderer from dividing by zero or producing a zero-cell buffer
        // that the compositor can't diff. DEBUG path retains the override
        // hook for tests that want a specific simulated geometry.
        #if DEBUG
        if let minSize = debugMinSize, size.cols == 0 || size.rows == 0 {
            size = minSize
        }
        #endif
        if ioctlResult != 0 || size.cols == 0 || size.rows == 0 {
            size = .default
        }

        return size
    }

    /// Switch stdin to raw mode for character-at-a-time input.
    ///
    /// Disables:
    /// - ECHO, ICANON: line buffering and echo (we render our own output)
    /// - ISIG: Ctrl+C/Z signal generation (we handle these as key events)
    /// - IEXTEN: implementation-defined input processing
    /// - IXON: Ctrl+S/Q flow control (we need these keys for shortcuts)
    /// - ICRNL: CR→NL translation (we need raw Enter = 0x0D)
    /// - BRKINT, INPCK, ISTRIP: legacy serial line flags (no-op on modern systems, belt-and-suspenders)
    /// - OPOST: output post-processing (we emit raw ANSI, no translation)
    ///
    /// Sets VMIN=0, VTIME=1 (100ms timeout): read() returns immediately with available bytes
    /// or after 100ms with nothing. This gives the event loop a natural polling interval
    /// without busy-waiting.
    ///
    /// Returns `true` on success, `false` if the underlying syscalls fail
    /// (e.g. stdin is not a TTY). On failure no termios state is captured,
    /// so `disableRawMode()` is a no-op — the caller is left in cooked mode.
    /// previously this discarded both syscall returns silently,
    /// leaving callers unable to distinguish "raw mode active" from "no-op
    /// because stdin is a pipe."
    @discardableResult
    public static func enableRawMode() -> Bool {
        var raw = termios()
        if posix.tcgetattr(STDIN_FILENO, &raw) != 0 {
            return false
        }
        originalTermios = raw
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~tcflag_t(OPOST)
        // c_cc tuple layout: index 0 = VMIN, index 1 = VTIME
        // This is a POSIX ABI assumption shared by Darwin and Glibc.
        raw.c_cc.0 = 0
        raw.c_cc.1 = 1
        if posix.tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0 {
            // Restore captured termios so the caller can still call
            // disableRawMode() defensively, even though we never made it
            // into raw mode.
            return false
        }
        return true
    }

    /// Restore the termios state captured by `enableRawMode()`,
    /// returning stdin to cooked (line-buffered, echoing) mode. A no-op
    /// if raw mode was never successfully enabled — safe to call
    /// defensively on any shutdown path.
    public static func disableRawMode() {
        if var original = originalTermios {
            _ = posix.tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    /// Switch to the alternate screen buffer (DEC 1049) and hide the
    /// cursor. The shell's scrollback is saved untouched underneath;
    /// ``exitAlternateScreen()`` restores it exactly — the standard
    /// full-screen TUI convention.
    public static func enterAlternateScreen() {
        // alternateScreen on + cursorVisible off
        writeRaw("\u{1B}[?1049h\u{1B}[?25l")
    }

    /// Leave the alternate screen, restoring the user's shell content
    /// and cursor. Also force-disables mouse tracking both before and
    /// after the switch — Apple Terminal keeps per-screen mouse state,
    /// so a single disable would be undone by the screen restore and
    /// leave the shell spewing SGR mouse bytes.
    public static func exitAlternateScreen() {
        // HYP-342 — disable mouse modes BOTH before AND after the
        // alt-screen exit. Apple Terminal.app saves/restores per-
        // screen state on ?1049l: a disable issued only in the alt
        // screen is reverted when the main screen is restored, so
        // moving the mouse over the shell prints raw SGR 1006 byte
        // streams. Re-issuing the disable after ?1049l ensures the
        // user's main-screen state has mouse tracking off.
        //
        // The pre-exit disable still matters: it prevents in-flight
        // mouse events from being reported during the brief window
        // between alt-exit and the second disable, which is the
        // corruption pattern HYP-324 documented.
        disableMouseTracking()
        // cursorVisible on + alternateScreen off
        writeRaw("\u{1B}[?25h\u{1B}[?1049l")
        disableMouseTracking()
    }

    /// Enable SGR 1006 extended mouse protocol — supports click, drag, move, scroll.
    /// Enables four progressive tracking modes (must be disabled in reverse order).
    public static func enableMouseTracking() {
        let sequence = enableMode(ANSIMode.mouseBasic)
            + enableMode(ANSIMode.mouseDrag)
            + enableMode(ANSIMode.mouseMotion)
            + enableMode(ANSIMode.mouseSGR)
        write(sequence)
    }

    /// Disable all four mouse tracking modes, in the reverse of the
    /// order `enableMouseTracking()` enabled them. Idempotent — issued
    /// liberally on every shutdown path, since stray mouse reporting is
    /// the classic way a crashed TUI corrupts the shell.
    public static func disableMouseTracking() {
        let sequence = disableMode(ANSIMode.mouseSGR)
            + disableMode(ANSIMode.mouseMotion)
            + disableMode(ANSIMode.mouseDrag)
            + disableMode(ANSIMode.mouseBasic)
        write(sequence)
    }

    /// Enable xterm bracketed-paste mode. The terminal will wrap any
    /// pasted content in `ESC[200~ ... ESC[201~`, which the InputParser
    /// converts into a single `TerminalEvent.paste(String)`. Without
    /// this, paste content arrives byte-by-byte indistinguishable from
    /// fast typed input. Idempotent — calling twice is harmless.
    public static func enableBracketedPaste() {
        write(enableMode(ANSIMode.bracketedPaste))
    }

    /// Turn off bracketed-paste mode (xterm 2004) so pasted text is no
    /// longer wrapped in `ESC[200~ … ESC[201~` markers. Part of the
    /// standard shutdown sequence; idempotent.
    public static func disableBracketedPaste() {
        write(disableMode(ANSIMode.bracketedPaste))
    }

    /// Bypass Swift's buffered print — writes raw bytes to stdout via POSIX write().
    public static func write(_ string: String) {
        var mutableString = string
        mutableString.withUTF8 { buffer in
            var written = 0
            while written < buffer.count {
                let bytesWritten = posixWrite(STDOUT_FILENO, buffer.baseAddress! + written, buffer.count - written)
                if bytesWritten <= 0 { break }
                written += bytesWritten
            }
        }
    }

    /// StaticString variant — compile-time known content, zero heap allocation.
    static func writeRaw(_ staticString: StaticString) {
        staticString.withUTF8Buffer { buffer in
            var written = 0
            while written < buffer.count {
                let bytesWritten = posixWrite(STDOUT_FILENO, buffer.baseAddress! + written, buffer.count - written)
                if bytesWritten <= 0 { break }
                written += bytesWritten
            }
        }
    }

    /// Signal handler writes only an atomic bool — no Swift allocation or ARC in signal context.
    public static func installResizeHandler() {
        signal(SIGWINCH) { _ in
            _resizeFlag.store(true, ordering: .relaxed)
        }
    }

    // MARK: - Crash-path cleanup (HYP-324)

    /// Concatenated DEC private-mode disable sequence covering every
    /// state TerminalApp.run() enables. Precomputed at file scope so
    /// the signal handler doesn't allocate or call the Swift runtime
    /// (async-signal-safe constraint).
    ///
    /// Ordering matters: the four mouse modes (1006/1003/1002/1000)
    /// disable FIRST so any in-flight mouse events stop being
    /// reported BEFORE the alternate screen is exited and the user's
    /// shell becomes visible again. Disabling alt-screen first would
    /// briefly leave the shell rendering SGR 1006 coordinate strings
    /// before mouse mode is off — that's the corruption pattern that
    /// triggered HYP-324.
    public static let cleanupEscapeSequence: String =
        "\u{1B}[?1006l" +    // SGR 1006 mouse extended-coordinates off
        "\u{1B}[?1003l" +    // mouse motion (any-event) off
        "\u{1B}[?1002l" +    // mouse drag off
        "\u{1B}[?1000l" +    // mouse basic click tracking off
        "\u{1B}[?2004l" +    // bracketed-paste off
        "\u{1B}[?25h"   +    // cursor visible
        "\u{1B}[?1049l" +    // alt-screen exit
        // HYP-342 — re-issue mouse-off in main-screen context. Apple
        // Terminal.app restores per-screen mouse state on ?1049l, so
        // the pre-alt-exit disable doesn't stick. Repeat after the
        // alt-screen exit so the shell-side state is mouse-off too.
        "\u{1B}[?1006l" +
        "\u{1B}[?1003l" +
        "\u{1B}[?1002l" +
        "\u{1B}[?1000l"

    /// Emit the cleanup sequence + restore termios using ONLY async-
    /// signal-safe syscalls (posix_write + tcsetattr per POSIX.1).
    ///
    /// Called from three paths:
    ///   1. Signal handler installed by `installSignalCleanup()`.
    ///   2. `atexit` hook for direct `exit()` calls.
    ///   3. The normal `defer` block in TerminalApp.run() (idempotent
    ///      — a second cleanup is a no-op against an already-restored
    ///      terminal).
    ///
    /// No Swift heap allocations. No ARC traffic. The escape sequence
    /// is materialised once at file-scope `cleanupEscapeSequence`;
    /// `withCString` reuses that storage without allocating.
    public static func runCleanup() {
        cleanupEscapeSequence.withCString { ptr in
            // strlen is async-signal-safe.
            let len = strlen(ptr)
            _ = posixWrite(STDOUT_FILENO, ptr, len)
        }
        // Restore termios from the cached value taken before raw mode.
        // tcsetattr is on the POSIX list of async-signal-safe functions.
        if var orig = originalTermios {
            #if canImport(Darwin)
            _ = Darwin.tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
            #elseif canImport(Glibc)
            _ = Glibc.tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
            #endif
        }
    }

    /// Install signal handlers that disable mouse / alt-screen / raw
    /// mode + restore termios on SIGINT, SIGTERM, SIGHUP. Each handler
    /// re-raises the signal with the default disposition so the
    /// parent shell observes the correct exit code.
    ///
    /// The fatal signals — SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP,
    /// SIGABRT — get the same cleanup, then go back to the handler they had
    /// before, so a crash still reaches the Swift backtracer, now printed on
    /// a restored screen.
    ///
    /// Also registers an `atexit` hook so direct `exit()` calls run
    /// the same cleanup. SIGKILL cannot be intercepted by design;
    /// document recovery via `printf '\x1b[?1006l...\x1b[?1049l'` in
    /// the troubleshooting guide.
    ///
    /// Safe to call multiple times — each call replaces any prior
    /// handler with the cleanup-then-default-action shape.
    public static func installSignalCleanup() {
        // The handlers are declared at file scope (see below) — Swift
        // forbids C-function-pointer formation from any closure that
        // captures Self / context, even via static-function calls.
        // File-scope free functions sidestep that.
        #if canImport(Darwin)
        _ = Darwin.signal(SIGINT, _terminalSignalHandler)
        _ = Darwin.signal(SIGTERM, _terminalSignalHandler)
        _ = Darwin.signal(SIGHUP, _terminalSignalHandler)
        #elseif canImport(Glibc)
        _ = Glibc.signal(SIGINT, _terminalSignalHandler)
        _ = Glibc.signal(SIGTERM, _terminalSignalHandler)
        _ = Glibc.signal(SIGHUP, _terminalSignalHandler)
        #endif
        // A static `let` is initialised on first use, which allocates — the
        // handler must find the sequence already built, not build it.
        _ = cleanupEscapeSequence.utf8.count
        let firstInstall = !fatalHandlersInstalled.exchange(true, ordering: .acquiringAndReleasing)
        for (index, signum) in fatalSignals.enumerated() where firstInstall {
            // Read the whole previous action, not just its handler: the
            // backtracer installs with SA_SIGINFO, and `signal()` would hand
            // back a pointer to be called with the wrong arguments.
            _ = sigaction(signum, nil, previousFatalActions + index)
            #if canImport(Darwin)
            _ = Darwin.signal(signum, _terminalFatalSignalHandler)
            #elseif canImport(Glibc)
            _ = Glibc.signal(signum, _terminalFatalSignalHandler)
            #endif
        }
        atexit(_terminalAtExitHandler)
    }

    /// Atomically check and clear the resize flag. Single exchange — no TOCTOU.
    public static func checkResize() -> Bool {
        _resizeFlag.exchange(false, ordering: .relaxed)
    }
}
