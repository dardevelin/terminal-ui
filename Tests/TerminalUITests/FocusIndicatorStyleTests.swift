import Testing
@testable import TerminalUI

// exercises each of the four FocusIndicatorStyle values by setting
// GraphContext.currentEnvironment, placing a known rect on a focused node, then
// inspecting which cells the focus pass wrote.

@Suite("FocusIndicatorStyle — keyboard focus rendering")
@MainActor
struct FocusIndicatorStyleTests {

    private func makeFocusedNode(rect: Rect) -> (AttributeNode, FocusEngine) {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("x") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[0].rect = rect
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[0].id
        return (root, engine)
    }

    @Test(".overlay draws bar at rect.x - 1 (outside focused rect)")
    func overlayDrawsOutside() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .overlay
        var buffer = CellBuffer(width: 20, height: 5)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        }
        #expect(buffer[2, 1].character == "▎")
        // First cell of focused rect is untouched
        #expect(buffer[3, 1] == Cell.empty)
    }

    @Test(".bar draws bar at rect.x (inside focused rect)")
    func barDrawsInside() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .bar
        var buffer = CellBuffer(width: 20, height: 5)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        }
        #expect(buffer[3, 1].character == "▎")
        // Cell outside left edge is untouched
        #expect(buffer[2, 1] == Cell.empty)
    }

    @Test(".prefix leaves the framework pass silent")
    func prefixDrawsNothing() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .prefix
        var buffer = CellBuffer(width: 20, height: 5)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        }
        #expect(buffer[2, 1] == Cell.empty)
        #expect(buffer[3, 1] == Cell.empty)
    }

    @Test(".none leaves the framework pass silent")
    func noneDrawsNothing() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .none
        var buffer = CellBuffer(width: 20, height: 5)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        }
        #expect(buffer[2, 1] == Cell.empty)
        #expect(buffer[3, 1] == Cell.empty)
    }

    @Test("default environment falls back to .overlay")
    func defaultIsOverlay() {
        #expect(EnvironmentValues().focusIndicatorStyle == .overlay)
    }

    @Test(".bar spans multiple rows when rect.height > 1")
    func barMultiRow() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 2, y: 1, width: 4, height: 3))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .bar
        var buffer = CellBuffer(width: 10, height: 5)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        }
        #expect(buffer[2, 1].character == "▎")
        #expect(buffer[2, 2].character == "▎")
        #expect(buffer[2, 3].character == "▎")
        #expect(buffer[2, 4] == Cell.empty)
    }
}

// Focus must never be nowhere. The overlay bar draws one cell to the left of
// the focused view, and a view flush against the left edge of the screen has
// no such cell — so the indicator was dropped and the user got a Tab that
// appeared to do nothing. In a sidebar-and-detail layout that is exactly the
// stop *outside* the detail pane, so Tab out of a form read as a form that
// traps Tab.
//
// A view one cell in was dropped too, by an off-by-one: column 0 is a real
// cell, and `drawX > 0` refused to use it.

@Suite("Focus indicator — views at the left edge")
@MainActor
struct FocusIndicatorLeftEdgeTests {

    private func indicatorColumns(_ buffer: CellBuffer) -> [Int] {
        (0..<buffer.width).filter { x in
            (0..<buffer.height).contains { y in
                buffer[x, y].character == "▎" || buffer[x, y].character == "┆"
            }
        }
    }

    @MainActor
    private func draw(_ view: some TerminalView, width: Int = 20, height: Int = 4) -> CellBuffer {
        let graph = AttributeGraph()
        let engine = FocusEngine()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root)
        }
        return buffer
    }

    // Marked, and still readable. Drawing the bar over the first column would
    // cost the row its first character — the row reading `Account` rendered as
    // `▎ccount` — so the edge case inverts that cell instead of replacing it.
    @Test("a focusable flush against the left edge is marked without losing text")
    func leftEdgeFocusableIsMarked() {
        let buffer = draw(VStack { Text("edge").focusable() })

        #expect(buffer[0, 0].character == "e", "the row still says what it said")
        #expect(buffer[0, 0].style.background != nil,
                "a Tab stop that shows nothing reads as a Tab that did nothing")
    }

    @Test("a focusable one cell in uses column zero")
    func oneCellInUsesColumnZero() {
        let buffer = draw(VStack { Text("inset").focusable() }.padding())
        #expect(indicatorColumns(buffer) == [0], "column 0 is a cell like any other")
    }
}

// `.focusIndicator(_:)` is written on a view, so it has to be read from the
// view it was written on. The indicator pass asked the ambient environment
// instead — the value a `.environment` modifier leaves behind for a whole
// frame — so the modifier only ever worked when applied globally. A pane that
// draws its own focus visual (a list with a ▸ cursor at column 0, where the
// framework's bar would have to overwrite the first character of every row to
// appear) could not opt out of the bar at all.

@Suite("Focus indicator — style is read from the focused view")
@MainActor
struct FocusIndicatorStyleScopeTests {

    private struct PrefixOwningRow: TerminalView {
        var body: some TerminalView {
            VStack {
                Text("▸ owns its cursor")
                    .focusable()
                    .focusIndicator(.prefix)
            }
        }
    }

    @Test("a view asking for .prefix is not given a bar")
    func prefixStyleSuppressesTheBar() {
        let graph = AttributeGraph()
        let engine = FocusEngine()
        var buffer = CellBuffer(width: 24, height: 3)
        let rect = Rect(x: 0, y: 0, width: 24, height: 3)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: PrefixOwningRow())
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root)
        }

        let text = (0..<buffer.height).map { y in
            (0..<buffer.width).map { x in String(buffer[x, y].character) }.joined()
        }.joined()
        #expect(!text.contains("▎"), "the view said it marks its own focus")
        #expect(text.contains("▸"), "and its own cursor survives")
    }
}
