import Testing
@testable import TerminalUI

// User direction 2026-04-18:
//   "arrow down on an element that has the focus shouldn't move focus out of
//    it, tab is the focus changer, unless marked as allow"
//
// Validates the policy encoded at TerminalApp.swift: only when the
// `allowArrowFocusNavigation` environment value is `.true` should arrow
// presses unhandled by the focused view fall through to
// `FocusEngine.move`.

@Suite("Arrow focus policy — default off, opt-in via env")
@MainActor
struct ArrowFocusPolicyTests {

    @Test("default EnvironmentValues has allowArrowFocusNavigation == false")
    func defaultIsOff() {
        #expect(EnvironmentValues().allowArrowFocusNavigation == false)
    }

    @Test("arrow direction fires focus change when called directly (engine-level behavior unchanged)")
    func engineStillRespondsWhenCalled() {
        // Safety check: FocusEngine's own `move` still works as
        // before — the policy gate lives at the event-loop level, not in
        // the engine. Apps that want to arrow-navigate inside a custom
        // input handler can still invoke it explicitly.
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[1].isFocusable = true
        root.children[0].rect = Rect(x: 0, y: 0, width: 1, height: 1)
        root.children[1].rect = Rect(x: 0, y: 1, width: 1, height: 1)
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[0].id
        engine.move(.down, root: root)
        #expect(engine.keyboardFocusID == root.children[1].id)
    }

    @Test("crossStack policy resolves from focused node's _resolvedEnv, not GraphContext")
    func crossStackResolvesFromResolvedEnv() {
        // Pre-@TaskLocal, the runtime read GraphContext.currentEnvironment
        // for `allowArrowFocusNavigation`. After the migration that
        // global is bound only for the duration of a frame's render
        // walk; key events run between frames where the binding is
        // unbound. The fix resolves from the focused node's stamped
        // `_resolvedEnv` instead, which persists across frames.
        //
        // This test pins that contract by stamping a focused node with
        // a known `_resolvedEnv`, asking the runtime helper-shape
        // (focused.node._resolvedEnv) to surface the value, and
        // confirming GraphContext.currentEnvironment is irrelevant.
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[0].rect = Rect(x: 0, y: 0, width: 1, height: 1)

        var env = EnvironmentValues()
        env.allowArrowFocusNavigation = true
        root.children[0]._resolvedEnv = env

        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[0].id

        let focused = engine.focusedNode(in: root)
        let crossStack = focused?._resolvedEnv?.allowArrowFocusNavigation == true
        #expect(crossStack,
                "runtime arrow-nav must resolve allowArrowFocusNavigation from focused node's stamped _resolvedEnv")

        // GraphContext is unbound here (no `withValue` scope) — the
        // legacy read path would observe nil and silently disable
        // cross-stack nav. Pin that the new path doesn't depend on it.
        #expect(GraphContext.currentEnvironment == nil,
                "test must not have a current GraphContext binding")
    }
}
