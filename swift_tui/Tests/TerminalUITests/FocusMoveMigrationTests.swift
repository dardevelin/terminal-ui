import Testing
@testable import TerminalUI

// Arrow navigation dispatches through `FocusableContainer` for every
// container kind, not just splits. These pin the behaviours the previous
// LayoutKind-matching path guaranteed, so the unified engine cannot quietly
// regress them:
//
//   * Arrows stay inside their stack. User directive 2026-04-18: "arrow down
//     on an element that has the focus shouldn't move focus out of it, tab is
//     the focus changer, unless marked as allow." Splits are the deliberate
//     exception — an i3 tree is meant to be traversed edge to edge.
//   * Arrows never tunnel past a perpendicular stack.
//   * `.focusScope` clamps arrows to the scope, and a wrong-axis arrow inside
//     a scope does not fall through to Tab order.
//   * Composite views (Button, TextInput) whose bodies introduce their own
//     wrapping stack stay navigable. This is the case a child-based walk
//     breaks if it stops at the first same-axis ancestor: the wrapper holds
//     exactly one focusable, so the walk has to keep climbing.

@MainActor
private func focusHarness(on graph: AttributeGraph, focus index: Int) -> (FocusEngine, [AttributeNode]) {
    let engine = FocusEngine()
    engine.rebuildIndex(root: graph.root!)
    let focusables = engine.collectFocusables(graph.root!)
    engine.keyboardFocusID = focusables[index].id
    return (engine, focusables)
}

@Suite("Directional focus — stacks traverse through FocusableContainer")
@MainActor
struct FocusMoveStackTests {

    @Test("down moves to the next focusable in a VStack")
    func downMovesWithinVStack() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("a").focusable()
            Text("b").focusable()
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        #expect(engine.move(.down, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("right moves to the next focusable in an HStack")
    func rightMovesWithinHStack() {
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("a").focusable()
            Text("b").focusable()
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        #expect(engine.move(.right, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("a stack edge blocks rather than escaping to the parent")
    func stackEdgeStaysPut() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("a").focusable()
            Text("b").focusable()
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 1)

        // Last child: the directive says stay, so this must not bubble.
        #expect(engine.move(.down, root: graph.root!) == .blocked)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("arrows do not tunnel past a perpendicular stack")
    func perpendicularStackBlocks() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("above").focusable()
            HStack {
                Text("a").focusable()
                Text("b").focusable()
            }
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 1)  // "a", inside the HStack

        // Up would reach "above" only by tunnelling out of the HStack.
        #expect(engine.move(.up, root: graph.root!) == .blocked)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("non-focusable siblings are skipped, not selected")
    func skipsNonFocusableSiblings() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("a").focusable()
            Text("decoration")
            Text("b").focusable()
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        // A child-based walk that returns every child would land on the
        // decoration node, which cannot hold focus.
        #expect(engine.move(.down, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("composite views whose bodies wrap themselves stay navigable")
    func compositeViewsKeepClimbing() {
        // Button's body introduces its own VStack-shaped wrapper holding a
        // single focusable. Stopping at that wrapper would make every Button
        // an arrow-navigation dead end.
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Button("first") {}
            Button("second") {}
        })
        let (engine, focusables) = focusHarness(on: graph, focus: 0)
        #expect(focusables.count == 2, "each Button contributes one focusable")

        #expect(engine.move(.down, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("a focused node with no container ancestor reports unhandled")
    func noContainerIsUnhandled() {
        let graph = AttributeGraph()
        graph.update(from: Text("alone").focusable())
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        // Nothing claimed the direction — the caller may fall back to Tab
        // order when the app opted into cross-stack arrows.
        #expect(engine.move(.down, root: graph.root!) == .unhandled)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }
}

@Suite("Directional focus — scopes clamp arrows")
@MainActor
struct FocusMoveScopeTests {

    /// VStack { HStack{A B}.focusScope("top"); HStack{C D}.focusScope("bot") }
    private func scopedLayout() -> AttributeGraph {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            HStack {
                Text("a").focusable()
                Text("b").focusable()
            }.focusScope("top")
            HStack {
                Text("c").focusable()
                Text("d").focusable()
            }.focusScope("bot")
        })
        return graph
    }

    @Test("right moves within a scope")
    func rightWithinScope() {
        let graph = scopedLayout()
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        #expect(engine.move(.right, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("right at a scope edge does not cross into the next scope")
    func rightStopsAtScopeEdge() {
        let graph = scopedLayout()
        let (engine, focusables) = focusHarness(on: graph, focus: 1)  // B, last in "top"

        #expect(engine.move(.right, root: graph.root!) == .blocked)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("left at a scope start stays put")
    func leftStopsAtScopeStart() {
        let graph = scopedLayout()
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        #expect(engine.move(.left, root: graph.root!) == .blocked)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }

    @Test("a wrong-axis arrow inside a scope does not fall back to Tab order")
    func wrongAxisDoesNotLeakOutOfScope() {
        let graph = scopedLayout()
        let (engine, focusables) = focusHarness(on: graph, focus: 0)

        // Down is the wrong axis for the HStack holding A. Reporting
        // `.unhandled` would let the caller Tab-fall-back and leak to C.
        #expect(engine.move(.down, root: graph.root!) == .blocked)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }

    @Test("Tab still crosses scopes")
    func tabCrossesScopes() {
        let graph = scopedLayout()
        let (engine, focusables) = focusHarness(on: graph, focus: 1)  // B, end of "top"

        engine.focusNext()
        #expect(engine.keyboardFocusID == focusables[2].id)  // C, start of "bot"
    }
}

@Suite("Directional focus — splits stay permeable")
@MainActor
struct FocusMoveSplitTests {

    @Test("a split declares itself permeable; a stack does not")
    func splitEscapesStackContains() {
        // Splits are the deliberate counterpart to stacks: an i3 tree is meant
        // to be traversed edge to edge, so a split's boundary bubbles instead
        // of blocking. Pinned here so the stack-side containment cannot be
        // widened to every container by accident, nor the reverse.
        let split = AttributeNode(
            id: NodeID.root.appending(.index(0)),
            kind: .layout(LayoutInfo(kind: .split(.vertical)))
        )
        #expect(split.traversalGeometry.isPermeable,
                "splits must remain permeable at their edges")

        let stack = AttributeNode(
            id: NodeID.root.appending(.index(1)),
            kind: .layout(LayoutInfo(kind: .vstack))
        )
        #expect(!stack.traversalGeometry.isPermeable,
                "stacks contain arrows per the arrows-stay-inside directive")
    }
}
