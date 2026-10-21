import Foundation
import Synchronization
import TerminalInk

// sinks for log output.
//
// `LogEntry` is the structured record passed to every sink: scope,
// level, message, plus a `rendered(capability:)` helper that emits
// the canonical `[scope] LEVEL: message` form (with optional ANSI).
//
// Two built-in sinks:
//
//   - `ConsoleSink` writes to stdout (info/below) or stderr
//     (warn/above), capability auto-detected via TerminalInk so
//     `NO_COLOR=1` and piped output strip ANSI for free.
//   - `FileSink` writes plain text to a file URL — capability is
//     forced to `.none` so the file never contains escape sequences,
//     even when the process is otherwise writing color to a TTY.
//
// Custom sinks (network, JSON-line, structured-log shipper) implement
// `LogSink` directly — single `receive(_:)` method, all the rendering
// machinery is on `LogEntry`.

/// One emitted log line. Sinks decide whether/how to render and where
/// to write. The `rendered(capability:)` helper is the canonical
/// console form so most sinks just call it.
public struct LogEntry: Sendable {
    public let scope: String
    public let level: LogLevel
    public let message: String

    public init(scope: String, level: LogLevel, message: String) {
        self.scope = scope
        self.level = level
        self.message = message
    }

    /// Build the canonical `[scope] LEVEL: message` line. The level
    /// label is colored via TerminalInk; `.critical` also gets bold.
    /// `capability == .none` strips all ANSI — the FileSink form.
    public func rendered(capability: ColorCapability) -> String {
        var styled = StyledString("[\(scope)] ").muted
        var label = level.label.styled(level.color)
        if level == .critical {
            label = label.traits(.bold)
        }
        styled = styled + label + StyledString(": \(message)")
        return styled.render(capability: capability)
    }
}

/// Output target for a `Log`. The same entry can fan out to multiple
/// sinks — typical setup: ConsoleSink + FileSink.
public protocol LogSink: Sendable {
    func receive(_ entry: LogEntry)
}

/// Stdout/stderr writer. Routes by `entry.level.stream`. Capability
/// is detected once at construction; reset to `.detectFromProcess()`
/// per write would be wasteful and detection isn't free.
public final class ConsoleSink: LogSink, Sendable {
    private let capability: ColorCapability

    public init(capability: ColorCapability? = nil) {
        self.capability = capability ?? ColorCapability.detectFromProcess()
    }

    public func receive(_ entry: LogEntry) {
        let line = entry.rendered(capability: capability) + "\n"
        if let data = line.data(using: .utf8) {
            entry.level.stream.fileHandle.write(data)
        }
    }
}

/// Plain-text file writer. Capability is forced to `.none` — the
/// file never accumulates ANSI escapes regardless of where the
/// process is otherwise writing color.
public final class FileSink: LogSink, Sendable {
    /// Held under a lock so two threads logging at once cannot interleave
    /// their bytes in the file.
    private let handle: Mutex<FileHandle>

    public init(url: URL) throws {
        // Create the file if it doesn't exist; otherwise open for append.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Discarding the result would surface a creation failure as an
            // opaque FileHandle error on the next line instead of naming the
            // path that could not be created. On Linux the unused result is
            // additionally a diagnostic, which the warnings-as-errors gate
            // treats as a build failure.
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        // Append mode — seek to end so concurrent process restarts
        // don't truncate prior contents.
        try handle.seekToEnd()
        self.handle = Mutex(handle)
    }

    deinit {
        handle.withLock { try? $0.close() }
    }

    public func receive(_ entry: LogEntry) {
        let line = entry.rendered(capability: .none) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        handle.withLock { $0.write(data) }
    }

    /// Force the OS write buffer to disk. Useful before reading the
    /// file back in tests or after a critical message.
    public func flush() {
        handle.withLock { try? $0.synchronize() }
    }
}

