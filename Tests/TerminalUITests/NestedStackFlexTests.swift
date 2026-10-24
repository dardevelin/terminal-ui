import Testing
@testable import TerminalUI

// SwiftUI: a stack holding a view that takes what it is offered takes what
// it is offered itself. An HStack with a Spacer in it, nested in another
// HStack, stayed at its natural width, so the Spacer had nothing to grow
// into and whatever followed it never reached the edge — a row's trailing
// button, a file's counts. A Spacer in a VStack stretches only along the
// VStack, so it does not make the VStack wide.

@MainActor
private func row(_ view: some TerminalView, width: Int = 30) -> String {
    let graph = AttributeGraph()
    graph.update(from: view)
    var buffer = CellBuffer(width: width, height: 2)
    let rect = Rect(x: 0, y: 0, width: width, height: 2)
    Layout.measureAndPlace(graph: graph.root!, in: rect)
    GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    return buffer.text(row: 0)
}

@Suite("A stack takes the width a flexible child would")
@MainActor
struct NestedStackFlexTests {

    @Test func anHStackWithASpacerReachesTheEdgeInsideAnotherHStack() {
        let text = row(HStack(spacing: 1) {
            Text(">")
            HStack(spacing: 0) {
                Text("path")
                Spacer()
                Text("[end]")
            }
        })
        #expect(text.count == 30 && text.hasSuffix("[end]"), "\(text)")
    }

    @Test func aVStackWithOnlyAVerticalSpacerStaysNarrowInAnHStack() {
        let text = row(HStack(spacing: 1) {
            VStack(spacing: 0) {
                Text("left")
                Spacer()
            }
            Text("right")
        })
        #expect(text == "left right", "\(text)")
    }
}
