import Testing
@testable import TerminalUI

// Wrapping used to depend on whether the text happened to be styled: an
// unstyled `Text` went through word-aware `TextLayout.wrapWords`, while a
// `Text(spans:)` was handed cell by cell to `CellBuffer.writeSpans`, which
// broke wherever the next grapheme stopped fitting.
//
// That is worse than an inconsistency. `GraphMeasurer` counts word-wrapped
// rows for both, so a styled paragraph could be measured at one height and
// rendered at another — the class of defect that clips a message's last line.

@MainActor
@Suite struct SpanWrappingTests {

    private func render(_ view: some TerminalView, width: Int, height: Int) -> CellBuffer {
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

    private func rows(_ buffer: CellBuffer) -> [String] {
        (0..<buffer.height).map { y in
            var line = ""
            for x in 0..<buffer.width { line.append(buffer[x, y].character) }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// The defect itself: the same sentence must reflow identically whether or
    /// not any of it carries styling.
    @Test func styledAndUnstyledTextBreakAtTheSameWords() {
        let sentence = "alpha beta gamma delta"
        let plain = rows(render(Text(sentence), width: 12, height: 3))
        let styled = rows(render(
            Text(spans: [TextSpan("alpha ", foreground: .red), TextSpan("beta gamma delta")]),
            width: 12, height: 3))
        #expect(plain == styled, "plain \(plain) vs styled \(styled)")
    }

    @Test func wrappingPreservesEachRunsStyle() {
        let buffer = render(
            Text(spans: [TextSpan("alpha beta ", foreground: .red),
                         TextSpan("gamma delta", foreground: .green)]),
            width: 12, height: 3)
        #expect(rows(buffer)[0] == "alpha beta")
        #expect(buffer[0, 0].style.foreground == .red)
        // The second run kept its own colour across the wrap boundary.
        #expect(buffer[0, 1].style.foreground == .green)
    }

    /// Leading whitespace the caller wrote is content — a padded list marker,
    /// an indent — and only a break the wrapper introduced swallows a space.
    @Test func callerWrittenLeadingWhitespaceSurvives() {
        let buffer = render(Text(spans: [TextSpan(" 9. item", foreground: .red)]),
                            width: 12, height: 1)
        #expect(rows(buffer)[0] == " 9. item")
    }

    @Test func measuredHeightMatchesTheRenderedRowCount() {
        let spans = [TextSpan("alpha ", foreground: .red), TextSpan("beta gamma delta")]
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: Text(spans: spans))
        }
        let measured = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 12)
        let rendered = TextLayout.wrap(spans, width: 12).count
        #expect(measured == rendered, "measured \(measured) vs rendered \(rendered)")
    }

    // MARK: - TextLayout.wrap directly

    @Test func embeddedNewlinesStartANewRow() {
        let wrapped = TextLayout.wrap([TextSpan("one\ntwo")], width: 20)
        #expect(wrapped.count == 2)
        #expect(wrapped[0].map(\.text).joined() == "one")
        #expect(wrapped[1].map(\.text).joined() == "two")
    }

    /// A word wider than the column has to break somewhere; keeping it visible
    /// beats dropping it.
    @Test func anOverlongWordBreaksAtACharacterBoundary() {
        let wrapped = TextLayout.wrap([TextSpan("supercalifragilistic")], width: 8)
        #expect(wrapped.count == 3)
        #expect(wrapped.map { $0.map(\.text).joined() }.joined() == "supercalifragilistic")
    }

    @Test func adjacentRunsFromOneSpanAreNotSplitApart() {
        // Regrouping must not emit one span per character.
        let wrapped = TextLayout.wrap([TextSpan("alpha beta", foreground: .red)], width: 20)
        #expect(wrapped.count == 1)
        #expect(wrapped[0].count == 1)
    }

    @Test func wideGraphemesAreMeasuredByCellNotCount() {
        // Four ideographs are eight cells, so they cannot share a six-cell row.
        let wrapped = TextLayout.wrap([TextSpan("日本語テキスト")], width: 6)
        #expect(wrapped.allSatisfy { $0.map(\.text).joined().displayWidth <= 6 })
    }

    @Test func nonPositiveWidthReturnsTheInputUntouched() {
        let spans = [TextSpan("anything")]
        #expect(TextLayout.wrap(spans, width: 0).count == 1)
    }
}
