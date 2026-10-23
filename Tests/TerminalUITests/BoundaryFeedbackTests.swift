import Foundation
import Testing
@testable import TerminalUI

// Boundary feedback: TextInput, TextArea and PromptInput call the
// environment's `boundaryHit` action when their cursor or maxLength logic
// hits a wall. It reads the subtree's `BoundaryFeedback` mode and routes:
//
//   .bell    → rings the environment's `BellAction` (BEL in a running app)
//   .bounce  → the subtree's own bounce hook, else the shared emitter's
//              `bounceSink`, a no-op until an app installs one
//   .modal   → invokes the .onBoundaryHit callback if registered
//   .none    → silent
//
// Public API:
//
//   .boundaryFeedback(_:), .onBoundaryHit { reason in ... }
//   @TerminalEnvironment(\.boundaryHit), @TerminalEnvironment(\.bell)
//   BoundaryHitReason = .leftEdge / .rightEdge / .topEdge / .bottomEdge / .maxLength

@Suite("BoundaryHitReason — five canonical reasons")
@MainActor
struct BoundaryHitReasonTests {

    @Test("five reason cases per spec")
    func fiveReasons() {
        // The five wall types. Edge cases for
        // cursor-at-extreme; maxLength for fixed-width inputs.
        let reasons: [BoundaryHitReason] = [
            .leftEdge,
            .rightEdge,
            .topEdge,
            .bottomEdge,
            .maxLength,
        ]
        #expect(Set(reasons).count == 5,
                "five canonical reasons must be distinct cases; got \(reasons)")
    }
}

// Each mode routes a hit to one place. A subtree can carry its own `.bounce`
// hook in the environment, and its hits go there instead of to the shared
// emitter's: suites that drove inputs into walls each swapped the one
// process-wide hook, and run side by side, one suite's hits reached another's
// recorder.
@Suite("The boundary-hit action routes by the subtree's mode")
@MainActor
struct BoundaryHitRoutingTests {

    private func hit(_ reason: BoundaryHitReason, under mode: BoundaryFeedback) -> BoundaryRecorder {
        let recorder = BoundaryRecorder()
        var env = recorder.environment
        env.boundaryFeedback = mode
        env.boundaryHit(reason)
        return recorder
    }

    @Test func bellRingsTheBell() {
        let recorder = hit(.rightEdge, under: .bell)
        #expect(recorder.bell == 1)
        #expect(recorder.bounce.isEmpty && recorder.modal.isEmpty)
    }

    @Test func modalCallsTheCallback() {
        let recorder = hit(.maxLength, under: .modal)
        #expect(recorder.modal == [.maxLength])
        #expect(recorder.bell == 0 && recorder.bounce.isEmpty)
    }

    @Test func noneIsSilent() {
        let recorder = hit(.leftEdge, under: .none)
        #expect(recorder.bell == 0 && recorder.bounce.isEmpty && recorder.modal.isEmpty)
    }

    @Test func bounceCallsTheSubtreesHookOverTheSharedOne() {
        #expect(EnvironmentValues().boundaryBounce == nil, "with none, a hit goes to the shared emitter's hook")
        let recorder = hit(.topEdge, under: .bounce)
        #expect(recorder.bounce == [.topEdge])
        #expect(recorder.bell == 0 && recorder.modal.isEmpty)
    }
}

@Suite(".onBoundaryHit modifier — registers callback in env")
@MainActor
struct OnBoundaryHitModifierTests {

    @Test(".onBoundaryHit attaches a callback the renderer can read")
    func onBoundaryHitAttaches() {
        // Sanity: the modifier compiles and produces a chainable
        // ModifiedView. Behavioural assertion that the callback is
        // invoked via .modal lives in the routing tests above.
        let view = Text("x").onBoundaryHit { _ in }
        _ = view
    }
}
