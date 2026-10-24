import Testing
@testable import TerminalUI

// A `Spacer` draws nothing, so the stacks skipped it when they placed their
// children, and it kept the rect the first layout pass gave every child: the
// whole stack. Hit testing searches the last child first, so a trailing
// spacer owned every point in its stack — the inspector named `Spacer` for a
// task row, a header, a detail pane. A spacer has the slot it takes.

@Suite("A Spacer owns only the space it takes")
@MainActor
struct SpacerHitTestTests {

    private func rendered(_ view: some TerminalView, width: Int, height: Int) -> AttributeGraph {
        let graph = AttributeGraph()
        graph.update(from: view)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        var buffer = CellBuffer(width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        return graph
    }

    private func isText(_ node: AttributeNode?) -> Bool {
        if case .primitive(.text) = node?.kind { return true }
        return false
    }

    private func isSpacer(_ node: AttributeNode?) -> Bool {
        if case .primitive(.spacer) = node?.kind { return true }
        return false
    }

    @Test func aRowAboveAVerticalSpacerIsTheRows() {
        let graph = rendered(VStack(spacing: 0) {
            Text("task")
            Spacer()
        }, width: 10, height: 6)
        #expect(isText(HitTest.nodeAt(x: 1, y: 0, root: graph.root)?.node))
        #expect(isSpacer(HitTest.nodeAt(x: 1, y: 4, root: graph.root)?.node))
    }

    @Test func aWordBeforeAHorizontalSpacerIsTheWords() {
        let graph = rendered(HStack(spacing: 0) {
            Text("task")
            Spacer()
        }, width: 12, height: 1)
        #expect(isText(HitTest.nodeAt(x: 1, y: 0, root: graph.root)?.node))
        #expect(isSpacer(HitTest.nodeAt(x: 9, y: 0, root: graph.root)?.node))
    }
}
