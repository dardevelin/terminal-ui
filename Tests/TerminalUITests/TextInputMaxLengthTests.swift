import Testing
@testable import TerminalUI

// `maxLength` is a hard ceiling on the value's character count. When
// the buffer is full, `.character` insertions are blocked at the
// handler and the `.maxLength` boundary reason fires through the
// environment's boundary-hit action — symmetric to the cursor-wall emits in
// `TextInputBoundaryTests`. Backspace still works (the ceiling is
// not a one-way ratchet), and retyping after a backspace fits.

@MainActor
private func driveTextInput(text: Binding<String>,
                            maxLength: Int?,
                            env: EnvironmentValues,
                            keys: [Key]) {
    let view = TextInput(text: text, maxLength: maxLength)
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

@Suite("TextInput maxLength — hard ceiling on value.count")
@MainActor
struct TextInputMaxLengthTests {

    @Test("typing past maxLength leaves value at the ceiling")
    func typingPastCeilingClamps() {
        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let env = EnvironmentValues()  // default .bounce, no callback

        // maxLength=3, typing 5 chars → value should stop at 3.
        driveTextInput(text: textBinding, maxLength: 3, env: env,
                       keys: [.character("a"), .character("b"), .character("c"),
                              .character("d"), .character("e")])
        #expect(value == "abc",
                "typing past maxLength=3 should leave value='abc'; got '\(value)'")
    }

    @Test("blocked insert fires .maxLength through the boundary-hit action (.bounce mode)")
    func blockedInsertEmitsMaxLength() {
        let recorder = BoundaryRecorder()

        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        // Fill to ceiling (3 chars), then 2 more chars should each
        // emit .maxLength and not modify the value.
        driveTextInput(text: textBinding, maxLength: 3, env: env,
                       keys: [.character("a"), .character("b"), .character("c"),
                              .character("d"), .character("e")])
        #expect(value == "abc")
        #expect(recorder.bounce == [.maxLength, .maxLength],
                "two blocked inserts should fire two .maxLength emits; got \(recorder.bounce)")
    }

    @Test("blocked insert under .modal mode dispatches to .onBoundaryHit")
    func blockedInsertModalCallback() {
        let recorder = BoundaryRecorder()
        var value = "ab"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .modal

        // Already at ceiling (maxLength=2, value="ab"). One more char
        // should fire .maxLength to the callback.
        driveTextInput(text: textBinding, maxLength: 2, env: env,
                       keys: [.character("c")])
        #expect(value == "ab")
        #expect(recorder.modal == [.maxLength],
                ".modal mode should dispatch .maxLength to onBoundaryHit; got \(recorder.modal)")
    }

    @Test("backspace + retype works — ceiling is not a one-way ratchet")
    func backspaceRetypeFits() {
        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let env = EnvironmentValues()

        // Fill, backspace, retype: still fits.
        driveTextInput(text: textBinding, maxLength: 3, env: env,
                       keys: [.character("a"), .character("b"), .character("c"),
                              .backspace,
                              .character("z")])
        #expect(value == "abz",
                "backspace + retype should produce 'abz'; got '\(value)'")
    }

    @Test("nil maxLength imposes no ceiling")
    func nilMaxLengthIsUnlimited() {
        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let env = EnvironmentValues()

        let payload = "the quick brown fox jumps"
        driveTextInput(text: textBinding, maxLength: nil, env: env,
                       keys: payload.map { .character($0) })
        #expect(value == payload,
                "nil maxLength should impose no ceiling; got '\(value)'")
    }

    @Test("mid-buffer insert respects maxLength")
    func midBufferInsertRespectsCeiling() {
        let recorder = BoundaryRecorder()

        var value = "ac"
        let textBinding = Binding(get: { value }, set: { value = $0 })
        var env = recorder.environment
        env.boundaryFeedback = .bounce

        // maxLength=3, value="ac" (2 chars). Cursor at end. Move
        // Left, type 'b' — fits (count goes to 3 — exactly the
        // ceiling, allowed). Then type 'X' — blocked + emit.
        driveTextInput(text: textBinding, maxLength: 3, env: env,
                       keys: [.left, .character("b"), .character("X")])
        #expect(value == "abc",
                "mid-buffer insert at room=1 should fit; got '\(value)'")
        #expect(recorder.bounce == [.maxLength],
                "second mid-buffer insert at full buffer should fire one .maxLength; got \(recorder.bounce)")
    }

    @Test("init carries maxLength through to handler")
    func initCarriesMaxLength() {
        // Sanity that the new parameter exists on both init overloads.
        // No-arg label, with-axis overload.
        var value = ""
        let textBinding = Binding(get: { value }, set: { value = $0 })
        _ = TextInput(text: textBinding, maxLength: 5)
        _ = TextInput(text: textBinding, axis: .vertical, maxLength: 5)
    }
}
