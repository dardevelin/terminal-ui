import Testing
@testable import TerminalUI

// `FocusEngine.rebuildIndex` must validate the existing
// `keyboardFocusID` against the new `nodeIndex`. Page transitions
// (sidebar click → state.selectedIndex change → graph rebuild from
// a different view) leave the old NodeID dangling: it doesn't
// resolve in the new index, so `routeKeyEvent` walks a stale node
// reference.
//
// Fix contract: after rebuildIndex completes, if `keyboardFocusID`
// is set but not present in the new `nodeIndex`, it must be cleared
// to nil. `routeKeyEvent` returns false on nil — a clean fallback
// the runtime / `focusNext()` can recover from.

@Suite("FocusEngine — rebuildIndex revalidates keyboardFocusID")
@MainActor
struct FocusEngineRebuildValidationTests {

    @Test("Stale keyboardFocusID is cleared after rebuild from a different graph")
    func staleFocusIDClearedOnRebuild() {
        let engine = FocusEngine()

        // Build first graph: a focusable Text node, focus it.
        let firstGraph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            firstGraph.update(from: Text("first").focusable())
        }
        engine.rebuildIndex(root: firstGraph.root!)
        engine.focusNext()
        let firstFocusID = engine.keyboardFocusID
        #expect(firstFocusID != nil, "first graph focused")

        // Build a second, structurally different graph. The first
        // graph's NodeID is NOT present in the new tree.
        let secondGraph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            secondGraph.update(from: VStack {
                Text("second").focusable()
                Text("third").focusable()
            })
        }
        engine.rebuildIndex(root: secondGraph.root!)

        // The previous keyboardFocusID is now stale.
        // The fix: rebuildIndex must clear it.
        if let focused = engine.keyboardFocusID {
            // If still set, it MUST resolve in the new graph.
            // Cheapest validity check: walk the second graph for the ID.
            let resolved = nodeContains(focused, in: secondGraph.root!)
            #expect(resolved,
                    "keyboardFocusID after rebuild must resolve in the new tree (or be nil); was \(focused) which doesn't")
        }
        // (engine.keyboardFocusID == nil is also acceptable — the contract is "valid OR nil")
    }

    @Test("Valid keyboardFocusID survives rebuild that preserves the node")
    func validFocusIDSurvives() {
        let engine = FocusEngine()

        // Build a graph and focus its only focusable.
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: Text("only").focusable())
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        let focused = engine.keyboardFocusID

        // Rebuild from the same view shape — node identity is preserved.
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: Text("only").focusable())
        }
        engine.rebuildIndex(root: graph.root!)

        #expect(engine.keyboardFocusID == focused,
                "valid focus ID must survive a no-op rebuild")
    }

    @Test("RED — explicitly stale focus ID gets cleared on rebuild")
    func explicitlyStaleFocusIDIsCleared() {
        // Construct a focus engine, build a tree, then poison
        // `keyboardFocusID` to a NodeID that doesn't exist anywhere
        // in the tree. After rebuildIndex, the engine MUST clear it
        // (or at least leave it resolvable).
        let engine = FocusEngine()
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: VStack {
                Text("a").focusable()
                Text("b").focusable()
            })
        }
        // Poison keyboardFocusID with a fabricated path no node uses.
        // Path indices `[999, 999, 999]` are unreachable in any built tree.
        let fakeID = NodeID(path: [.index(999), .index(999), .index(999)])
        engine.keyboardFocusID = fakeID

        engine.rebuildIndex(root: graph.root!)

        // Contract: after rebuild, the focused ID must either
        // resolve in the new index or be nil.
        if let focused = engine.keyboardFocusID {
            let resolved = nodeContains(focused, in: graph.root!)
            #expect(resolved,
                    "after rebuild, keyboardFocusID must be valid OR nil; got \(focused) which doesn't resolve in the new tree")
        }
    }

    @Test("Arrow routes after stale-focus rebuild does not infinite-loop")
    func arrowRoutesAfterStaleFocusRebuild() {
        let engine = FocusEngine()
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: VStack {
                Text("a").focusable()
                Text("b").focusable()
            })
        }
        let fakeID = NodeID(path: [.index(999), .index(999), .index(999)])
        engine.keyboardFocusID = fakeID
        engine.rebuildIndex(root: graph.root!)

        // routeKeyEvent must not crash on the stale ID. It should
        // resolve to nil (nothing handled) or land on a real node.
        let result = engine.routeKeyEvent(KeyEvent(key: .down), root: graph.root)
        // We don't care whether it returns true/false — only that it
        // returns at all without crashing. (Test passes by reaching
        // this assertion.)
        _ = result
    }

    @Test("Arrow nav recovers gracefully after stale-focus reset")
    func arrowNavRecoversAfterReset() {
        let engine = FocusEngine()

        // Initial graph + focus.
        let graphA = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graphA.update(from: Text("A").focusable())
        }
        engine.rebuildIndex(root: graphA.root!)
        engine.focusNext()

        // Switch graph; focus ID becomes stale.
        let graphB = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graphB.update(from: VStack {
                Text("B1").focusable()
                Text("B2").focusable()
            })
        }
        engine.rebuildIndex(root: graphB.root!)

        // Arrow nav after rebuild: focusNext should select FIRST focusable
        // in the new tree, not crash or get stuck on the stale ID.
        engine.focusNext()
        #expect(engine.keyboardFocusID != nil,
                "focusNext must land on a focusable from the new tree")
        let resolved = nodeContains(engine.keyboardFocusID!, in: graphB.root!)
        #expect(resolved, "focused ID must resolve in the new tree")
    }
}

@MainActor
private func nodeContains(_ id: NodeID, in root: AttributeNode) -> Bool {
    if root.id == id { return true }
    for child in root.children {
        if nodeContains(id, in: child) { return true }
    }
    return false
}
