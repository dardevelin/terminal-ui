import Testing
@testable import TerminalUI

// .onHover { isHovering in … } follows SwiftUI's signature exactly.
// The callback fires on hover STATE TRANSITIONS only (true on enter,
// false on leave). Movement within an already-hovered rect must not
// re-fire the callback.

@Suite(".onHover modifier — enter/leave callbacks")
@MainActor
struct OnHoverModifierTests {

    @Test("onHover fires true when cursor enters rect")
    func firesTrueOnEnter() {
        let (engine, root, probe) = makeHoverHarness(width: 5)
        engine.applyMouseMove(x: 2, y: 0, root: root, policy: .clickToLock)
        #expect(probe.history == [true])
    }

    @Test("onHover fires false when cursor leaves rect")
    func firesFalseOnLeave() {
        let (engine, root, probe) = makeHoverHarness(width: 5)
        engine.applyMouseMove(x: 2, y: 0, root: root, policy: .clickToLock)
        engine.applyMouseMove(x: 99, y: 99, root: root, policy: .clickToLock)
        #expect(probe.history == [true, false])
    }

    @Test("onHover does NOT fire on intra-rect movement")
    func doesNotFireOnIntraRectMove() {
        let (engine, root, probe) = makeHoverHarness(width: 10)
        engine.applyMouseMove(x: 1, y: 0, root: root, policy: .clickToLock)
        engine.applyMouseMove(x: 5, y: 0, root: root, policy: .clickToLock)
        engine.applyMouseMove(x: 9, y: 0, root: root, policy: .clickToLock)
        #expect(probe.history == [true], "hover state already true — moving inside the rect must not re-fire")
    }

    @Test("onHover fires under .disabled policy too — view callback is opt-in")
    func firesUnderDisabledPolicy() {
        // .disabled turns off framework HOVER STATE tracking
        // (mouseHoverID stays nil), but the user-registered .onHover
        // callback is the whole point of the .disabled escape hatch.
        // It MUST still fire on rect enter/leave.
        let (engine, root, probe) = makeHoverHarness(width: 5)
        engine.applyMouseMove(x: 2, y: 0, root: root, policy: .disabled)
        engine.applyMouseMove(x: 99, y: 99, root: root, policy: .disabled)
        #expect(probe.history == [true, false])
        #expect(engine.mouseHoverID == nil, "framework hover state stays off under .disabled")
    }
}

// MARK: - Helpers

@MainActor
private final class HoverProbe {
    var history: [Bool] = []
    func record(_ isHovering: Bool) { history.append(isHovering) }
}

/// Build a graph containing a single `.onHover`-equipped Text rooted
/// at (0,0). Returns (engine, root, probe). The hover handler is
/// registered with the FocusEngine because `GraphContext.currentFocusEngine`
/// is set before `graph.update`. Caller-controlled rect width keeps the
/// "leave" coordinates outside the rect.
@MainActor
private func makeHoverHarness(width: Int) -> (FocusEngine, AttributeNode, HoverProbe) {
    let engine = FocusEngine()
    let probe = HoverProbe()
    let graph = AttributeGraph()
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: Text("target").onHover { isHovering in
            probe.record(isHovering)
        })
    }
    let root = graph.root!
    // The `.onHover` modifier wraps Text, but the registered handler
    // sits on the modifier's child node. Find that node and stamp a
    // rect — graph construction in tests doesn't run the layout pass.
    if let target = findOnHoverNode(root, engine: engine) {
        target.rect = Rect(x: 0, y: 0, width: width, height: 1)
    }
    engine.rebuildIndex(root: root)
    return (engine, root, probe)
}

/// Walk the graph to find the node that owns the registered hover
/// handler. Mirrors how callers locate `.onClick` targets in tests:
/// search the tree for the node whose ID is in the engine's hover
/// registry. The handler being registered AT ALL is a load-bearing
/// invariant of the `.onHover` modifier — if green-phase changes
/// move handlers off the engine, this helper is the canary.
@MainActor
private func findOnHoverNode(_ node: AttributeNode, engine: FocusEngine) -> AttributeNode? {
    if engine.hasHoverHandler(for: node.id) { return node }
    for child in node.children {
        if let found = findOnHoverNode(child, engine: engine) { return found }
    }
    return nil
}
