import Testing
@testable import TerminalUI

// TextArea → boundary-hit wiring. Mirrors the TextInput
// suite (TextInputBoundaryTests) but exercises the four buffer-edge walls instead
// of two:
//
//   * cursor at (0, 0), user pressed Left  → .leftEdge
//   * cursor at (lastRow, lastCol), Right  → .rightEdge
//   * cursor on row 0, user pressed Up     → .topEdge
//   * cursor on last row, user pressed Down → .bottomEdge
//
// .maxLength is excluded — TextArea is multi-line free-form, no
// ceiling concept. Mid-row Left/Right that crosses logical lines
// (col=0 on row=2 + Left) MUST NOT fire .leftEdge — it's a
// legitimate movement to the previous row's tail.

/// Drive a TextArea with the given env, focus its node, dispatch keys.
@MainActor
private func driveTextArea(text: Binding<String>,
                           state: Binding<TextAreaState>,
                           env: EnvironmentValues,
                           keys: [Key]) {
    let view = TextArea(text: text, state: state)
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

@Suite("TextArea boundary emit — four buffer-edge walls")
@MainActor
struct TextAreaBoundaryEmitTests {

    @Test("Left at (0,0) fires .leftEdge under .bounce")
    func leftEdgeAtOrigin() {
        let recorder = BoundaryRecorder()

        var value = "hello"
        var st = TextAreaState()  // cursor at (0, 0)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.left])
        #expect(recorder.bounce == [.leftEdge],
                "Left at (0,0) must fire .leftEdge once; got \(recorder.bounce)")
    }

    @Test("Right at (lastRow, lastCol) fires .rightEdge under .bounce")
    func rightEdgeAtEnd() {
        let recorder = BoundaryRecorder()

        var value = "ab\ncd"  // 2 logical rows, "cd" is last
        var st = TextAreaState(); st.cursor = TextAreaCursor(row: 1, col: 2)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.right])
        #expect(recorder.bounce == [.rightEdge],
                "Right at end-of-buffer must fire .rightEdge once; got \(recorder.bounce)")
    }

    @Test("Up on row 0 fires .topEdge under .bounce")
    func topEdgeOnFirstRow() {
        let recorder = BoundaryRecorder()

        var value = "ab\ncd"
        var st = TextAreaState()  // (0, 0)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.up])
        #expect(recorder.bounce == [.topEdge],
                "Up on row 0 must fire .topEdge once; got \(recorder.bounce)")
    }

    @Test("Down on last row fires .bottomEdge under .bounce")
    func bottomEdgeOnLastRow() {
        let recorder = BoundaryRecorder()

        var value = "ab\ncd"
        var st = TextAreaState(); st.cursor = TextAreaCursor(row: 1, col: 0)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.down])
        #expect(recorder.bounce == [.bottomEdge],
                "Down on last row must fire .bottomEdge once; got \(recorder.bounce)")
    }

    @Test("Left at (1, 0) does NOT fire .leftEdge — it crosses to previous row's tail")
    func leftAtRowStartCrossesUpwards() {
        let recorder = BoundaryRecorder()

        var value = "ab\ncd"
        var st = TextAreaState(); st.cursor = TextAreaCursor(row: 1, col: 0)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.left])
        #expect(recorder.bounce.isEmpty,
                "Left at (1,0) is a legitimate cross to previous row's tail — must not emit; got \(recorder.bounce)")
    }

    @Test("Right at end-of-row when more rows exist — NO emit (crosses to next row)")
    func rightAtRowEndCrossesDownwards() {
        let recorder = BoundaryRecorder()

        var value = "ab\ncd"
        var st = TextAreaState(); st.cursor = TextAreaCursor(row: 0, col: 2)
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.right])
        #expect(recorder.bounce.isEmpty,
                "Right at end-of-row 0 is a cross to row 1 — must not emit; got \(recorder.bounce)")
    }

    @Test(".modal mode dispatches each wall to .onBoundaryHit")
    func modalDispatch() {
        let recorder = BoundaryRecorder()
        var value = "ab"  // single row "ab" — all four walls reachable from (0,0)/(0,2)
        var st = TextAreaState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .modal

        // (0,0): Left → .leftEdge, Up → .topEdge.
        // Move to end (right twice gets to col 2 — that's the wall),
        // and Right + Down → .rightEdge + .bottomEdge.
        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.left, .up, .end, .right, .down])
        #expect(recorder.modal == [.leftEdge, .topEdge, .rightEdge, .bottomEdge],
                ".modal must dispatch each wall reason; got \(recorder.modal)")
    }

    @Test(".none mode at the wall is silent")
    func noneSilent() {
        let recorder = BoundaryRecorder()

        var value = "x"
        var st = TextAreaState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { st }, set: { st = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .none

        driveTextArea(text: textBinding, state: stateBinding, env: env,
                      keys: [.left, .up, .end, .right, .down])
        #expect(recorder.bell == 0)
        #expect(recorder.bounce.isEmpty,
                ".none mode must stay silent at all walls; got \(recorder.bounce)")
    }
}
