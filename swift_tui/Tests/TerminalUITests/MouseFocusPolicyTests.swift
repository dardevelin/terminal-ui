import Testing
@testable import TerminalUI

// Policy-driven mouse routing. The framework default (.clickToLock)
// covers the canonical "click promotes, wheel routes to hover, hover
// alone never moves keyboard focus" semantics; this suite exercises
// the three additional cases behind the public env enum and the
// .disabled escape hatch.
//
// Tests sit at the FocusEngine boundary: it exposes a policy-aware
// `applyMouseMove(x:y:root:policy:)` and `applyMouseWheel(...)` that the
// runtime delegates into. Keeps the assertions hermetic — no full
// TerminalApp required.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

/// Build a graph with two focusables side-by-side so a single x/y can
/// pick exactly one. Returns (engine, graph, leftID, rightID).
@MainActor
private func makeTwoFocusableHarness() -> (FocusEngine, AttributeGraph, NodeID, NodeID) {
    resetGraphContext()
    let graph = AttributeGraph()
    graph.update(from: VStack { Text("left"); Text("right") })
    let root = graph.root!
    let left = root.children[0]
    let right = root.children[1]
    left.isFocusable = true
    right.isFocusable = true
    left.rect = Rect(x: 0, y: 0, width: 5, height: 1)
    right.rect = Rect(x: 0, y: 1, width: 5, height: 1)
    let engine = FocusEngine()
    engine.rebuildIndex(root: root)
    return (engine, graph, left.id, right.id)
}

@Suite("MouseFocusPolicy — defaults")
@MainActor
struct MouseFocusPolicyDefaultTests {

    @Test("env default is .clickToLock")
    func envDefault() {
        let env = EnvironmentValues()
        #expect(env.mouseFocusPolicy == .clickToLock)
    }
}

@Suite("MouseFocusPolicy — .clickToLock (default)")
@MainActor
struct MouseFocusPolicyClickToLockTests {

    @Test("hover does NOT move keyboard focus")
    func hoverDoesNotMoveFocus() {
        let (engine, graph, leftID, _) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.applyMouseMove(x: 2, y: 1, root: graph.root!, policy: .clickToLock)
        #expect(engine.keyboardFocusID == leftID, "hover must not steal keyboard focus under .clickToLock")
    }

    @Test("hover updates mouseHoverID separately")
    func hoverUpdatesHoverState() {
        let (engine, graph, _, rightID) = makeTwoFocusableHarness()
        engine.applyMouseMove(x: 2, y: 1, root: graph.root!, policy: .clickToLock)
        #expect(engine.mouseHoverID == rightID)
    }
}

@Suite("MouseFocusPolicy — .hoverFollows")
@MainActor
struct MouseFocusPolicyHoverFollowsTests {

    @Test("hover sets keyboard focus to hover target")
    func hoverMovesFocus() {
        let (engine, graph, leftID, rightID) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.applyMouseMove(x: 2, y: 1, root: graph.root!, policy: .hoverFollows)
        #expect(engine.keyboardFocusID == rightID, "hover under .hoverFollows must move keyboard focus")
    }

    @Test("hover over non-focusable area clears nothing")
    func hoverOverEmpty() {
        let (engine, graph, leftID, _) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.applyMouseMove(x: 99, y: 99, root: graph.root!, policy: .hoverFollows)
        #expect(engine.keyboardFocusID == leftID, "hover over empty space must not clear keyboard focus")
    }
}

@Suite("MouseFocusPolicy — .clickOnly")
@MainActor
struct MouseFocusPolicyClickOnlyTests {

    @Test("wheel routes to keyboard focus, not hover target")
    func wheelTargetsKeyboardFocus() {
        let (engine, graph, leftID, rightID) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.mouseHoverID = rightID
        let target = engine.wheelTargetID(x: 2, y: 1, root: graph.root!, policy: .clickOnly)
        #expect(target == leftID, ".clickOnly wheel must route to keyboard-focused id, not hover")
    }

    @Test(".clickToLock wheel routes to hover target")
    func clickToLockWheelTargetsHover() {
        let (engine, graph, leftID, rightID) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.mouseHoverID = rightID
        let target = engine.wheelTargetID(x: 2, y: 1, root: graph.root!, policy: .clickToLock)
        #expect(target == rightID, ".clickToLock wheel must route to hover-target focusable")
    }

    /// Wheel-over-inert contract: when the cursor sits over inert
    /// space (no focusable hit), wheel events must be DROPPED, not
    /// fall back to the keyboard-focused element. Falling back
    /// resurrects the original bug — wheeling over the Storybook
    /// preview while the sidebar is keyboard-focused advances the
    /// sidebar selection.
    @Test(".clickToLock wheel returns nil when cursor is over inert space")
    func clickToLockWheelDropsOverInert() {
        let (engine, graph, leftID, _) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        let target = engine.wheelTargetID(x: 99, y: 99, root: graph.root!, policy: .clickToLock)
        #expect(target == nil, ".clickToLock wheel over inert space must drop, not fall back to keyboard focus")
    }

    @Test(".hoverFollows wheel returns nil when cursor is over inert space")
    func hoverFollowsWheelDropsOverInert() {
        let (engine, graph, leftID, _) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        let target = engine.wheelTargetID(x: 99, y: 99, root: graph.root!, policy: .hoverFollows)
        #expect(target == nil, ".hoverFollows wheel over inert space must drop, not fall back to keyboard focus")
    }
}

@Suite("MouseFocusPolicy — .disabled")
@MainActor
struct MouseFocusPolicyDisabledTests {

    @Test("hover does not update mouseHoverID")
    func hoverIgnoredForState() {
        let (engine, graph, _, _) = makeTwoFocusableHarness()
        engine.applyMouseMove(x: 2, y: 1, root: graph.root!, policy: .disabled)
        #expect(engine.mouseHoverID == nil, ".disabled must not track framework hover state")
    }

    @Test("hover does not move keyboard focus")
    func hoverIgnoredForFocus() {
        let (engine, graph, leftID, _) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.applyMouseMove(x: 2, y: 1, root: graph.root!, policy: .disabled)
        #expect(engine.keyboardFocusID == leftID)
    }

    @Test("wheelTargetID returns nil so runtime drops the event")
    func wheelInert() {
        let (engine, graph, leftID, rightID) = makeTwoFocusableHarness()
        engine.keyboardFocusID = leftID
        engine.mouseHoverID = rightID
        let target = engine.wheelTargetID(x: 2, y: 1, root: graph.root!, policy: .disabled)
        #expect(target == nil, ".disabled must report no auto-routed wheel target")
    }
}
