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

// HYP-91 — exercises each of the four FocusIndicatorStyle values by setting
// GraphContext.currentEnvironment, placing a known rect on a focused node, then
// inspecting which cells the focus pass wrote.

@Suite("FocusIndicatorStyle — keyboard focus rendering")
@MainActor
struct FocusIndicatorStyleTests {

    private func makeFocusedNode(rect: Rect) -> (AttributeNode, FocusEngine) {
        resetGraphContext()
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
        GraphContext.currentEnvironment = env
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1].character == "▎")
        // First cell of focused rect is untouched
        #expect(buffer[3, 1] == Cell.empty)
    }

    @Test(".bar draws bar at rect.x (inside focused rect)")
    func barDrawsInside() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .bar
        GraphContext.currentEnvironment = env
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[3, 1].character == "▎")
        // Cell outside left edge is untouched
        #expect(buffer[2, 1] == Cell.empty)
    }

    @Test(".prefix leaves the framework pass silent")
    func prefixDrawsNothing() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .prefix
        GraphContext.currentEnvironment = env
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1] == Cell.empty)
        #expect(buffer[3, 1] == Cell.empty)
    }

    @Test(".none leaves the framework pass silent")
    func noneDrawsNothing() {
        let (root, engine) = makeFocusedNode(rect: Rect(x: 3, y: 1, width: 5, height: 1))
        var env = EnvironmentValues()
        env.focusIndicatorStyle = .none
        GraphContext.currentEnvironment = env
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
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
        GraphContext.currentEnvironment = env
        var buffer = CellBuffer(width: 10, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1].character == "▎")
        #expect(buffer[2, 2].character == "▎")
        #expect(buffer[2, 3].character == "▎")
        #expect(buffer[2, 4] == Cell.empty)
    }
}
