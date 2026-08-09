import Testing
@testable import TerminalUI

// A `GeometryReader` sizes itself to whatever it is offered — that is its
// entire reason to exist. The stack flex pass did not know that: it had no
// entry in the flexibility vocabulary, so a stack measured it like a fixed
// child. Any view whose body reads its size through a GeometryReader
// (`TreeView` does) then reported the *parent's* height back as its own,
// and the stack laid out siblings + child past its own rect.
//
// Found live in the GitClient example: the files pane is
// `VStack { Text; Divider; TreeView }.padding(1).border()`, and the tree
// overflowed through the padding row onto the bottom border, where the
// focus indicator faithfully marked the overflowed rows — rendering `╰▎──`.

@MainActor
private func draw(_ view: some TerminalView, width: Int, height: Int) -> ([String], AttributeGraph) {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    let rendered = (0..<height).map { y in
        (0..<width).map { String(buffer[$0, y].character) }.joined()
    }
    return (rendered, graph)
}

/// Every stack keeps its children inside its own rect. Returns the first
/// violation found, or nil.
@MainActor
private func firstStackOverflow(_ node: AttributeNode) -> String? {
    if case .layout(let info) = node.kind,
       info.kind == .vstack || info.kind == .hstack {
        let bottom = node.rect.y + node.rect.height
        let right = node.rect.x + node.rect.width
        for child in node.children {
            if child.rect.y + child.rect.height > bottom || child.rect.x + child.rect.width > right {
                return "stack \(node.rect) contains child \(child.kind) at \(child.rect)"
            }
        }
    }
    for child in node.children {
        if let violation = firstStackOverflow(child) { return violation }
    }
    return nil
}

private struct Node: Identifiable {
    let id: Int
    var children: [Node]?
}

@MainActor
@Suite struct GeometryReaderFlexTests {

    @Test func geometryReaderChildTakesRemainingHeightNotFullHeight() {
        let view = VStack {
            Text("header")
            GeometryReader { size in
                Text("h=\(size.height)")
            }
        }
        let (rendered, _) = draw(view, width: 12, height: 6)
        // One fixed row above leaves 5 for the reader, not 6.
        #expect(rendered[1].hasPrefix("h=5"))
    }

    @Test func geometryReaderChildTakesRemainingWidthInHStack() {
        let view = HStack {
            Text("ab")
            GeometryReader { size in
                Text("w=\(size.width)")
            }
        }
        let (rendered, _) = draw(view, width: 10, height: 3)
        #expect(rendered[0].contains("w=8"))
    }

    /// A component that declares its own row window is not greedy: the
    /// Storybook List preview (`List(…, visibleCount: 5)` in a bordered box,
    /// with a Spacer below) must size the box to its 5 rows, not split the
    /// remaining space with the Spacer and crush the list.
    @Test func listWithExplicitVisibleCountMeasuresFixed() {
        let items = (1...8).map { Node(id: $0, children: nil) }
        let view = VStack {
            Text("above")
            List(items, visibleCount: 5) { node in
                Text("item \(node.id)")
            }
            .padding(1)
            .border(.rounded)
            Spacer()
        }
        let (rendered, _) = draw(view, width: 30, height: 20)
        let top = rendered.firstIndex { $0.contains("╭") }
        let bottom = rendered.firstIndex { $0.contains("╰") }
        #expect(top != nil && bottom != nil)
        if let top, let bottom {
            // 5 content rows + padding (2) + border (2) = 9 rows outer.
            #expect(bottom - top + 1 == 9,
                    "box should wrap its declared 5 rows, got \(bottom - top + 1)")
        }
        #expect(rendered.contains { $0.contains("item 1") })
    }

    /// The GitClient pane, reduced: the tree must not punch through the
    /// padding row onto the bottom border.
    @Test func treeViewInPaddedBorderedVStackStaysInsideItsStack() {
        let items = (1...4).map { Node(id: $0, children: nil) }
        let view = VStack {
            Text("Files")
            Divider()
            TreeView(items, children: \.children) { node in
                Text("row \(node.id)")
            }
        }
        .padding(1)
        .border(.rounded)

        let (rendered, graph) = draw(view, width: 32, height: 21)
        #expect(rendered[20].hasPrefix("╰"))
        #expect(firstStackOverflow(graph.root!) == nil)
    }
}

@MainActor
@Suite struct TabViewBarLayoutTests {
    /// The tab bar measures its width through a GeometryReader; when readers
    /// joined the flex vocabulary, the BAR became the greedy child and shoved
    /// every tab's content to the bottom of the view. The bar is one row by
    /// declaration — content must start right under it.
    @Test func tabContentStartsDirectlyUnderTheBar() {
        let view = TabView(selection: Binding(get: { 0 }, set: { _ in })) {
            Tab("One") { Text("first page content") }
            Tab("Two") { Text("second page content") }
        }
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 40, height: 10)
        let rect = Rect(x: 0, y: 0, width: 40, height: 10)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        let rows = (0..<10).map { y in (0..<40).map { String(buffer[$0, y].character) }.joined() }
        #expect(rows[0].contains("One"))
        #expect(rows.prefix(3).contains { $0.contains("first page content") },
                "content should sit directly under the bar, got rows: \(rows)")
    }
}
