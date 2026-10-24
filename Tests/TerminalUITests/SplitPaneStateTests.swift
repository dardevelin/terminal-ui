import Testing
@testable import TerminalUI

// A SplitView rebuilt its panes from nothing on every update, so a pane's
// @TerminalState went back to its initial value whenever anything above the
// split drew again — and resizing, which assigns new ratios, reset every
// pane. Panes are now updated in place, by position, as a stack's children
// are.

private struct Counter: TerminalView {
    @TerminalState var count = 0
    var body: some TerminalView {
        let binding = $count
        return Text("count \(count)").onClick { _, _ in binding.wrappedValue += 1 }
    }
}

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let state: SplitState

    init(_ state: SplitState) {
        self.state = state
    }

    @discardableResult
    func frame() -> String {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: SplitView(state: state)) }
        var buffer = CellBuffer(width: 30, height: 1)
        let rect = Rect(x: 0, y: 0, width: 30, height: 1)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: graph.root!)
        return (0..<30).map { String(buffer[$0, 0].character) }.joined()
    }

    func click(_ x: Int) {
        engine.handleMouseClick(x: x, y: 0, root: graph.root)
    }
}

private func divider(_ row: String) -> Int {
    row.firstIndex(of: "│").map { row.distance(from: row.startIndex, to: $0) } ?? -1
}

private func panes(_ ratios: [Double]) -> SplitNode {
    .split(axis: .horizontal, children: [.leaf(Counter()), .leaf(Text("right"))], ratios: ratios)
}

@Suite("A pane keeps its state")
@MainActor
struct SplitPaneStateTests {

    @Test func aPaneKeepsItsStateWhenTheSplitDrawsAgain() {
        let screen = Screen(SplitState(root: panes([0.5, 0.5])))
        screen.frame()
        screen.click(1)
        #expect(screen.frame().hasPrefix("count 1"))
    }

    @Test func aPaneKeepsItsStateWhenTheSplitIsResized() {
        let screen = Screen(SplitState(root: panes([0.5, 0.5])))
        screen.frame()
        screen.click(1)
        let before = screen.frame()
        screen.state.root = panes([0.7, 0.3])
        let after = screen.frame()
        #expect(after.hasPrefix("count 1"))
        #expect(divider(after) > divider(before), "the new ratios lay the panes out")
    }

    @Test func aPaneOfAnotherKindIsBuiltAfresh() {
        let screen = Screen(SplitState(root: panes([0.5, 0.5])))
        screen.frame()
        screen.click(1)
        screen.frame()
        screen.state.root = .split(axis: .horizontal,
                                   children: [.leaf(Text("left")), .leaf(Text("right"))],
                                   ratios: [0.5, 0.5])
        #expect(screen.frame().hasPrefix("left"))
    }
}
