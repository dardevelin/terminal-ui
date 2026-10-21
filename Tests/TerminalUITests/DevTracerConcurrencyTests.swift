#if DEBUG
import Foundation
import Testing
@testable import TerminalUI

// The input task records the bytes of every event it parses while the render
// loop opens and closes frames on another thread, and both wrote the same
// array unguarded. A burst of wheel events in Coder crashed it, in the array's
// reallocation. Recording is now serialised, and input traced between frames
// lands in the next frame instead of being cleared away by it.

@Suite("Trace recording is safe from any thread")
struct DevTracerConcurrencyTests {

    @Test func inputTracedWhileFramesTurnOverIsAllKept() async {
        let tracer = DevTracer()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtracer-\(UUID().uuidString)").path
        tracer.configure(DevTraceConfig(enabled: true, screenshotDir: scratch, traceDir: scratch,
                                        captureScreenshots: false, captureTrace: false,
                                        captureEvents: true, frameLimit: nil))
        let events = 20_000
        let frames = 2_000
        let buffer = CellBuffer(width: 1, height: 1)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<events {
                    tracer.traceInputBytes([UInt8(truncatingIfNeeded: index)], decoded: "wheel")
                }
            }
            group.addTask {
                for _ in 0..<frames {
                    tracer.beginFrame()
                    tracer.endFrame(buffer: buffer, previousBuffer: nil)
                }
            }
        }
        tracer.beginFrame()
        tracer.endFrame(buffer: buffer, previousBuffer: nil)

        let recorded = tracer.recordedFrames().joined().filter {
            if case .inputBytes = $0 { return true }
            return false
        }
        #expect(recorded.count == events)
        try? FileManager.default.removeItem(atPath: scratch)
    }
}
#endif
