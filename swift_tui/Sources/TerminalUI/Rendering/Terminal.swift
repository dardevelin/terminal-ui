#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import Synchronization

/// Platform-agnostic POSIX write — avoids ambiguity with Swift instance methods.
@inline(__always)
internal func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buf, count)
    #elseif canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #endif
}

/// Atomic flag set by SIGWINCH handler, polled by resize task.
/// Using Atomic<Bool> ensures signal-safety and eliminates TOCTOU races.
private let _resizeFlag = Atomic<Bool>(false)

public struct TerminalSize: Sendable {
    public var cols: Int
    public var rows: Int
}

public enum Terminal {
    nonisolated(unsafe) private static var originalTermios: termios?

    /// Minimum size for debug traces — prevents 0x0 captures
    #if DEBUG
    nonisolated(unsafe) public static var debugMinSize: TerminalSize? = TerminalSize(cols: 80, rows: 24)
    #endif

    public static func size() -> TerminalSize {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        var size = TerminalSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))

        #if DEBUG
        // In debug, enforce minimum size so traces are useful
        if let minSize = debugMinSize, size.cols == 0 || size.rows == 0 {
            size = minSize
        }
        #endif

        return size
    }

    public static func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cc.0 = 0  // VMIN
        raw.c_cc.1 = 1  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    public static func disableRawMode() {
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    public static func enterAlternateScreen() {
        writeRaw("\u{1B}[?1049h\u{1B}[?25l")
    }

    public static func exitAlternateScreen() {
        disableMouseTracking()
        writeRaw("\u{1B}[?25h\u{1B}[?1049l")
    }

    /// Enable SGR 1006 extended mouse protocol — click, drag, move, scroll.
    public static func enableMouseTracking() {
        // 1000: basic mouse tracking
        // 1002: button event tracking (drag)
        // 1003: any event tracking (mouse move)
        // 1006: SGR extended format (for coordinates > 223)
        writeRaw("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h")
    }

    /// Disable mouse tracking.
    public static func disableMouseTracking() {
        writeRaw("\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l")
    }

    /// Write a string directly to stdout fd — bypasses Swift print/buffering
    public static func write(_ string: String) {
        var s = string
        s.withUTF8 { buf in
            var written = 0
            while written < buf.count {
                let n = posixWrite(STDOUT_FILENO, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// Write a static string — known at compile time, no allocation
    static func writeRaw(_ s: StaticString) {
        s.withUTF8Buffer { buf in
            var written = 0
            while written < buf.count {
                let n = posixWrite(STDOUT_FILENO, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// Install the SIGWINCH handler. Sets an atomic flag — no Swift closure
    /// in the signal handler (async-signal-safe).
    public static func installResizeHandler() {
        signal(SIGWINCH) { _ in
            _resizeFlag.store(true, ordering: .relaxed)
        }
    }

    /// Atomically check and clear the resize flag. Returns true if a resize
    /// occurred since the last check. No TOCTOU — single atomic exchange.
    public static func checkResize() -> Bool {
        _resizeFlag.exchange(false, ordering: .relaxed)
    }
}
