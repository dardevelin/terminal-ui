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

/// Atomic flag set by SIGWINCH handler, polled by resize task.
/// Atomic<Bool> is async-signal-safe and eliminates TOCTOU races
/// between the signal handler (any thread) and the main loop polling.
private let _resizeFlag = Atomic<Bool>(false)

// MARK: - Terminal Size

private let vt100DefaultCols = 80
private let vt100DefaultRows = 24

public struct TerminalSize: Sendable {
    public var cols: Int
    public var rows: Int

    /// VT100 default (80x24) — fallback when ioctl(TIOCGWINSZ) fails
    /// (e.g. stdout is piped, not a TTY, or running in CI).
    public static let `default` = TerminalSize(cols: vt100DefaultCols, rows: vt100DefaultRows)
}

// MARK: - Terminal Control

public enum Terminal {
    nonisolated(unsafe) private static var originalTermios: termios?

    #if DEBUG
    nonisolated(unsafe) public static var debugMinSize: TerminalSize? = .default
    #endif

    public static func size() -> TerminalSize {
        var windowSize = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize)
        var size = TerminalSize(cols: Int(windowSize.ws_col), rows: Int(windowSize.ws_row))

        #if DEBUG
        if let minSize = debugMinSize, size.cols == 0 || size.rows == 0 {
            size = minSize
        }
        #endif

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
    public static func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~tcflag_t(OPOST)
        // c_cc tuple layout: index 0 = VMIN, index 1 = VTIME
        // This is a POSIX ABI assumption shared by Darwin and Glibc.
        raw.c_cc.0 = 0
        raw.c_cc.1 = 1
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    public static func disableRawMode() {
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    public static func enterAlternateScreen() {
        // alternateScreen on + cursorVisible off
        writeRaw("\u{1B}[?1049h\u{1B}[?25l")
    }

    public static func exitAlternateScreen() {
        disableMouseTracking()
        // cursorVisible on + alternateScreen off
        writeRaw("\u{1B}[?25h\u{1B}[?1049l")
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

    public static func disableMouseTracking() {
        let sequence = disableMode(ANSIMode.mouseSGR)
            + disableMode(ANSIMode.mouseMotion)
            + disableMode(ANSIMode.mouseDrag)
            + disableMode(ANSIMode.mouseBasic)
        write(sequence)
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

    /// Atomically check and clear the resize flag. Single exchange — no TOCTOU.
    public static func checkResize() -> Bool {
        _resizeFlag.exchange(false, ordering: .relaxed)
    }
}
