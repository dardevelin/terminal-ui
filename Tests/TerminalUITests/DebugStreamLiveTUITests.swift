#if DEBUG
import Testing
import Foundation
@testable import TerminalUI

// `DebugStream.emitWarning` must not corrupt the live TUI:
//   1. While `setLiveTUI(true)` is set, no fallback writes to stderr.
//   2. Identical `(code, nodeID, message)` pairs dedupe per session
//      so a misbehaving node doesn't flood thousands of warnings.

private final class CapturingSink: DebugSink, @unchecked Sendable {
    nonisolated(unsafe) var events: [DebugEvent] = []
    func receive(_ event: DebugEvent) {
        events.append(event)
    }
}

@Suite("DebugStream — warning flood guards (live-TUI + dedupe)")
@MainActor
struct DebugStreamLiveTUITests {

    @Test("Identical (code, nodeID, message) pairs dedupe per session")
    func dedupeRepeatedWarnings() {
        DebugStream.shared.resetWarningDedup()
        DebugStream.shared.removeAllSinks()
        let sink = CapturingSink()
        DebugStream.shared.addSink(sink)
        defer {
            DebugStream.shared.removeAllSinks()
            DebugStream.shared.resetWarningDedup()
        }

        for _ in 0..<10 {
            DebugStream.shared.emitWarning(
                .componentOverflow,
                message: "node X wrote 5 cells outside its rect",
                nodeID: "0.1.2"
            )
        }
        let warnings = sink.events.compactMap { event -> FrameworkWarningInfo? in
            if case .frameworkWarning(let info) = event { return info }
            return nil
        }
        #expect(warnings.count == 1,
                "10 identical emits should dedupe to a single warning; got \(warnings.count)")
    }

    @Test("Distinct nodeIDs do NOT dedupe")
    func distinctNodesNotDeduped() {
        DebugStream.shared.resetWarningDedup()
        DebugStream.shared.removeAllSinks()
        let sink = CapturingSink()
        DebugStream.shared.addSink(sink)
        defer {
            DebugStream.shared.removeAllSinks()
            DebugStream.shared.resetWarningDedup()
        }

        DebugStream.shared.emitWarning(.componentOverflow, message: "a", nodeID: "node-1")
        DebugStream.shared.emitWarning(.componentOverflow, message: "a", nodeID: "node-2")
        DebugStream.shared.emitWarning(.componentOverflow, message: "a", nodeID: "node-3")
        let warnings = sink.events.compactMap { event -> FrameworkWarningInfo? in
            if case .frameworkWarning(let info) = event { return info }
            return nil
        }
        #expect(warnings.count == 3,
                "different nodeIDs must each emit once; got \(warnings.count)")
    }

    @Test("Live TUI + no sinks: warning routes to log file, not stderr")
    func livesinkRoutesWarningsToFile() throws {
        DebugStream.shared.resetWarningDedup()
        DebugStream.shared.removeAllSinks()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terminalui-warnings-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            DebugStream.shared.setLiveTUI(false)
            DebugStream.shared.resetWarningDedup()
        }
        DebugStream.shared.setLiveTUI(true, logFileURL: tmp)

        DebugStream.shared.emitWarning(
            .componentOverflow,
            message: "node Y wrote 99 cells",
            nodeID: "live-node"
        )

        let contents = try String(contentsOf: tmp, encoding: .utf8)
        #expect(contents.contains("componentOverflow"),
                "warning should be appended to the log file under live-TUI mode")
        #expect(contents.contains("node Y wrote 99 cells"),
                "log line should include the warning message")
    }
}
#endif
