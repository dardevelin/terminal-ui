import Foundation
import TerminalInk

// structured logger.
//
//   let log = Log("swtui")
//   log.info("Config loaded from \(path)")        // → stdout, [swtui] INFO: ... (green)
//   log.warn("Socket already in use at \(addr)")   // → stderr, [swtui] WARN: ... (yellow)
//   log.error("Cannot read \(file): \(err)")       // → stderr, [swtui] ERROR: ... (red)
//
// Structure:
//
//   - `Log` is a value type holding (scope, sinks, minLevel).
//     Copying a logger is cheap; passing to subsystems is fine.
//   - Default sinks = [ConsoleSink()] resolved once at init.
//   - Default minLevel = `Log.detectMinLevel(env:)` which reads
//     LOG_LEVEL from the process environment, falling back to .info.
//   - Per-call message uses `@autoclosure` so the string isn't built
//     when the level is filtered — common Swift logger pattern.
//
// Min-level filtering happens BEFORE the message closure runs, so
// `log.trace("expensive: \(slowDescription())")` costs nothing at
// runtime when min-level is .info or higher.

public struct Log: Sendable {
    public let scope: String
    public let sinks: [any LogSink]
    public let minLevel: LogLevel

    /// Full-featured initializer. `minLevel` defaults to whatever
    /// `detectMinLevel(env:)` reads from `ProcessInfo.environment`;
    /// pass an explicit value to override.
    public init(scope: String,
                sinks: [any LogSink]? = nil,
                minLevel: LogLevel? = nil) {
        self.scope = scope
        self.sinks = sinks ?? [ConsoleSink()]
        self.minLevel = minLevel
            ?? Log.detectMinLevel(env: ProcessInfo.processInfo.environment)
    }

    /// Single-string convenience: `Log("swtui")`.
    public init(_ scope: String) {
        self.init(scope: scope)
    }

    // MARK: - Per-level helpers
    //
    // Each helper takes an autoclosure so callers don't pay for
    // string interpolation when the level is filtered out. File/line
    // are captured for future structured-output sinks (the canonical
    // text form doesn't include them today — keeps lines readable).

    public func trace(_ message: @autoclosure () -> String,
                      file: String = #file, line: Int = #line) {
        emit(.trace, message(), file: file, line: line)
    }

    public func debug(_ message: @autoclosure () -> String,
                      file: String = #file, line: Int = #line) {
        emit(.debug, message(), file: file, line: line)
    }

    public func info(_ message: @autoclosure () -> String,
                     file: String = #file, line: Int = #line) {
        emit(.info, message(), file: file, line: line)
    }

    public func warn(_ message: @autoclosure () -> String,
                     file: String = #file, line: Int = #line) {
        emit(.warn, message(), file: file, line: line)
    }

    public func error(_ message: @autoclosure () -> String,
                      file: String = #file, line: Int = #line) {
        emit(.error, message(), file: file, line: line)
    }

    public func critical(_ message: @autoclosure () -> String,
                         file: String = #file, line: Int = #line) {
        emit(.critical, message(), file: file, line: line)
    }

    // MARK: - Internals

    private func emit(_ level: LogLevel, _ message: String, file: String, line: Int) {
        guard level >= minLevel else { return }
        let entry = LogEntry(scope: scope, level: level, message: message)
        for sink in sinks {
            sink.receive(entry)
        }
    }

    // MARK: - Min-level resolution

    /// Pure parser for `LOG_LEVEL`. Accepts any case (`debug`,
    /// `DEBUG`, `Debug`); unrecognized values fall back to `.info`
    /// rather than throwing — log config shouldn't crash the app.
    /// Absent → `.info`.
    public static func detectMinLevel(env: [String: String]) -> LogLevel {
        guard let raw = env["LOG_LEVEL"] else { return .info }
        switch raw.lowercased() {
        case "trace":    return .trace
        case "debug":    return .debug
        case "info":     return .info
        case "warn", "warning": return .warn
        case "error":    return .error
        case "critical", "fatal": return .critical
        default:         return .info
        }
    }
}
