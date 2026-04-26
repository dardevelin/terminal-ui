import Foundation
import Testing
@testable import TerminalUI

// Boundary feedback: input components fire a feedback emitter when
// their internal cursor / maxLength logic hits a wall. The emitter
// reads the active `BoundaryFeedback` env value and routes:
//
//   .bell    → emits ASCII BEL (\x07) to OutputBuffer
//   .bounce  → cursor animates briefly (per-component visual)
//   .modal   → invokes the .onBoundaryHit callback if registered
//   .none    → silent
//
// Input components (TextInput, TextArea, PromptInput) call into the
// emitter at their boundary-hit sites; the wiring per component
// happens incrementally. The API surface ships here; TextInput is
// the canary consumer.
//
// Public API:
//
//   .onBoundaryHit { reason in ... }
//   BoundaryHitReason = .leftEdge / .rightEdge / .topEdge / .bottomEdge / .maxLength

@Suite("BoundaryHitReason — five canonical reasons")
@MainActor
struct BoundaryHitReasonTests {

    @Test("five reason cases per spec")
    func fiveReasons() {
        // The five wall types from the ticket spec. Edge cases for
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

@Suite("BoundaryFeedbackEmitter — routes per env value")
@MainActor
struct BoundaryFeedbackEmitterTests {

    @Test(".bell route increments the bell counter")
    func bellRoutes() {
        var env = EnvironmentValues()
        env.boundaryFeedback = .bell
        let probe = BoundaryFeedbackProbe()
        probe.emit(reason: .rightEdge, env: env, callback: nil)
        #expect(probe.bellCount == 1,
                ".bell mode must increment bellCount; got \(probe.bellCount)")
        #expect(probe.callbackCount == 0)
    }

    @Test(".modal route invokes the registered callback")
    func modalRoutes() {
        var env = EnvironmentValues()
        env.boundaryFeedback = .modal
        let probe = BoundaryFeedbackProbe()
        // The probe + the framework treat the callback as Sendable.
        // Use a class-typed box so the @Sendable closure can mutate
        // shared state without sendability-violation noise.
        final class Box: @unchecked Sendable { var reason: BoundaryHitReason? }
        let captured = Box()
        let cb = BoundaryHitCallback { reason in captured.reason = reason }
        probe.emit(reason: .maxLength, env: env, callback: cb)
        #expect(probe.callbackCount == 1)
        #expect(captured.reason == .maxLength)
    }

    @Test(".none route is silent")
    func noneRoutes() {
        var env = EnvironmentValues()
        env.boundaryFeedback = .none
        let probe = BoundaryFeedbackProbe()
        probe.emit(reason: .leftEdge, env: env, callback: nil)
        #expect(probe.bellCount == 0)
        #expect(probe.callbackCount == 0)
    }

    @Test(".bounce route bumps the bounce counter (visual hook for components)")
    func bounceRoutes() {
        var env = EnvironmentValues()
        env.boundaryFeedback = .bounce
        let probe = BoundaryFeedbackProbe()
        probe.emit(reason: .topEdge, env: env, callback: nil)
        #expect(probe.bounceCount == 1,
                ".bounce mode must signal bounceCount for the component-side animator")
    }
}

@Suite(".onBoundaryHit modifier — registers callback in env")
@MainActor
struct OnBoundaryHitModifierTests {

    @Test(".onBoundaryHit attaches a callback the renderer can read")
    func onBoundaryHitAttaches() {
        // Sanity: the modifier compiles and produces a chainable
        // ModifiedView. Behavioural assertion that the callback is
        // invoked via .modal lives in the emitter test above.
        let view = Text("x").onBoundaryHit { _ in }
        _ = view
    }
}
