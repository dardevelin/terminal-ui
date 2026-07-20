import Testing
@testable import TerminalUI

// Mouse wheel on a HOVERED bare ScrollView — no `.scrollable()`,
// no enclosing `.focusable()` — should still scroll the viewport.
//
// This is SwiftUI parity: the wheel is owned by the deepest scroll
// region under the cursor, regardless of whether anything focusable
// is reachable inside it. A sidebar that uses `.scrollPosition(id:)`
// for keyboard-driven selection is exactly this case — the user's
// keyboard focus lives elsewhere (the bottom hint row), but they
// still expect mouse-wheel over the sidebar to advance its viewport.
//
// Pre-fix: `wheelTargetID` only finds focusables; bare ScrollView
// returns nil → wheel dropped on the floor.
//
// Post-fix: when no focusable is under the cursor, fall back to the
// deepest enclosing scroll-layout node and mutate its scrollOffset
// directly (skipping the focusable / routing path).

@Suite("Wheel routes to hovered scroll layout when no focusable is under cursor")
@MainActor
struct HoveredScrollViewWheelTests {

    /// Bare ScrollView (no `.scrollable()`) hovered with the wheel.
    /// Currently `wheelTargetID` returns nil → wheel dropped. After
    /// the fix, the framework should route wheel deltas to the
    /// hovered scroll layout's `scrollOffset` directly.
    @Test("wheel-down over a hovered bare ScrollView advances its scrollOffset")
    func wheelOverBareScrollViewScrolls() {
        // Graph: ScrollView(.vertical) { 20 rows }.
        // The render context's rect (30x5) becomes the ScrollView's
        // viewport directly — no .frame() wrapper, no focusable, no
        // .scrollable(). Mirrors a sidebar that uses ScrollView for
        // visual clipping and `.scrollPosition(id:)` for selection-
        // driven offset adjustment, but never opted into wheel.
        let view = ScrollView(.vertical) {
            VStack {
                ForEachWithID(0..<20, id: \.self) { i in Text("row \(i)") }
            }
        }

        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)

        // Render once so node rects are populated.
        var buffer = CellBuffer(width: 30, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 30, height: 5))
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
            }
        }

        // Locate the scroll layout node. It must exist — ScrollView
        // produces one — and its rect must cover the viewport.
        var scrollLayoutNode: AttributeNode? = nil
        func walk(_ n: AttributeNode) {
            if case .layout(let info) = n.kind, case .scroll = info.kind {
                scrollLayoutNode = n
                return
            }
            for child in n.children { walk(child) }
        }
        walk(graph.root!)

        guard let scrollLayoutNode else {
            Issue.record("test setup failed: no scroll layout node in graph")
            return
        }

        let viewport = scrollLayoutNode.rect
        #expect(viewport.height > 0, "scroll layout viewport must have height; got \(viewport)")

        let initialOffset = scrollLayoutNode.scrollOffset
        #expect(initialOffset == 0, "scrollOffset starts at 0; got \(initialOffset)")

        // Sanity: the existing focusable-based wheelTargetID returns
        // nil because there's no focusable in the tree.
        let target = engine.wheelTargetID(
            x: viewport.x + 1,
            y: viewport.y + 1,
            root: graph.root!,
            policy: .clickToLock
        )
        #expect(target == nil, "no focusable in tree → wheelTargetID is nil; got \(String(describing: target))")

        // The new fallback path: deepest scroll layout under cursor.
        // Should resolve to scrollLayoutNode.
        let scrollNode = engine.findScrollNodeAt(
            x: viewport.x + 1,
            y: viewport.y + 1,
            root: graph.root!
        )
        #expect(scrollNode?.id == scrollLayoutNode.id,
                "wheel-on-bare-ScrollView fallback must resolve the scroll layout under cursor")

        // Drive a wheel-down at the hovered point — the scroll
        // layout's offset must advance.
        engine.dispatchWheelToScrollNode(
            scrollLayoutNode,
            event: KeyEvent(key: .down)
        )

        let afterOffset = scrollLayoutNode.scrollOffset
        #expect(afterOffset > initialOffset,
                "wheel-down on hovered bare ScrollView must advance scrollOffset; before=\(initialOffset) after=\(afterOffset)")
    }

    /// When the cursor is over inert space (no scroll layout, no
    /// focusable), the fallback must return nil — wheel drops.
    @Test("wheel over inert space returns nil scroll node and does not crash")
    func wheelOverInertSpaceReturnsNil() {
        let view = Text("just text")

        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)

        var buffer = CellBuffer(width: 30, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 30, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        let scrollNode = engine.findScrollNodeAt(x: 5, y: 2, root: graph.root!)
        #expect(scrollNode == nil, "no scroll layout in tree → fallback returns nil")
    }

    /// Wheel over a horizontal-axis ScrollView: pressing wheel-right
    /// (mapped to `.right` arrow internally) advances horizontally.
    /// Confirms the axis-respecting dispatch matches `.scrollable()`.
    @Test("wheel over horizontal ScrollView advances horizontal offset")
    func wheelOverHorizontalScrollViewScrolls() {
        let view = ScrollView(.horizontal) {
            HStack {
                ForEachWithID(0..<20, id: \.self) { i in Text("col\(i)") }
            }
        }

        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)

        var buffer = CellBuffer(width: 10, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 3))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        var scrollLayoutNode: AttributeNode? = nil
        func walk(_ n: AttributeNode) {
            if case .layout(let info) = n.kind, case .scroll = info.kind {
                scrollLayoutNode = n; return
            }
            for child in n.children { walk(child) }
        }
        walk(graph.root!)
        guard let scrollLayoutNode else {
            Issue.record("test setup failed: no scroll layout"); return
        }

        let initial = scrollLayoutNode.scrollOffset
        engine.dispatchWheelToScrollNode(
            scrollLayoutNode,
            event: KeyEvent(key: .right)
        )
        #expect(scrollLayoutNode.scrollOffset > initial,
                "horizontal wheel-right must advance horizontal scrollOffset")
    }
}
