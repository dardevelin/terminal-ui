import Testing
@testable import TerminalUI

// `isFocused` was declared and documented but never set: no view could tell
// whether it held focus, so every input drew its cursor whether or not keys
// would reach it, and a prompt could not dim itself when focus left. A
// focusable node now tells its content whether it holds focus, and a focus
// change re-runs exactly the bodies that asked.

private struct Field: TerminalView {
    let name: String
    @TerminalEnvironment(\.isFocused) var isFocused

    var body: some TerminalView {
        Text((isFocused ? ">" : " ") + name)
    }
}

private struct Label: TerminalView {
    let name: String
    var body: some TerminalView { Text(name) }
}

@MainActor
private func focusables(in node: AttributeNode) -> [NodeID] {
    (node.isFocusable ? [node.id] : []) + node.children.flatMap { focusables(in: $0) }
}

@MainActor
private func rows(_ graph: AttributeGraph, focus: NodeID?, width: Int = 6, height: Int = 3) -> [String] {
    var env = EnvironmentValues()
    env.focusedID = focus
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(env) {
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<height).map { y in
        var line = String((0..<width).map { buffer[$0, y].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}

@MainActor
private func update(_ graph: AttributeGraph, focus: NodeID?, _ view: some TerminalView) {
    var env = EnvironmentValues()
    env.focusedID = focus
    GraphContext.$currentEnvironment.withValue(env) { _ = graph.update(from: view) }
}

@MainActor
private func moveFocus(_ graph: AttributeGraph, to focus: NodeID?) {
    var env = EnvironmentValues()
    env.focusedID = focus
    graph.focusMoved(to: focus)
    GraphContext.$currentEnvironment.withValue(env) { _ = graph.drain() }
}

@Suite("A view can read whether it holds focus")
@MainActor
struct FocusEnvironmentTests {

    private var form: some TerminalView {
        VStack(spacing: 0) {
            Field(name: "a").focusable()
            Field(name: "b").focusable()
            Label(name: "c")
        }
    }

    @Test func theFocusedFieldKnowsItIsFocused() {
        let graph = AttributeGraph()
        update(graph, focus: nil, form)
        let ids = focusables(in: graph.root!)
        moveFocus(graph, to: ids[0])
        #expect(rows(graph, focus: ids[0]) == [">a", " b", "c"])
    }

    @Test func movingFocusRerunsOnlyTheBodiesThatReadIt() {
        let graph = AttributeGraph()
        update(graph, focus: nil, form)
        let ids = focusables(in: graph.root!)
        moveFocus(graph, to: ids[0])
        graph.resetFrameStats()

        moveFocus(graph, to: ids[1])
        #expect(rows(graph, focus: ids[1]) == [" a", ">b", "c"])
        #expect(graph.bodyEvaluationCount == 2, "the field that lost focus and the one that gained it")
    }

    @Test func anUnchangedFocusRerunsNothing() {
        let graph = AttributeGraph()
        update(graph, focus: nil, form)
        let ids = focusables(in: graph.root!)
        moveFocus(graph, to: ids[0])
        graph.resetFrameStats()
        #expect(graph.focusMoved(to: ids[0]) == false)
        #expect(graph.bodyEvaluationCount == 0)
    }

    /// The case an input needs: content built for a width, inside the
    /// focusable, rebuilt during layout rather than by the update walk.
    @Test func focusReachesContentBuiltForAWidth() {
        let graph = AttributeGraph()
        update(graph, focus: nil, WidthReader { _ in Field(name: "w") }.focusable())
        let ids = focusables(in: graph.root!)
        moveFocus(graph, to: ids[0])
        #expect(rows(graph, focus: ids[0], height: 1) == [">w"])
        moveFocus(graph, to: nil)
        #expect(rows(graph, focus: nil, height: 1) == [" w"])
    }
}
