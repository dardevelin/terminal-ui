import Testing
@testable import TerminalUI

// Mouse-wheel scroll routes the synthetic arrow event to the
// focusable under the cursor (per MouseFocusPolicy.clickToLock), but
// `ScrollableScrollView.handleScrollKey` reads `engine.keyboardFocusID`
// to find the scroll-layout node — which is the SIDEBAR's focusable,
// NOT the routing target. The handler runs but resolves the wrong
// scroll node (or none at all) and returns `.ignored`. Wheel does
// nothing visible.
//
// Live-diagnose against Storybook page 5 (ScrollView):
//   * Tab-to-focus then wheel → scrolls (3 rows / wheel-down).
//   * Hover over preview without Tab + wheel → no movement.
//
// Both paths should scroll. The fix: route the synthetic arrow such
// that the handler resolves its *owning* scroll node, not the global
// keyboard-focused one.

@Suite("Wheel routes to hover target's scroll node, not keyboard focus")
@MainActor
struct WheelRoutingTargetTests {

    /// Build a graph with a focusable sidebar AND a focusable
    /// scrollable ScrollView containing scrollable content. With the
    /// sidebar keyboard-focused, route a synthetic Down arrow via
    /// `routeKeyEvent(_:root:startingFrom:)` to the ScrollView's
    /// focusable. The ScrollView's scrollOffset must advance.
    @Test("wheel-down via routeKeyEvent(startingFrom:) advances the target's scrollOffset")
    func wheelTargetAdvancesItsOwnScroll() {
        // Graph: HStack { sidebar=focusable, ScrollView(.vertical){VStack{20 rows}}.scrollable() }
        let view = HStack {
            Text("sidebar").focusable()
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(0..<20, id: \.self) { i in Text("row \(i)") }
                }
            }
            .scrollable()
            .frame(height: 5)
        }

        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)

        // Render once so node rects are populated (handleScrollKey
        // reads the scroll layout's rect to compute pageStep + max).
        var buffer = CellBuffer(width: 60, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 60, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Find the ScrollView's focusable (added by .scrollable()) AND
        // the keyboard focusable (the sidebar Text). Both are in the
        // engine's index after rebuildIndex.
        var sidebarID: NodeID? = nil
        var scrollableFocusableID: NodeID? = nil
        var scrollLayoutNode: AttributeNode? = nil
        func walk(_ n: AttributeNode) {
            if n.isFocusable {
                if case .layout = n.kind { /* skip layouts */ }
                // Sidebar is the FIRST focusable (Text wrapped in .focusable()).
                // ScrollableScrollView's focusable wraps the .scroll layout.
                if sidebarID == nil {
                    sidebarID = n.id
                } else {
                    scrollableFocusableID = n.id
                }
            }
            if case .layout(let info) = n.kind, case .scroll = info.kind {
                scrollLayoutNode = n
            }
            for child in n.children { walk(child) }
        }
        walk(graph.root!)

        guard let sidebarID, let scrollableFocusableID, let scrollLayoutNode else {
            Issue.record("test setup failed to locate sidebar / scrollable / scroll-layout nodes")
            return
        }

        // Set keyboard focus to the SIDEBAR (the regression scenario).
        engine.keyboardFocusID = sidebarID
        let initialOffset = scrollLayoutNode.scrollOffset
        #expect(initialOffset == 0, "scrollOffset starts at 0; got \(initialOffset)")

        // Now simulate the wheel routing path: dispatch a synthetic
        // .down arrow via routeKeyEvent(...startingFrom: scrollableFocusableID).
        // `handleScrollKey` runs, must mutate scrollOffset of the
        // ScrollView IT belongs to (not the sidebar's tree).
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                _ = engine.routeKeyEvent(KeyEvent(key: .down),
                                         root: graph.root!,
                                         startingFrom: scrollableFocusableID)
            }
        }

        let afterOffset = scrollLayoutNode.scrollOffset
        #expect(afterOffset > initialOffset,
                "wheel-routed Down at the ScrollView's focusable must advance ITS scrollOffset; before=\(initialOffset) after=\(afterOffset)")
    }
}
