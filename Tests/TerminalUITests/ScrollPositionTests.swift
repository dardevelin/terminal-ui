import Testing
@testable import TerminalUI

// HYP-217 — `.scrollPosition(id:)` adjusts an enclosing ScrollView's
// offset to keep the descendant tagged with `.id(matching)` visible.
// Independent of keyboard focus.

private struct PinnedTargetView: TerminalView {
    let targetIndex: Int
    var body: some TerminalView {
        ScrollView(.vertical) {
            VStack {
                ForEach(Array(0..<20).map(IntID.init)) { box in
                    Text("row-\(box.id)").id(box.id)
                }
            }
        }
        .scrollPosition(id: targetIndex)
        .frame(width: 20, height: 5)
    }
}

private struct IntID: Identifiable {
    let id: Int
}

@Suite(".scrollPosition(id:) — explicit-target scroll")
@MainActor
struct ScrollPositionTests {

    @Test("Targeting a row past the visible window scrolls offset forward")
    func scrollsToTargetPastViewport() {
        // Build the graph at a target=15 (past visible 5-row window from top).
        let view = PinnedTargetView(targetIndex: 15)
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)

        // Stamp rects so adjustScrollForExplicitTarget has a viewport to
        // reason against. We fake the layout pass by giving the scroll
        // node a 5-row rect; the renderer normally does this during
        // layout but tests bypass that machinery.
        if let scrollNode = findScrollNode(graph.root!) {
            scrollNode.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        }

        GraphRenderer.adjustScrollForExplicitTarget(
            root: graph.root, viewportWidth: 20, viewportHeight: 5
        )

        guard let scrollNode = findScrollNode(graph.root!) else {
            Issue.record("expected a scroll node in the graph")
            return
        }
        // Target row is at content offset 15. Viewport is 5 rows. To
        // bring the row into view, scrollOffset must be > 0 (any value
        // that makes row 15 fall inside [offset, offset + 5)).
        #expect(scrollNode.scrollOffset > 0,
                "ScrollView offset should advance when target is below viewport")
        #expect(scrollNode.scrollOffset <= 15,
                "scrollOffset shouldn't overshoot the target row")
    }

    @Test("Nested category-grouped ForEach (Storybook-style) finds the target")
    func storybookShape() {
        struct CategoryView: TerminalView {
            let targetIndex: Int
            var body: some TerminalView {
                ScrollView(.vertical) {
                    VStack {
                        ForEach(Array(0..<3).map(IntID.init)) { category in
                            Text("category \(category.id)").bold()
                            ForEach(Array((category.id*10)..<((category.id+1)*10)).map(IntID.init)) { row in
                                Text("row \(row.id)").id(row.id)
                            }
                            Text(" ")
                        }
                    }
                }
                .scrollPosition(id: targetIndex)
                .frame(width: 20, height: 6)
            }
        }
        let view = CategoryView(targetIndex: 25)  // far down
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        if let scrollNode = findScrollNode(graph.root!) {
            scrollNode.rect = Rect(x: 0, y: 0, width: 20, height: 6)
        }
        GraphRenderer.adjustScrollForExplicitTarget(
            root: graph.root, viewportWidth: 20, viewportHeight: 6
        )
        guard let scrollNode = findScrollNode(graph.root!) else {
            Issue.record("expected scroll node"); return
        }
        // Target row 25 sits in category 2 (index ≥20). Each category emits
        // a header + 10 rows + spacer = 12 logical rows; row 25 is at content
        // y ≈ 12 + 12 + (25-20)+1 = 30. With viewport=6, offset should land
        // somewhere in [25, 30] (depending on size of target).
        #expect(scrollNode.scrollOffset > 0,
                "Storybook-shape ForEach with target in category 2 must scroll forward")
    }

    @Test("nil scrollPosition leaves offset untouched")
    func nilTargetDoesNothing() {
        struct ViewWithoutTarget: TerminalView {
            var body: some TerminalView {
                ScrollView(.vertical) {
                    VStack {
                        ForEach(Array(0..<20).map(IntID.init)) { box in
                            Text("row-\(box.id)").id(box.id)
                        }
                    }
                }
                .frame(width: 20, height: 5)
            }
        }
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: ViewWithoutTarget())
            }
        }
        engine.rebuildIndex(root: graph.root!)
        if let scrollNode = findScrollNode(graph.root!) {
            scrollNode.rect = Rect(x: 0, y: 0, width: 20, height: 5)
            scrollNode.scrollOffset = 3  // Pre-existing offset from prior interaction.
        }
        GraphRenderer.adjustScrollForExplicitTarget(
            root: graph.root, viewportWidth: 20, viewportHeight: 5
        )
        if let scrollNode = findScrollNode(graph.root!) {
            #expect(scrollNode.scrollOffset == 3,
                    "no .scrollPosition env → offset preserved")
        }
    }
}

private func findScrollNode(_ node: AttributeNode) -> AttributeNode? {
    if case .layout(let info) = node.kind, case .scroll = info.kind {
        return node
    }
    for child in node.children {
        if let found = findScrollNode(child) { return found }
    }
    return nil
}
