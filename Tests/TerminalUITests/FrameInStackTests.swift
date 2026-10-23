import Testing
@testable import TerminalUI

// `.frame(width:)` proposes an exact size, and a `.border()` outside it draws
// around that size. Inside a stack it did not: a stack hands every child the
// full extent of its cross axis, so the box was drawn at the stack's width and
// only the text inside reflowed. The user's report, verbatim (2026-05-06):
//
//   "the containers did not resize, it seems that the drawing of the borders
//    remained the same just the floating of text changed."
//
// The main axis was fixed by later layout work — a stack already allocates each
// child its measured extent along the axis it stacks on. The cross axis is what
// remained: width in a VStack, height in an HStack.

@MainActor
private func draw(_ view: some TerminalView, width: Int, height: Int) -> [String] {
    let buffer = renderedBuffer(view, width: width, height: height)
    return (0..<height).map { y in
        (0..<width).map { String(buffer[$0, y].character) }.joined()
    }
}

/// Width of the box drawn on `row`, corner to corner.
private func boxWidth(_ row: String) -> Int? {
    guard let start = row.firstIndex(of: "╭"), let end = row.firstIndex(of: "╮") else { return nil }
    return row.distance(from: start, to: end) + 1
}

private func boxRows(_ rendered: [String]) -> Int {
    rendered.filter { $0.contains("│") || $0.contains("╭") || $0.contains("╰") }.count
}

private struct HStackPanes: TerminalView {
    let left: Int
    let right: Int
    var body: some TerminalView {
        HStack {
            Text("left").frame(width: left, height: 3).border()
            Text("right").frame(width: right, height: 3).border()
        }
    }
}

private struct VStackPane: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("a").frame(width: 8, height: 1).border()
        }
    }
}

private struct FixedBesideFlex: TerminalView {
    var body: some TerminalView {
        HStack {
            Text("fix").frame(width: 8)
            Text("flex").flexible(.horizontal)
        }
    }
}

@Suite("`.frame` inside a stack")
@MainActor
struct FrameInStackTests {

    @Test("an HStack honours each child's width")
    func hstackHonoursWidth() {
        let rendered = draw(HStackPanes(left: 8, right: 14), width: 40, height: 6)
        // 8 and 14 of content, each inside its own two border cells.
        #expect(boxWidth(rendered[0]) == 10)
        #expect(rendered[0].dropFirst(10).contains("╭"))
    }

    @Test("changing a width moves the border")
    func widthChangeMovesTheBorder() {
        let narrow = draw(HStackPanes(left: 8, right: 14), width: 40, height: 6)
        let wide = draw(HStackPanes(left: 16, right: 14), width: 40, height: 6)
        #expect(boxWidth(narrow[0]) == 10)
        #expect(boxWidth(wide[0]) == 18, "the box tracks the frame, not the stack")
    }

    // The cross axis: an HStack stacks along x, so it was handing every child
    // the whole of y.
    @Test("an HStack honours a child's height")
    func hstackHonoursHeight() {
        let rendered = draw(HStackPanes(left: 8, right: 14), width: 40, height: 10)
        #expect(boxRows(rendered) == 5,
                "three rows of content between the top and bottom rules")
    }

    // The same on the other stack: a VStack stacks along y, so it was handing
    // every child the whole of x.
    @Test("a VStack honours a child's width")
    func vstackHonoursWidth() {
        let rendered = draw(VStackPane(), width: 40, height: 6)
        #expect(boxWidth(rendered[0]) == 10,
                "the box is drawn at the width the frame asked for, not the stack's")
    }

    // The behaviour that has to survive: a child with no fixed size still
    // takes what its siblings leave.
    @Test("a flexible sibling still expands around a fixed one")
    func flexExpandsAroundFixed() {
        let rendered = draw(FixedBesideFlex(), width: 30, height: 1)
        #expect(rendered[0].hasPrefix("fix"))
        #expect(rendered[0].contains("flex"), "the flexible child kept its space")
    }
}
