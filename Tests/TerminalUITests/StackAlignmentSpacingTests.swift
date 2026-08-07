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

// A `.frame` states a size and `.overlay` states a layer; both were silent
// about where the content goes inside them, so both drew from the top-left
// corner. `.overlay(alignment: .topTrailing)` is the case that matters most —
// badges, close buttons, corner indicators are the reason overlays exist.

@Suite("Frames and overlays — alignment")
@MainActor
struct FrameOverlayAlignmentTests {

    @Test("a frame places its content where it was told")
    func frameAlignsContent() {
        let centred = draw(Text("ab").frame(width: 10, height: 3, alignment: .center),
                           width: 12, height: 4)
        #expect(column(of: "ab", in: centred) == 4, "(10 - 2) / 2")
        #expect(rowIndex(of: "ab", in: centred) == 1, "(3 - 1) / 2")

        let corner = draw(Text("ab").frame(width: 10, height: 3, alignment: .bottomTrailing),
                          width: 12, height: 4)
        #expect(column(of: "ab", in: corner) == 8)
        #expect(rowIndex(of: "ab", in: corner) == 2)
    }

    @Test("a frame with no alignment still draws from the corner")
    func frameDefaultUnchanged() {
        let rendered = draw(Text("ab").frame(width: 10, height: 3), width: 12, height: 4)
        #expect(column(of: "ab", in: rendered) == 0)
        #expect(rowIndex(of: "ab", in: rendered) == 0)
    }

    @Test("an overlay pins to the corner it was given")
    func overlayPinsToCorner() {
        let base = Text("....\n....\n....").overlay(alignment: .topTrailing) { Text("X") }
        let rendered = draw(base, width: 6, height: 4)

        #expect(rowIndex(of: "X", in: rendered) == 0)
        #expect(column(of: "X", in: rendered) == 3, "flush against the base's right edge")
    }

    @Test("an overlay with no alignment covers from the corner, as before")
    func overlayDefaultUnchanged() {
        let base = Text("....\n....").overlay { Text("X") }
        let rendered = draw(base, width: 6, height: 3)
        #expect(rowIndex(of: "X", in: rendered) == 0)
        #expect(column(of: "X", in: rendered) == 0)
    }
}

// Alignment measures a child so it can place it — but some children have a
// nominal width and fill whatever they are given. A `Divider` measures one
// cell and draws a rule across its whole rect, so measuring it and honouring
// the answer turns the rule into a single dash floating in the middle of the
// stack. Found by building a consumer package against the public API, which is
// the first thing that put a Divider under a non-default alignment.

@Suite("Stacks — alignment does not shrink filling children")
@MainActor
struct AlignmentFillingChildTests {

    @Test("a Divider still spans the stack when the stack is centred")
    func dividerFillsUnderCenterAlignment() {
        let rendered = draw(VStack(alignment: .center) {
            Text("hi")
            Divider()
        }, width: 20, height: 3)

        let rule = rendered.first { $0.contains("─") } ?? ""
        #expect(rule.filter { $0 == "─" }.count == 20,
                "the rule spans the stack, it is not centred as a one-cell dash")
    }

    @Test("a Divider still spans the stack when the stack is trailing-aligned")
    func dividerFillsUnderTrailingAlignment() {
        let rendered = draw(VStack(alignment: .trailing) {
            Text("hi")
            Divider()
        }, width: 20, height: 3)

        let rule = rendered.first { $0.contains("─") } ?? ""
        #expect(rule.filter { $0 == "─" }.count == 20)
    }

    // The horizontal twin: a view that asked for the whole cross axis keeps it.
    @Test("a maxWidth-infinity child still fills a centred stack")
    func infiniteWidthChildFills() {
        let rendered = draw(VStack(alignment: .center) {
            Text("x").frame(maxWidth: .infinity)
        }, width: 12, height: 2)
        #expect(rendered[0].hasPrefix("x"), "it kept the full width, so it draws from the left")
    }
}

// Spacing changes how much room a stack needs, so a parent asking "how wide
// are you?" has to be told about the gaps. The measurer summed its children
// and ignored them, so any parent that sizes a spaced stack — a centred
// VStack, a border, a frame — under-measured it and clipped the last child.
// Found by a consumer package rendering a centred card: `right` came out as
// `rig`.

@Suite("Stacks — spacing counts toward the measured size")
@MainActor
struct SpacingMeasurementTests {

    @Test("an HStack reports its gaps in its width")
    func hstackWidthIncludesSpacing() {
        let graph = AttributeGraph()
        graph.update(from: HStack(spacing: 2) {
            Text("aaaa")
            Text("bbbb")
        })
        #expect(GraphMeasurer.measureWidth(graph.root!) == 10, "4 + 4 of text, 2 of gap")
    }

    @Test("a VStack reports its gaps in its height")
    func vstackHeightIncludesSpacing() {
        let graph = AttributeGraph()
        graph.update(from: VStack(spacing: 3) {
            Text("one")
            Text("two")
        })
        #expect(GraphMeasurer.measureHeight(graph.root!, proposedWidth: 10) == 5,
                "two rows, three of gap")
    }

    // The shape that surfaced it: a spaced row centred inside a stack, which
    // sizes the row from its measurement before placing it.
    @Test("a centred stack does not clip a spaced row")
    func centredSpacedRowIsNotClipped() {
        let rendered = draw(VStack(alignment: .center) {
            HStack(spacing: 2) {
                Text("left")
                Text("right")
            }
        }, width: 24, height: 2)

        #expect(rendered[0].contains("right"), "the last child survives the measurement")
    }
}
