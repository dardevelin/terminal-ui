#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct TerminalSize: Sendable {
    public var cols: Int
    public var rows: Int
}

public enum Terminal {
    nonisolated(unsafe) private static var originalTermios: termios?

    public static func size() -> TerminalSize {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        return TerminalSize(cols: Int(ws.ws_col), rows: Int(ws.ws_row))
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
        writeRaw("\u{1B}[?25h\u{1B}[?1049l")
    }

    /// Write a string directly to stdout fd — bypasses Swift print/buffering
    public static func write(_ string: String) {
        var s = string
        s.withUTF8 { buf in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + written, buf.count - written)
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
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    public static func installResizeHandler(_ handler: @escaping () -> Void) {
        _resizeCallback = handler
        signal(SIGWINCH, _sigwinchHandler)
    }
}

nonisolated(unsafe) private var _resizeCallback: (() -> Void)?

private func _sigwinchHandler(_: Int32) {
    _resizeCallback?()
}
