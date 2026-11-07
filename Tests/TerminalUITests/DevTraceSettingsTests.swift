#if DEBUG
import Foundation
import Testing
import TerminalUIConfig
@testable import TerminalUI

// Every app that did not state a `devTrace` was handed one by the protocol's
// default — tracing on, 100 frames — and the runtime took a stated one over
// the file, so `.terminalui/terminalui.toml`'s `[trace]` section reached no
// app at all: `swtui disable trace` and `swtui set frame_limit` changed
// nothing, and a run traced exactly 100 frames whatever the file said.

private struct StatesNothingApp: TerminalAppProtocol {
    static func content() -> some TerminalView { Text("plain") }
}

private struct StatesItsOwnApp: TerminalAppProtocol {
    static var devTrace: DevTraceConfig? {
        DevTraceConfig(enabled: true, screenshotDir: "/ignored", traceDir: "/ignored",
                       captureScreenshots: true, captureTrace: false,
                       captureEvents: true, frameLimit: 7)
    }
    static func content() -> some TerminalView { Text("own") }
}

private func fileConfig(traceEnabled: Bool = true, frameLimit: Int? = 150) -> DiagConfig {
    DiagConfig(traceEnabled: traceEnabled, captureScreenshots: false, captureEvents: false,
               frameLimit: frameLimit, captureEnabled: false, useTmp: false, socketEnabled: false)
}

@Suite("A run traces what the file says unless the app states its own")
struct DevTraceSettingsTests {

    @Test func anAppThatStatesNothingDefersToTheFile() {
        #expect(StatesNothingApp.devTrace == nil)
    }

    @Test func theFilesTraceSectionReachesAnAppThatStatesNothing() {
        let config = DevTraceConfig.resolved(stated: StatesNothingApp.devTrace, file: fileConfig())
        #expect(config.enabled)
        #expect(config.captureTrace)
        #expect(!config.captureScreenshots)
        #expect(!config.captureEvents)
        #expect(config.frameLimit == 150)
        #expect(config.traceDir == DiagPaths.tracesDir(useTmp: false))
        #expect(config.screenshotDir == DiagPaths.screenshotsDir(useTmp: false))
    }

    @Test func traceTurnedOffInTheFileIsOff() {
        let config = DevTraceConfig.resolved(stated: StatesNothingApp.devTrace,
                                             file: fileConfig(traceEnabled: false))
        #expect(!config.enabled)
    }

    @Test func noFileTracesNothing() {
        let config = DevTraceConfig.resolved(stated: StatesNothingApp.devTrace, file: .default)
        #expect(!config.enabled)
    }

    @Test func anAppThatStatesItsOwnWinsAndWritesWhereTheFileSays() {
        let config = DevTraceConfig.resolved(stated: StatesItsOwnApp.devTrace,
                                             file: fileConfig(traceEnabled: false, frameLimit: 150))
        #expect(config.enabled)
        #expect(!config.captureTrace)
        #expect(config.captureScreenshots)
        #expect(config.captureEvents)
        #expect(config.frameLimit == 7)
        #expect(config.traceDir == DiagPaths.tracesDir(useTmp: false))
        #expect(config.screenshotDir == DiagPaths.screenshotsDir(useTmp: false))
    }

    @Test func theFilesFrameLimitHoldsPastAHundredFrames() {
        var config = DevTraceConfig.resolved(stated: StatesNothingApp.devTrace, file: fileConfig())
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtrace-settings-\(UUID().uuidString)").path
        config.screenshotDir = scratch
        config.traceDir = scratch
        let tracer = DevTracer()
        tracer.configure(config)
        let buffer = CellBuffer(width: 1, height: 1)
        for _ in 0..<200 {
            tracer.beginFrame()
            tracer.endFrame(buffer: buffer, previousBuffer: nil)
        }
        let closedFrames = tracer.recordedFrames().dropLast()
        #expect(closedFrames.count == 150)
        try? FileManager.default.removeItem(atPath: scratch)
    }
}
#endif
