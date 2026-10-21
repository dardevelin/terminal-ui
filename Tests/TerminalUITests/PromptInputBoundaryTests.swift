import Testing
@testable import TerminalUI

// PromptInput → BoundaryFeedbackEmitter wiring. Mirrors TextArea
// (TextAreaBoundaryTests) but with two PromptInput-specific quirks:
//
//   1. Plain Enter submits — it doesn't fall through to a wall
//      check. So "Enter at end of last row" is NOT a .bottomEdge
//      hit; it's a submit. Modified Enter (Shift/Alt/Ctrl+Enter)
//      inserts a newline, also not a wall.
//
//   2. Up/Down at the visual edge of the input compete with
//      history recall. The wall fires only when arrow movement
//      didn't navigate AND history couldn't be recalled either.
//
// Wall sites:
//   * cursor at (0, 0), Left → .leftEdge
//   * cursor at (lastRow, lastCol), Right → .rightEdge
//   * Up at top + no older history → .topEdge
//   * Down at bottom + no newer history (historyIndex < 0) → .bottomEdge

private final class SharedEmitterRecorder: @unchecked Sendable {
    nonisolated(unsafe) var bell = 0
    nonisolated(unsafe) var bounce: [BoundaryHitReason] = []
    private let savedBounce: @Sendable (BoundaryHitReason) -> Void

    init() {
        savedBounce = BoundaryFeedbackEmitter.shared.bounceSink
        BoundaryFeedbackEmitter.shared.bounceSink = { [weak self] reason in
            self?.bounce.append(reason)
        }
    }

    /// The bell to put in the environment a test drives, counting rings.
    var bellAction: BellAction {
        BellAction { [weak self] in self?.bell += 1 }
    }

    func restore() {
        BoundaryFeedbackEmitter.shared.bounceSink = savedBounce
    }
}

@MainActor
private func drivePromptInput(text: Binding<String>,
                              state: Binding<PromptInputState>,
                              env: EnvironmentValues,
                              keys: [Key]) {
    let view = PromptInput(text: text, state: state)
    let graph = AttributeGraph()
    let engine = FocusEngine()
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(env) {
            graph.update(from: view)
        }
    }
    engine.rebuildIndex(root: graph.root!)
    engine.focusNext()
    for key in keys {
        _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
    }
}

@Suite("PromptInput boundary emit — four buffer-edge walls + history-aware Up/Down")
@MainActor
struct PromptInputBoundaryEmitTests {

    @Test("Left at (0, 0) fires .leftEdge under .bounce")
    func leftEdgeAtOrigin() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "hi"
        var st = PromptInputState()  // cursor at (0, 0)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.left])
        #expect(recorder.bounce == [.leftEdge],
                "Left at (0,0) must fire .leftEdge once; got \(recorder.bounce)")
    }

    @Test("Right at end of last logical row fires .rightEdge under .bounce")
    func rightEdgeAtEnd() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "ab"  // single row, length 2
        var st = PromptInputState()
        st.cursorCol = 2  // at end
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.right])
        #expect(recorder.bounce == [.rightEdge],
                "Right at end-of-buffer must fire .rightEdge once; got \(recorder.bounce)")
    }

    @Test("Left at (1, 0) does NOT fire .leftEdge — crosses to previous row's tail")
    func leftAtRowStartCrossesUp() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "ab\ncd"
        var st = PromptInputState()
        st.cursorRow = 1; st.cursorCol = 0
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.left])
        #expect(recorder.bounce.isEmpty,
                "Left at (1,0) is a legitimate cross to previous row's tail; got \(recorder.bounce)")
    }

    @Test("Up at top with no history fires .topEdge under .bounce")
    func topEdgeNoHistory() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "single"
        var st = PromptInputState()  // cursor (0, 0), no history
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.up])
        #expect(recorder.bounce == [.topEdge],
                "Up at top with no history must fire .topEdge; got \(recorder.bounce)")
    }

    @Test("Up at top WITH history does NOT fire — history recall takes priority")
    func upWithHistorySilent() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "live"
        var st = PromptInputState()
        st.history = [PromptInputHistoryEntry(text: "older command")]  // one entry available
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.up])
        #expect(recorder.bounce.isEmpty,
                "Up at top with history must recall, not emit; got \(recorder.bounce)")
        // Sanity that history actually loaded.
        #expect(value == "older command",
                "history recall should overwrite text; got '\(value)'")
    }

    @Test("Down at bottom with historyIndex < 0 fires .bottomEdge")
    func bottomEdgeNoHistoryNav() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "hello"
        var st = PromptInputState()
        // Position cursor at end of last (only) row. historyIndex
        // defaults to -1 (live input, nothing to advance to).
        st.cursorCol = 5
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .bounce

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.down])
        #expect(recorder.bounce == [.bottomEdge],
                "Down at bottom with historyIndex=-1 must fire .bottomEdge; got \(recorder.bounce)")
    }

    @Test(".modal mode dispatches each wall to .onBoundaryHit")
    func modalDispatch() {
        final class Box: @unchecked Sendable {
            var reasons: [BoundaryHitReason] = []
        }
        let captured = Box()

        var value = "ab"
        var st = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.boundaryFeedback = .modal
        env.onBoundaryHit = BoundaryHitCallback { reason in
            captured.reasons.append(reason)
        }

        // (0,0): Left → .leftEdge, Up → .topEdge.
        // End → cursor at 2; Right → .rightEdge; Down → .bottomEdge.
        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.left, .up, .end, .right, .down])
        #expect(captured.reasons == [.leftEdge, .topEdge, .rightEdge, .bottomEdge],
                ".modal must dispatch each wall reason; got \(captured.reasons)")
    }

    @Test(".none mode at the wall is silent")
    func noneSilent() {
        let recorder = SharedEmitterRecorder()
        defer { recorder.restore() }

        var value = "x"
        var st = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = EnvironmentValues()
        env.bell = recorder.bellAction
        env.boundaryFeedback = .none

        drivePromptInput(text: textBinding, state: stateBinding, env: env,
                         keys: [.left, .up, .end, .right, .down])
        #expect(recorder.bell == 0)
        #expect(recorder.bounce.isEmpty,
                ".none mode must stay silent at all walls; got \(recorder.bounce)")
    }
}
