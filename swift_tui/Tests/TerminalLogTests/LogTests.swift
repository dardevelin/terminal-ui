import Testing
import Foundation
@testable import TerminalLog
@testable import TerminalInk

// HYP-58 — TerminalLog. Structured logging that piggybacks on
// TerminalInk for styled output. Six levels (trace/debug/info/warn/
// error/critical), per-scope logger, env-var-driven min-level
// filter, console + file sinks, automatic ANSI stripping for
// non-TTY targets.
//
// Test injection seam: `Log` writes through a `[any LogSink]`
// configured at construction time. Tests use a `MemorySink` that
// captures emitted entries so we can pin the format and routing
// without touching real stdout/stderr/files.

@Suite("LogLevel — six cases, comparable")
struct LogLevelTests {

    @Test("six levels in canonical order")
    func sixCases() {
        // Comparable: lower = noisier. .trace < .debug < .info <
        // .warn < .error < .critical. Min-level filtering relies on
        // this ordering.
        #expect(LogLevel.trace < LogLevel.debug)
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warn)
        #expect(LogLevel.warn < LogLevel.error)
        #expect(LogLevel.error < LogLevel.critical)
    }

    @Test("each level has a stable label string")
    func labels() {
        // Labels match the SwiftLog / structlog conventions in
        // upper-case so log lines grep cleanly.
        #expect(LogLevel.trace.label == "TRACE")
        #expect(LogLevel.debug.label == "DEBUG")
        #expect(LogLevel.info.label == "INFO")
        #expect(LogLevel.warn.label == "WARN")
        #expect(LogLevel.error.label == "ERROR")
        #expect(LogLevel.critical.label == "CRITICAL")
    }

    @Test("each level has a distinct color")
    func colors() {
        let colors: [InkColor] = LogLevel.allCases.map(\.color)
        #expect(Set(colors).count >= 5,
                "levels should map to mostly-distinct colors; got \(colors)")
    }

    @Test("warn and above route to stderr; below routes to stdout")
    func streamRouting() {
        #expect(LogLevel.trace.stream == .stdout)
        #expect(LogLevel.debug.stream == .stdout)
        #expect(LogLevel.info.stream == .stdout)
        #expect(LogLevel.warn.stream == .stderr)
        #expect(LogLevel.error.stream == .stderr)
        #expect(LogLevel.critical.stream == .stderr)
    }
}

@Suite("Log — emission + scope + format")
struct LogEmissionTests {

    @Test("info emits one entry through all sinks")
    func infoEmits() {
        let sink = MemorySink()
        let log = Log(scope: "test", sinks: [sink], minLevel: .trace)
        log.info("hello")
        #expect(sink.entries.count == 1)
        let entry = sink.entries[0]
        #expect(entry.scope == "test")
        #expect(entry.level == .info)
        #expect(entry.message == "hello")
    }

    @Test("rendered console output contains scope, label, and message")
    func renderedFormat() {
        let sink = MemorySink()
        let log = Log(scope: "swtui", sinks: [sink], minLevel: .trace)
        log.warn("config not found")
        let rendered = sink.entries[0].rendered(capability: .none)
        // Format contract per HYP-58 body: `[scope] LEVEL: message`.
        // Strip-ANSI form (capability=.none) is the canonical assertable
        // shape — no SGR overhead.
        #expect(rendered.contains("[swtui]"),
                "rendered line must include bracketed scope; got \(rendered.debugDescription)")
        #expect(rendered.contains("WARN"),
                "rendered line must include level label; got \(rendered.debugDescription)")
        #expect(rendered.contains("config not found"))
    }
}

@Suite("Log — minLevel filtering")
struct LogMinLevelTests {

    @Test("messages below minLevel are dropped")
    func dropsBelow() {
        let sink = MemorySink()
        let log = Log(scope: "x", sinks: [sink], minLevel: .warn)
        log.trace("a")
        log.debug("b")
        log.info("c")
        log.warn("d")
        log.error("e")
        log.critical("f")
        #expect(sink.entries.count == 3,
                "only warn/error/critical should pass with minLevel=.warn; got \(sink.entries.count)")
    }

    @Test("LOG_LEVEL env var overrides defaults via Log.detectMinLevel(env:)")
    func envOverride() {
        // Pure function — easy to test. Real `Log.init` calls this
        // when `minLevel` defaults to nil.
        #expect(Log.detectMinLevel(env: ["LOG_LEVEL": "warn"]) == .warn)
        #expect(Log.detectMinLevel(env: ["LOG_LEVEL": "DEBUG"]) == .debug)
        #expect(Log.detectMinLevel(env: ["LOG_LEVEL": "garbage"]) == .info)
        #expect(Log.detectMinLevel(env: [:]) == .info,
                "default min level when LOG_LEVEL absent must be .info")
    }
}

@Suite("LogSink — file sink strips ANSI")
struct LogSinkFileTests {

    @Test("FileSink writes plain text — capability=.none")
    func fileStripsANSI() throws {
        // Write to a temp file, then read it back and verify no ESC.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminallog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sink = try FileSink(url: tmp)
        let log = Log(scope: "fs", sinks: [sink], minLevel: .trace)
        log.error("boom")
        sink.flush()
        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(!contents.contains("\u{1B}["),
                "FileSink output must contain no ANSI escape; got \(contents.debugDescription)")
        #expect(contents.contains("ERROR"))
        #expect(contents.contains("boom"))
    }
}

// MARK: - Test sink

/// In-memory sink that captures emitted entries verbatim. Used by
/// the suite to assert format + routing without writing to real
/// streams.
final class MemorySink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [LogEntry] = []

    func receive(_ entry: LogEntry) {
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }

    var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }
}
