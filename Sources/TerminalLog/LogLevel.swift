import TerminalInk

// log level enum + per-level color/stream mapping.
//
// Six levels, ordered noisy-to-fatal so
// `LogLevel.warn < .error` resolves correctly for min-level filters.
// Each level carries:
//
//   - `label`   : upper-case grep-friendly tag in rendered output.
//   - `color`   : InkColor used by the ConsoleSink to tint the label.
//   - `stream`  : stdout for trace/debug/info, stderr for warn/error/
//                 critical — matches Unix convention for diagnostics
//                 (`grep ERROR` works without piping stderr).

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug
    case info
    case warn
    case error
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Upper-case label for the rendered prefix `[scope] LABEL: msg`.
    /// Keep stable — log consumers grep against these strings.
    public var label: String {
        switch self {
        case .trace:    return "TRACE"
        case .debug:    return "DEBUG"
        case .info:     return "INFO"
        case .warn:     return "WARN"
        case .error:    return "ERROR"
        case .critical: return "CRITICAL"
        }
    }

    /// Color used to tint the level label when rendering to a
    /// color-capable terminal. `.critical` adds `.bold` via the
    /// renderer; the color itself stays red so a single grep can
    /// still find both error and critical lines.
    public var color: InkColor {
        switch self {
        case .trace:    return .muted          // dim — internal
        case .debug:    return .named(.cyan)
        case .info:     return .success        // green
        case .warn:     return .warning        // yellow
        case .error:    return .error          // bright red
        case .critical: return .error          // bright red (bold added at render)
        }
    }

    /// Output stream — stderr for warn/error/critical so log lines
    /// surface even when stdout is captured to a file.
    public var stream: InkStream {
        switch self {
        case .trace, .debug, .info: return .stdout
        case .warn, .error, .critical: return .stderr
        }
    }
}
