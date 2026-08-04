import Testing
@testable import TerminalUI

// `VStack(alignment: .leading, spacing: 8)` is close to the most-typed line in
// SwiftUI, and it did not compile here at all: the stacks took a content
// closure and nothing else. Spacing had a workaround that cost a graph node
// per gap; alignment had none.
//
// Defaults deviate from SwiftUI deliberately — `.leading` / `.top` rather than
// `.center` — because every layout in this framework was written against
// top-left placement and a centring default would silently move all of them.
// The parameter is there for anyone who wants the other thing.

@MainActor
private func draw(_ view: some TerminalView, width: Int, height: Int) -> [String] {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<height).map { y in
        (0..<width).map { String(buffer[$0, y].character) }.joined()
    }
}

private func column(of needle: String, in rendered: [String]) -> Int? {
    for row in rendered {
        if let range = row.range(of: needle) {
            return row.distance(from: row.startIndex, to: range.lowerBound)
        }
    }
    return nil
}

private func rowIndex(of needle: String, in rendered: [String]) -> Int? {
    rendered.firstIndex { $0.contains(needle) }
}

@Suite("Stacks — alignment and spacing")
@MainActor
struct StackAlignmentSpacingTests {

    @Test("spacing leaves blank rows between children")
    func vstackSpacing() {
        let rendered = draw(VStack(spacing: 2) {
            Text("one")
            Text("two")
        }, width: 12, height: 6)

        #expect(rowIndex(of: "one", in: rendered) == 0)
        #expect(rowIndex(of: "two", in: rendered) == 3, "two blank rows between them")
    }

    @Test("spacing leaves blank columns between children")
    func hstackSpacing() {
        let rendered = draw(HStack(spacing: 3) {
            Text("ab")
            Text("cd")
        }, width: 20, height: 2)

        #expect(column(of: "ab", in: rendered) == 0)
        #expect(column(of: "cd", in: rendered) == 5, "two cells of text, then three of gap")
    }

    @Test("a VStack centres and trails its children on request")
    func vstackAlignment() {
        let centred = draw(VStack(alignment: .center) { Text("abc") }, width: 11, height: 2)
        let trailing = draw(VStack(alignment: .trailing) { Text("abc") }, width: 11, height: 2)

        #expect(column(of: "abc", in: centred) == 4, "(11 - 3) / 2")
        #expect(column(of: "abc", in: trailing) == 8, "flush against the right edge")
    }

    @Test("an HStack centres and bottoms its children on request")
    func hstackAlignment() {
        let centred = draw(HStack(alignment: .center) { Text("x") }, width: 6, height: 5)
        let bottom = draw(HStack(alignment: .bottom) { Text("x") }, width: 6, height: 5)

        #expect(rowIndex(of: "x", in: centred) == 2, "(5 - 1) / 2")
        #expect(rowIndex(of: "x", in: bottom) == 4)
    }

    @Test("a ZStack pins to the corner it was given")
    func zstackAlignment() {
        let rendered = draw(ZStack(alignment: .bottomTrailing) { Text("hi") },
                            width: 10, height: 4)

        #expect(rowIndex(of: "hi", in: rendered) == 3)
        #expect(column(of: "hi", in: rendered) == 8)
    }

    // Spacing is space the author reserved; a Spacer must divide what is left
    // after the gaps, not eat them.
    @Test("spacing survives a flexible sibling")
    func spacingWithFlexibleChild() {
        let rendered = draw(HStack(spacing: 2) {
            Text("L")
            Spacer()
            Text("R")
        }, width: 10, height: 1)

        #expect(column(of: "L", in: rendered) == 0)
        #expect(column(of: "R", in: rendered) == 9, "still flush right, gaps included")
    }

    // The defaults are the whole reason existing layouts keep rendering the
    // same; they are worth a test of their own.
    @Test("the default stack is unspaced and top-left")
    func defaultsUnchanged() {
        let rendered = draw(VStack {
            Text("one")
            Text("two")
        }, width: 12, height: 4)

        #expect(rowIndex(of: "one", in: rendered) == 0)
        #expect(rowIndex(of: "two", in: rendered) == 1, "no gap unless asked for")
        #expect(column(of: "one", in: rendered) == 0)
    }
}
