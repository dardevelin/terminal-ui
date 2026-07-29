import Testing
@testable import TerminalUI

// A `ScrollView` states how tall it wants to be, and two parents ask in
// different ways:
//
//   * A flex parent (VStack, HStack) never asks — it hands the scroll view
//     whatever height its siblings leave, which is why a scroll view fills a
//     screen. That answer is `isVFlexChild`'s, not the measurer's.
//   * A content-sizing parent (`.frame(width:)`, a ZStack) *does* ask, and
//     sizes itself to the answer.
//
// Reporting "0 — you decide" served only the first, so a scroll view under a
// content-sizing parent collapsed to an empty box: its content was measured,
// laid out and rendered into a viewport of zero rows.
//
// The flex answer has its own gap: it was read off the child's node kind, so
// it stopped at the first thing that wasn't a scroll view. A scroll view
// behind a `.border()`, or inside a composite view's `body` — which is what
// every `Form` now is — looked like ordinary content, took its full natural
// height, and painted over its siblings.

@MainActor
private func render(_ view: some TerminalView, width: Int = 24, height: Int = 8) -> [String] {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    var env = EnvironmentValues()
    env.terminalSize = TerminalSize(cols: width, rows: height)
    GraphContext.$currentEnvironment.withValue(env) {
        graph.update(from: view)
        guard let root = graph.root else { return }
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<buffer.height).map { y in
        (0..<buffer.width).map { x in String(buffer[x, y].character) }.joined()
    }
}

@MainActor
private final class Model {
    var flag = false
    var binding: Binding<Bool> { Binding(get: { self.flag }, set: { self.flag = $0 }) }
}

/// Short content under a parent that sizes itself to what its child reports.
/// `.frame(width:)` fixes one dimension and leaves the other to the child, so
/// the height that reaches the enclosing stack is the measured one.
private struct MeasuredScroll: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("header")
            ScrollView(.vertical) {
                VStack {
                    Text("alpha")
                    Text("beta")
                }
            }
            .frame(width: 12)
            Spacer()
        }
    }
}

private struct BorderedScrollAboveFooter: TerminalView {
    var body: some TerminalView {
        VStack {
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(Array(0..<40), id: \.self) { index in
                        Text("row-\(index)")
                    }
                }
            }
            .border()
            Text("footer")
        }
    }
}

private struct ScrollAboveFooter: TerminalView {
    var body: some TerminalView {
        VStack {
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(Array(0..<40), id: \.self) { index in
                        Text("row-\(index)")
                    }
                }
            }
            Text("footer")
        }
    }
}

private struct FormAboveFooter: TerminalView {
    let isOn: Binding<Bool>

    var body: some TerminalView {
        VStack {
            Form {
                ForEachWithID(Array(0..<40), id: \.self) { index in
                    Toggle("Row \(index)", isOn: isOn)
                }
            }
            Text("footer")
        }
    }
}

@Suite("ScrollView — sizing under a content-sizing parent")
@MainActor
struct ScrollViewSizingTests {

    @Test("a measured ScrollView draws its content")
    func measuredScrollViewDrawsContent() {
        let rendered = render(MeasuredScroll()).joined(separator: "\n")
        #expect(rendered.contains("alpha"))
        #expect(rendered.contains("beta"))
    }

    @Test("a measured ScrollView is as tall as its content")
    func measuredScrollViewSizesToContent() {
        let rendered = render(MeasuredScroll())
        let alpha = rendered.firstIndex { $0.contains("alpha") }
        let beta = rendered.firstIndex { $0.contains("beta") }
        #expect(alpha == 1, "content starts on the row after the header")
        #expect(beta == 2, "and the second row is not squeezed out")
    }
}

@Suite("ScrollView — flexibility survives composition")
@MainActor
struct ScrollViewFlexibilityTests {

    @Test("a ScrollView yields the last row to its sibling")
    func scrollViewLeavesRoomForSibling() {
        let rendered = render(ScrollAboveFooter())
        #expect(rendered.last?.contains("footer") == true)
        #expect(rendered.first?.contains("row-0") == true)
    }

    // A border draws around the space its child was given; it does not decide
    // how much that is.
    @Test("a bordered ScrollView yields the last row to its sibling")
    func borderedScrollViewLeavesRoomForSibling() {
        let rendered = render(BorderedScrollAboveFooter())
        #expect(rendered.last?.contains("footer") == true,
                "the border must not take the footer's row on its child's behalf")
        #expect(rendered.joined().contains("row-0"))
    }

    // `Form` composes a `ScrollView` inside its `body`, so a flexibility test
    // that reads only the child's node kind stops one step short of it — and a
    // settings screen under a title bar is the shape every app writes.
    @Test("a Form yields the last row to its sibling")
    func formLeavesRoomForSibling() {
        let model = Model()
        let rendered = render(FormAboveFooter(isOn: model.binding))
        #expect(rendered.last?.contains("footer") == true,
                "a Form taller than the stack must scroll, not paint over its siblings")
        #expect(rendered.first?.contains("Row 0") == true)
    }
}
