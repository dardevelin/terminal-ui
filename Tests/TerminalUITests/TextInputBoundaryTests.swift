import Testing
@testable import TerminalUI

// TextInput → boundary-hit wiring. The boundary-hit action +
// reason enum + .onBoundaryHit modifier ship in BoundaryFeedback.swift;
// the cursor model ships in TextInput.swift. This pins the actual emit calls
// at the two TextInput wall sites:
//
//   * cursor at column 0 + Left → .leftEdge
//   * cursor at value.count + Right → .rightEdge
//
// .maxLength is excluded — TextInput doesn't yet have a maxLength
// parameter — the .maxLength wall is exercised by TextInputMaxLengthTests
// once the parameter exists. Excluded from this suite.

/// Drive a TextInput with the given env (configures boundaryFeedback +
/// onBoundaryHit), focus its node, dispatch the keys.
@MainActor
private func driveTextInput(text: Binding<String>,
                            env: EnvironmentValues,
                            keys: [Key]) -> (FocusEngine, AttributeGraph) {
    let view = TextInput(text: text)
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
    return (engine, graph)
}

@Suite("TextInput boundary emit — cursor at edge fires the right reason")
@MainActor
struct TextInputBoundaryEmitTests {

    @Test("Left at cursor=0 fires .leftEdge under .bounce mode")
    func leftEdgeAtStart() {
        let recorder = BoundaryRecorder()

        var value = "abc"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        // Cursor starts at end (3). Send Home to reach cursor=0, then
        // Left — that's the wall hit. The two prior Lefts (during
        // initial nav from end) must NOT fire because cursor is still
        // mid-buffer.
        _ = driveTextInput(text: textBinding, env: env,
                           keys: [.home, .left])
        #expect(recorder.bounce == [.leftEdge],
                "Left at cursor=0 must fire .leftEdge once; got \(recorder.bounce)")
    }

    @Test("Right at cursor=value.count fires .rightEdge under .bounce mode")
    func rightEdgeAtEnd() {
        let recorder = BoundaryRecorder()

        var value = "abc"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        // Cursor at end already. Right is the wall.
        _ = driveTextInput(text: textBinding, env: env, keys: [.right])
        #expect(recorder.bounce == [.rightEdge],
                "Right at end must fire .rightEdge once; got \(recorder.bounce)")
    }

    @Test("Left/Right mid-buffer do NOT fire — only walls")
    func midBufferSilent() {
        let recorder = BoundaryRecorder()

        var value = "abcdef"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        // Home gets cursor to 0, then 3 Rights move it to position 3
        // — nowhere near a wall.
        _ = driveTextInput(text: textBinding, env: env,
                           keys: [.home, .right, .right, .right])
        #expect(recorder.bounce.isEmpty,
                "Mid-buffer arrows must not emit; got \(recorder.bounce)")
    }

    @Test(".bell mode at the wall increments bellCount")
    func bellAtWall() {
        let recorder = BoundaryRecorder()

        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bell

        // Empty value: cursor at 0, both Left and Right are walls.
        // Left → .leftEdge; Right (value.count == 0) → .rightEdge.
        _ = driveTextInput(text: textBinding, env: env,
                           keys: [.left, .right])
        #expect(recorder.bell == 2,
                ".bell mode at two walls should fire bell sink twice; got \(recorder.bell)")
    }

    @Test(".modal mode invokes the .onBoundaryHit callback")
    func modalInvokesCallback() {
        let recorder = BoundaryRecorder()

        var value = "x"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .modal

        // Home → Left fires .leftEdge; End → Right fires .rightEdge.
        _ = driveTextInput(text: textBinding, env: env,
                           keys: [.home, .left, .end, .right])
        #expect(recorder.modal == [.leftEdge, .rightEdge],
                ".modal mode should dispatch to onBoundaryHit; got \(recorder.modal)")
        // Bounce/bell sinks remain untouched under .modal.
        #expect(recorder.bounce.isEmpty)
        #expect(recorder.bell == 0)
    }

    @Test(".none mode at the wall is silent")
    func noneSilent() {
        let recorder = BoundaryRecorder()

        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .none

        _ = driveTextInput(text: textBinding, env: env,
                           keys: [.left, .right])
        #expect(recorder.bell == 0)
        #expect(recorder.bounce.isEmpty,
                ".none mode must not emit anything; got \(recorder.bounce)")
    }
}
