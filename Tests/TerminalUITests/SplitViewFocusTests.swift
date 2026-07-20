import Testing
@testable import TerminalUI

// A split pane holding nothing focusable is still somewhere the user can go.
// That is i3's "container without leaf widget" rule, and it is what makes a
// tiling layout usable without asking the author to wrap every pane in
// `.focusable()` — the same reasoning behind SwiftUI treating a list row as a
// focusable unit whether or not its content is.
//
// The rule is deliberately confined to containers whose children are *panes*.
// Applying it to ordinary stacks would turn every decorative `Text` in a
// VStack into a Tab stop, which is a different framework, not a refinement.
//
// Focusability is derived at collection time rather than stamped during graph
// construction: "has no focusable descendant" is not a construction-time fact,
// because a descendant can gain focus later when state flips an `if` branch.

@MainActor
private func indexed(_ view: some TerminalView) -> (FocusEngine, AttributeGraph) {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        var buffer = CellBuffer(width: 60, height: 20)
        GraphRenderer.render(
            graph.root!,
            into: &buffer,
            context: RenderContext(rect: Rect(x: 0, y: 0, width: 60, height: 20))
        )
        engine.rebuildIndex(root: graph.root!)
    }
    return (engine, graph)
}

@MainActor
private func twoEmptyPanes() -> SplitState {
    SplitState(root: .split(
        axis: .horizontal,
        children: [.leaf(Text("left")), .leaf(Text("right"))],
        ratios: [0.5, 0.5]
    ))
}

@Suite("SplitView focus — panes are focusable units")
@MainActor
struct SplitViewPaneFocusTests {

    @Test("panes with no focusable content are themselves focusable")
    func emptyPanesAreFocusable() {
        let (engine, graph) = indexed(SplitView(state: twoEmptyPanes()))
        let focusables = engine.collectFocusables(graph.root!)

        #expect(focusables.count == 2,
                "each pane is a focus target; got \(focusables.count)")
    }

    @Test("a pane holding a focusable yields the child, not the pane")
    func paneWithContentDoesNotDoubleCount() {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("plain")), .leaf(Button("go") {})],
            ratios: [0.5, 0.5]
        ))
        let (engine, graph) = indexed(SplitView(state: state))
        let focusables = engine.collectFocusables(graph.root!)

        // The empty pane contributes one unit; the pane holding a Button
        // contributes the Button alone. A pane that both is focusable and
        // contains a focusable would stop Tab twice in the same region.
        #expect(focusables.count == 2,
                "expected one unit per pane, not a pane plus its child; got \(focusables.count)")
    }

    @Test("arrow navigation moves between empty panes")
    func arrowsMoveBetweenEmptyPanes() {
        let (engine, graph) = indexed(SplitView(state: twoEmptyPanes()))
        let focusables = engine.collectFocusables(graph.root!)
        engine.keyboardFocusID = focusables[0].id

        #expect(engine.move(.right, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id)
        #expect(engine.move(.left, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }

    @Test("a pane added by mutating the tree becomes focusable")
    func mutatedTreeKeepsPanesFocusable() {
        // Focusability is derived, not stamped, so the rebuild path needs no
        // parallel marking pass. Pinned because "nothing to do here" is
        // exactly the kind of claim that rots.
        let state = twoEmptyPanes()
        let engine = FocusEngine()
        let graph = AttributeGraph()

        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: SplitView(state: state))
            state.root = .split(
                axis: .horizontal,
                children: [.leaf(Text("a")), .leaf(Text("b")), .leaf(Text("c"))],
                ratios: [0.34, 0.33, 0.33]
            )
            graph.update(from: SplitView(state: state))
            engine.rebuildIndex(root: graph.root!)
        }

        #expect(engine.collectFocusables(graph.root!).count == 3,
                "the pane added by the mutation must be reachable")
    }
}

@Suite("SplitView focus — granularity governs the rule")
@MainActor
struct SplitViewGranularityTests {

    @Test("leaf granularity drops empty panes from the focus order")
    func leafGranularitySkipsEmptyPanes() {
        let (engine, graph) = indexed(
            SplitView(state: twoEmptyPanes()).focusGranularity(.leaf)
        )

        #expect(engine.collectFocusables(graph.root!).isEmpty,
                "under .leaf only explicitly focusable descendants participate")
    }

    @Test("arrows skip empty panes under leaf granularity")
    func leafGranularitySkipsPanesForArrows() {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Button("a") {}), .leaf(Text("gap")), .leaf(Button("b") {})],
            ratios: [0.34, 0.33, 0.33]
        ))
        let (engine, graph) = indexed(SplitView(state: state).focusGranularity(.leaf))
        let focusables = engine.collectFocusables(graph.root!)
        #expect(focusables.count == 2, "only the two Buttons participate")

        engine.keyboardFocusID = focusables[0].id
        #expect(engine.move(.right, root: graph.root!) == .moved)
        #expect(engine.keyboardFocusID == focusables[1].id,
                "the middle pane holds nothing focusable and must be stepped over")
    }

    @Test("granularity applies on the first frame, before anything renders")
    func granularityAppliesBeforeFirstRender() {
        // The runtime rebuilds the focus index and auto-focuses *before* the
        // first frame is drawn, so a granularity read from render-stamped
        // environment would be nil exactly when the initially focused node is
        // chosen. Index without rendering, matching that order.
        let engine = FocusEngine()
        let graph = AttributeGraph()
        GraphContext.$currentFocusEngine.withValue(engine) {
            graph.update(from: SplitView(state: twoEmptyPanes()).focusGranularity(.leaf))
            engine.rebuildIndex(root: graph.root!)
        }

        #expect(engine.collectFocusables(graph.root!).isEmpty,
                "the author asked for .leaf; empty panes must not be focus targets")
    }

    @Test("ordinary stacks do not make their children focusable units")
    func stacksAreUnaffected() {
        let (engine, graph) = indexed(VStack {
            Text("one")
            Text("two")
        })

        // The rule is about panes. A VStack of labels has no focus targets.
        #expect(engine.collectFocusables(graph.root!).isEmpty,
                "decorative stack children must not become Tab stops")
    }

    @Test("container granularity can be requested for a stack explicitly")
    func stacksOptInViaEnvironment() {
        let (engine, graph) = indexed(
            VStack {
                Text("one")
                Text("two")
            }.focusGranularity(.container)
        )

        #expect(engine.collectFocusables(graph.root!).count == 2,
                "an explicit preference overrides the container's own default")
    }
}

@Suite("SplitView focus — panes inside a presented modal")
@MainActor
struct SplitViewModalContainmentTests {

    @Test("panes inside a modal stay reachable")
    func panesInsideModalAreTraversable() {
        // Containment is stamped per node and Tab traversal keeps only the
        // deepest contained level. A pane that is a focus unit rather than an
        // `.focusable()` leaf must still carry its depth, or a dialog built
        // from a split becomes unreachable.
        let (engine, graph) = indexed(
            Text("background").focusable()
                .modal(isPresented: true) {
                    SplitView(state: twoEmptyPanes())
                }
        )

        let contained = engine.collectFocusables(graph.root!)
            .filter { $0.containmentDepth > 0 }
        #expect(contained.count == 2,
                "both panes must be contained by the modal, not stranded at depth 0")
    }
}
