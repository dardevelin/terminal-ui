import Testing
@testable import TerminalUI

// A Divider rules across its nearest enclosing stack: a horizontal rule in a
// VStack, a vertical one in an HStack. It drew `─` along its top row whatever
// held it, so an HStack's divider was a single dash at the stack's top.

@MainActor
private func draw(_ view: some TerminalView, width: Int, height: Int) -> [String] {
    let buffer = renderedBuffer(view, width: width, height: height)
    return (0..<height).map { y in
        (0..<width).map { String(buffer[$0, y].character) }.joined()
    }
}

/// The glyphs down column `x`, top to bottom.
private func column(_ x: Int, of rendered: [String]) -> [Character] {
    rendered.map { Array($0)[x] }
}

private struct Rule: TerminalView {
    var body: some TerminalView { Divider() }
}

@Suite("Divider — orientation follows the enclosing stack")
@MainActor
struct DividerOrientationTests {

    @Test("in an HStack, a Divider is a vertical rule down the stack's height")
    func hstackDividerIsVertical() {
        let rendered = draw(VStack {
            HStack {
                Text("a\nb\nc")
                Divider()
                Text("x")
            }
            Text("end")
        }, width: 6, height: 5)

        #expect(rendered[0] == "a│x   ")
        #expect(column(1, of: rendered).prefix(3) == ["│", "│", "│"],
                "the rule runs the stack's three rows")
        #expect(!rendered.joined().contains("─"))
    }

    @Test("a vertical Divider does not make its HStack taller")
    func hstackDividerDoesNotGrowTheStack() {
        let rendered = draw(VStack {
            HStack {
                Text("one")
                Divider()
                Text("two")
            }
            Text("end")
        }, width: 8, height: 4)

        #expect(rendered[0] == "one│two ")
        #expect(rendered[1] == "end     ", "the row stays one line tall")
        #expect(rendered[2] == "        ")
    }

    @Test("in an HStack that centres its children, the rule still runs the whole height")
    func hstackDividerFillsUnderCenterAlignment() {
        let rendered = draw(VStack {
            HStack(alignment: .center) {
                Text("a\nb\nc")
                Divider().bold()
                Text("x")
            }
        }, width: 4, height: 3)

        #expect(column(1, of: rendered) == ["│", "│", "│"],
                "a centred rule is not a one-cell tick mid-stack")
    }

    @Test("in a VStack, a Divider is the horizontal rule it always was")
    func vstackDividerIsHorizontal() {
        let rendered = draw(VStack {
            Text("above")
            Divider()
            Text("below")
        }, width: 8, height: 3)

        #expect(rendered == ["above   ", "────────", "below   "])
    }

    @Test("a styled Divider still spans a centred VStack")
    func styledDividerFillsUnderCenterAlignment() {
        let rendered = draw(VStack(alignment: .center) {
            Text("hi")
            Divider().bold().padding(.horizontal, 1)
        }, width: 8, height: 2)

        #expect(rendered[1] == " ────── ", "not a one-cell dash mid-stack")
    }

    @Test("a Divider a ForEach places in an HStack is vertical")
    func forEachDividerInHStackIsVertical() {
        let rendered = draw(HStack {
            ForEachWithID([1, 2], id: \.self) { value in
                Text("\(value)")
                Divider()
            }
        }, width: 6, height: 2)

        #expect(rendered[0] == "1│2│  ")
        #expect(rendered[1] == " │ │  ")
    }

    @Test("a Divider behind a condition, or a view's body, in an HStack is vertical")
    func conditionalAndCompositeDividerInHStackAreVertical() {
        let shows = true
        let rendered = draw(HStack {
            Text("a")
            if shows { Divider() }
            Text("b")
            Rule()
            Text("c")
        }, width: 6, height: 2)

        #expect(rendered[0] == "a│b│c ")
        #expect(rendered[1] == " │ │  ")
    }

    @Test("a VStack inside an HStack rules its own Divider horizontally")
    func nestedVStackDividerIsHorizontal() {
        let rendered = draw(HStack {
            Text("|\n|\n|")
            VStack {
                Text("top")
                Divider()
                Text("bottom")
            }
        }, width: 8, height: 3)

        #expect(rendered == ["|top    ", "|────── ", "|bottom "])
    }

    @Test("a ZStack inside an HStack rules its Divider horizontally, as a stack with no axis of its own")
    func zstackInHStackDividerIsHorizontal() {
        let rendered = draw(HStack {
            Text("|")
            ZStack { Divider() }.frame(width: 3)
        }, width: 5, height: 1)

        #expect(rendered == ["|─── "])
    }
}
