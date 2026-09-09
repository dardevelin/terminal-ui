import Testing
@testable import TerminalUI

// `.wrap(.truncate(_:))` is the third answer to "this line is too long":
// wrap spills it onto more rows, `.none` cuts it silently, truncate cuts it
// and says so. Dense chrome needs the third — a sidebar of file paths that
// wraps reflows the whole panel as content changes, and one that clips
// leaves the reader unable to tell a full path from a cut one.
//
// The span-aware path is the one worth guarding: a status row is three
// styles on one line, and truncating the joined string would flatten them.

@MainActor
@Suite struct TextTruncationTests {

    private func render(
        _ view: some TerminalView,
        width: Int,
        height: Int = 1
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

    private func row(_ buffer: CellBuffer, _ y: Int, width: Int) -> String {
        var text = ""
        for x in 0..<width { text.append(buffer[x, y].character) }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    // MARK: - Plain text

    @Test func tailTruncationKeepsTheStart() {
        let buffer = render(Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.tail)),
                            width: 12)
        #expect(row(buffer, 0, width: 12) == "Sources/Ren…")
    }

    @Test func headTruncationKeepsTheEnd() {
        let buffer = render(Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.head)),
                            width: 12)
        #expect(row(buffer, 0, width: 12) == "…sitor.swift")
    }

    @Test func middleTruncationKeepsBothEnds() {
        let buffer = render(Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.middle)),
                            width: 12)
        // Odd remainder gives the head the extra cell, per LineBreakMode.
        #expect(row(buffer, 0, width: 12) == "Source…swift")
    }

    @Test func textThatAlreadyFitsIsUntouched() {
        let buffer = render(Text("short").wrap(.truncate(.tail)), width: 12)
        #expect(row(buffer, 0, width: 12) == "short")
    }

    /// Truncation must not inflate height the way wrapping does — that is
    /// the reason a caller reaches for it in a fixed-height row.
    @Test func truncationKeepsTheLineToASingleRow() {
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: Text("a b c d e f g h i j k").wrap(.truncate(.tail)))
        }
        #expect(GraphMeasurer.measureHeight(graph.root!, proposedWidth: 8) == 1)
    }

    // MARK: - Styled spans

    @Test func spanTruncationPreservesPerRunStyles() {
        let spans = [
            TextSpan("●", foreground: .green),
            TextSpan(" gopls", foreground: .white),
            TextSpan("  not started", foreground: .gray),
        ]
        let truncated = TextLayout.truncate(spans, width: 12, edge: .tail)
        let text = truncated.map(\.text).joined()
        #expect(text == "● gopls  no…")
        #expect(truncated[0].foreground == .green)
        #expect(truncated[1].foreground == .white)
        // The ellipsis interrupts the dim trailing detail, so it stays dim
        // rather than jumping to the color of the first run.
        #expect(truncated.last?.foreground == .gray)
    }

    @Test func spanTruncationRendersThroughTheViewPath() {
        let view = Text(spans: [
            TextSpan("●", foreground: .green),
            TextSpan(" sourcekit-lsp", foreground: .white),
        ]).wrap(.truncate(.tail))
        let buffer = render(view, width: 8)
        #expect(row(buffer, 0, width: 8) == "● sourc…")
        #expect(buffer[0, 0].style.foreground == .green)
        #expect(buffer[2, 0].style.foreground == .white)
    }

    @Test func spanListThatFitsIsReturnedUnchanged() {
        let spans = [TextSpan("ok", foreground: .green)]
        #expect(TextLayout.truncate(spans, width: 12, edge: .tail).map(\.text) == ["ok"])
    }

    @Test func spanHeadTruncationKeepsTheTrailingRuns() {
        let spans = [
            TextSpan("Sources/", foreground: .gray),
            TextSpan("Compositor.swift", foreground: .white),
        ]
        let truncated = TextLayout.truncate(spans, width: 10, edge: .head)
        #expect(truncated.map(\.text).joined() == "…tor.swift")
        #expect(truncated.last?.foreground == .white)
    }

    /// Width 1 has room for the marker and nothing else; the result must
    /// still be exactly one cell rather than overflowing the rect.
    @Test func spanTruncationAtWidthOneEmitsOnlyTheMarker() {
        let spans = [TextSpan("hello", foreground: .red)]
        let truncated = TextLayout.truncate(spans, width: 1, edge: .tail)
        #expect(truncated.map(\.text).joined() == "…")
        #expect(truncated.count == 1)
    }

    /// Double-width graphemes are dropped whole — half an ideograph would
    /// desync every column to its right.
    @Test func spanTruncationDoesNotSplitAWideGrapheme() {
        let spans = [TextSpan("日本語テキスト", foreground: .cyan)]
        let truncated = TextLayout.truncate(spans, width: 6, edge: .tail)
        let joined = truncated.map(\.text).joined()
        #expect(joined.displayWidth <= 6)
        #expect(joined == "日本…")
    }
}
