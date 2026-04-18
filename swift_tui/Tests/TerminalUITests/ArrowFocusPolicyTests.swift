import Testing
@testable import TerminalUI

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// User direction 2026-04-18:
//   "arrow down on an element that has the focus shouldn't move focus out of
//    it, tab is the focus changer, unless marked as allow"
//
// Validates the policy encoded at TerminalApp.swift: only when the
// `allowArrowFocusNavigation` environment value is `.true` should arrow
// presses unhandled by the focused view fall through to
// `FocusEngine.focusInDirection`.

@Suite("Arrow focus policy — default off, opt-in via env")
@MainActor
struct ArrowFocusPolicyTests {

    @Test("default EnvironmentValues has allowArrowFocusNavigation == false")
    func defaultIsOff() {
        #expect(EnvironmentValues().allowArrowFocusNavigation == false)
    }

    @Test("arrow direction fires focus change when called directly (engine-level behavior unchanged)")
    func engineStillRespondsWhenCalled() {
        // Safety check: FocusEngine's own `focusInDirection` still works as
        // before — the policy gate lives at the event-loop level, not in
        // the engine. Apps that want to arrow-navigate inside a custom
        // input handler can still invoke it explicitly.
        resetGraphContext()
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
        engine.focusInDirection(.down, root: root)
        #expect(engine.keyboardFocusID == root.children[1].id)
    }
}
