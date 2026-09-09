import Testing
@testable import TerminalUI

// A wrapped `Text` reserves the rows its wrap needs — `GraphMeasurer`
// reports the taller rect and the parent lays it out — but the renderer
// must actually WRITE every one of those rows. The Coder example hit the
// case where it wrote only the first: a chat message inside
// `HStack { rail; VStack { header; body } }` showed its opening line and
// left the continuation blank, while the node's rect was two rows tall.
//
// Pinned at three widths of nesting because the bug was invisible in the
// bare case and only appeared once the wrapping Text sat behind a sibling
// that shifted its origin.

@MainActor
@Suite struct WrappedTextInStackTests {
    /// Reads a buffer row back as a string, trailing blanks trimmed.
    private func row(_ buffer: CellBuffer, _ y: Int, width: Int) -> String {
        var text = ""
        for x in 0..<width {
            text.append(buffer[x, y].character)
        }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    private func render(
        _ view: some TerminalView,
        width: Int,
        height: Int
    ) -> CellBuffer {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        return buffer
    }

    @Test func bareWrappedTextWritesBothRows() {
        let buffer = render(Text("aaaa bbbb cccc"), width: 10, height: 3)
        #expect(row(buffer, 0, width: 10) == "aaaa bbbb")
        #expect(row(buffer, 1, width: 10) == "cccc")
    }

    @Test func wrappedTextInsideVStackWritesBothRows() {
        let view = VStack(spacing: 0) {
            Text("head")
            Text("aaaa bbbb cccc")
        }
        let buffer = render(view, width: 10, height: 4)
        #expect(row(buffer, 0, width: 10) == "head")
        #expect(row(buffer, 1, width: 10) == "aaaa bbbb")
        #expect(row(buffer, 2, width: 10) == "cccc")
    }

    /// The Coder chat-message shape: a one-column rail beside a column
    /// whose second child wraps.
    @Test func wrappedTextInsideVStackInsideHStackWritesBothRows() {
        let view = HStack(spacing: 1) {
            Text("|")
            VStack(spacing: 0) {
                Text("head")
                Text("aaaa bbbb cccc")
            }
        }
        let buffer = render(view, width: 12, height: 4)
        #expect(row(buffer, 0, width: 12) == "| head")
        #expect(row(buffer, 1, width: 12) == "  aaaa bbbb")
        #expect(row(buffer, 2, width: 12) == "  cccc")
    }

    /// The full Coder transcript shape — the rail/column pair lives inside
    /// a `ScrollView`, which measures its content against an unbounded
    /// height before the visible slice is taken.
    @Test func wrappedTextInsideScrollViewWritesBothRows() {
        let view = ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    Text("|")
                    VStack(spacing: 0) {
                        Text("head")
                        Text("aaaa bbbb cccc")
                    }
                }
            }
        }
        let buffer = render(view, width: 12, height: 5)
        #expect(row(buffer, 0, width: 12) == "| head")
        #expect(row(buffer, 1, width: 12) == "  aaaa bbbb")
        #expect(row(buffer, 2, width: 12) == "  cccc")
    }

    private struct Entry: Identifiable { let id: Int; let body: String }

    /// The Coder transcript verbatim: a padded, horizontally-flexible
    /// `ScrollView` whose `ForEach` rows are gapped by `spacing: 1`, laid
    /// out beside a fixed-width sibling that takes the remaining columns.
    @Test func wrappedTextInFlexibleScrollViewBesideFixedSiblingWritesBothRows() {
        let entries = [Entry(id: 1, body: "aaaa bbbb cccc")]
        let view = HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(entries) { entry in
                        HStack(spacing: 1) {
                            Text("|")
                            VStack(spacing: 0) {
                                Text("head")
                                Text(entry.body)
                            }
                        }
                    }
                }
            }
            .padding(1)
            .flexible(.horizontal)
            Text("side").frame(width: 6)
        }
        let buffer = render(view, width: 20, height: 6)
        #expect(row(buffer, 1, width: 14) == " | head")
        #expect(row(buffer, 2, width: 14) == "   aaaa bbbb")
        #expect(row(buffer, 3, width: 14) == "   cccc")
    }

    /// Same shape, but the content is taller than the viewport so the
    /// `ScrollView` takes a visible slice. This is the case the Coder
    /// transcript actually hits: a wrapped message's continuation line
    /// went missing while its rect still claimed both rows.
    @Test func wrappedTextKeepsContinuationLineWhenScrollContentOverflows() {
        let entries = (1...6).map { Entry(id: $0, body: "aaaa bbbb cccc") }
        let view = ScrollView {
            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    VStack(spacing: 0) {
                        Text("head\(entry.id)")
                        Text(entry.body)
                    }
                }
            }
        }
        // Width 11 leaves column 10 to the scrollbar, so columns 0..<10
        // hold content only.
        let buffer = render(view, width: 11, height: 8)
        #expect(row(buffer, 0, width: 10) == "head1")
        #expect(row(buffer, 1, width: 10) == "aaaa bbbb")
        #expect(row(buffer, 2, width: 10) == "cccc")
    }

    /// The demo's exact composition: the wrapped body sits in a `VStack`
    /// that is itself the second child of an `HStack` rail, and the whole
    /// `ForEach` overflows the scroll viewport. This is the combination
    /// that lost the continuation line.
    @Test func railedMessageKeepsContinuationLineWhenScrollContentOverflows() {
        let entries = (1...6).map { Entry(id: $0, body: "aaaa bbbb cccc") }
        let view = ScrollView {
            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    HStack(spacing: 1) {
                        Text("|")
                        VStack(spacing: 0) {
                            Text("head\(entry.id)")
                            Text(entry.body)
                        }
                    }
                }
            }
        }
        let buffer = render(view, width: 13, height: 8)
        #expect(row(buffer, 0, width: 12) == "| head1")
        #expect(row(buffer, 1, width: 12) == "  aaaa bbbb")
        #expect(row(buffer, 2, width: 12) == "  cccc")
    }

    /// As above, but the wrapping `Text` carries a `.foreground()`. The
    /// modifier wraps the text node, and the wrap height has to survive
    /// that extra level or the continuation line is dropped.
    @Test func styledWrappedTextKeepsContinuationLine() {
        let entries = (1...6).map { Entry(id: $0, body: "aaaa bbbb cccc") }
        let view = ScrollView {
            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    HStack(spacing: 1) {
                        Text("|").foreground(.cyan)
                        VStack(spacing: 0) {
                            Text(spans: [TextSpan("head\(entry.id)", foreground: .cyan)])
                            Text(entry.body).foreground(.white)
                        }
                    }
                }
            }
        }
        let buffer = render(view, width: 13, height: 8)
        #expect(row(buffer, 0, width: 12) == "| head1")
        #expect(row(buffer, 1, width: 12) == "  aaaa bbbb")
        #expect(row(buffer, 2, width: 12) == "  cccc")
    }

    /// The literal Coder fixture at the width it is laid out at. 103
    /// characters into 102 columns: the wrap leaves a three-character
    /// remainder, and that remainder is what went missing on screen.
    @Test func exactCoderMessageWrapsToTwoRenderedRows() {
        let body = "The compositor is emitting a full repaint whenever the "
            + "frame budget is missed. Find out why and fix it."
        #expect(body.count == 103)
        let buffer = render(Text(body), width: 102, height: 4)
        #expect(row(buffer, 1, width: 102) == "it.")
    }

    /// `HStack` must measure a child against the width the child will
    /// actually be *placed* at — that is, after inter-child spacing has
    /// been taken out. Measuring against the unspaced width makes a text
    /// that fits by exactly one column look like it needs one row, so the
    /// stack reserves one row too few and the wrap's last line is clipped.
    ///
    /// Sized so the difference is decisive: the body is exactly one column
    /// narrower than the stack. Subtracting only the rail leaves it room
    /// for one line; subtracting the rail *and* the spacing forces two.
    /// The demo hit this at the same ratio — a 103-column body in a
    /// 104-column stack.
    @Test func hstackMeasuresChildrenAtTheirPostSpacingWidth() {
        let body = "aaaa bbbb c"
        #expect(body.count == 11)
        let view = HStack(spacing: 1) {
            Text("|")
            Text(body)
        }
        let buffer = render(view, width: 12, height: 4)
        #expect(row(buffer, 0, width: 12) == "| aaaa bbbb")
        #expect(row(buffer, 1, width: 12) == "  c")
    }

    /// The demo's shape at the demo's ratio: rail, then a `VStack` whose
    /// second child is one column wider than the space the stack will
    /// actually give it. The inner `VStack` must reserve the row the wrap
    /// needs — if it sizes itself from a measurement taken at the
    /// pre-spacing width it comes out one row short and clips the tail.
    @Test func railedColumnReservesTheWrappedRowAtExactSpacingBoundary() {
        let body = "aaaa bbbb c"
        #expect(body.count == 11)
        let view = HStack(spacing: 1) {
            Text("|")
            VStack(spacing: 0) {
                Text("h")
                Text(body)
            }
        }
        let buffer = render(view, width: 12, height: 5)
        #expect(row(buffer, 0, width: 12) == "| h")
        #expect(row(buffer, 1, width: 12) == "  aaaa bbbb")
        #expect(row(buffer, 2, width: 12) == "  c")
    }

    /// The defect itself, at the measurement layer where it lived.
    ///
    /// `GraphMeasurer` answers "how tall is this `HStack` at width W?" for
    /// every parent that sizes a child from its measurement — the enclosing
    /// `VStack` of a transcript, a `.border()`, a `.frame()`. It used to
    /// propose W to each child, but a child of an `HStack` is placed at W
    /// minus its siblings minus the gaps. A body that fits the former and
    /// not the latter measured one row short, and the parent clipped the
    /// wrap's last line — invisible until a message landed on the boundary.
    @Test func hstackHeightAccountsForTheWidthEachChildIsPlacedAt() {
        let view = HStack(spacing: 1) {
            Text("|")
            Text("aaaa bbbb c")  // 11 columns; placed at 10 → two rows
        }
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
        let height = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 12)
        #expect(height == 2)
    }

    /// `measureFocusedPosition` and `adjustScrollOffset` ask for heights at
    /// `proposedWidth: 0`, meaning "unconstrained — measure intrinsically".
    /// Apportioning zero columns across an `HStack`'s children measures every
    /// one of them at nothing and reports height 0, which tells the scroll
    /// math the content fits and silently disables keyboard scrolling. Pinned
    /// because that is exactly how the fix above first went wrong.
    @Test func hstackHeightTreatsZeroProposedWidthAsUnconstrained() {
        let view = HStack(spacing: 1) {
            Text("|")
            Text("aaaa bbbb c")
        }
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
        #expect(GraphMeasurer.measureHeight(graph.root!, proposedWidth: 0) > 0)
    }

    /// A `ZStack` is the counter-case: its children overlay at the full
    /// width, so the proposal must pass through untouched. Pinned so the
    /// `HStack` fix above is not "helpfully" generalised to it.
    @Test func zstackHeightProposesFullWidthToEachChild() {
        let view = ZStack {
            Text("aaaa bbbb c")
        }
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: view)
        }
        #expect(GraphMeasurer.measureHeight(graph.root!, proposedWidth: 12) == 1)
    }
}
