import Testing
@testable import TerminalUI

// The marks the framework draws on the app's behalf — scrollbar, scroll edge
// glyphs, focus and hover bars — were cyan and gray literals. A themed app got
// the terminal's palette in the middle of its own, and nothing it could set
// would change that. They take theme roles now, the scrollbar's shape is a
// style the app can set, and both are read from the view they belong to, so
// one pane can differ from the rest.

/// Roles set to values no literal in the codebase would produce, so a cell
/// wearing one can only have come from the theme.
private struct LoudTheme: Theme {
    var accent: Color = .rgb(1, 2, 3)
    var borderActive: Color = .rgb(10, 11, 12)
    var separator: Color = .rgb(4, 5, 6)
    var foregroundMuted: Color = .rgb(7, 8, 9)
}

@MainActor
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

/// Twenty rows in a five-row viewport: the bar is always drawn.
private func tallScroll() -> some TerminalView {
    ScrollView(.vertical) {
        VStack {
            ForEachWithID(Array(0..<20), id: \.self) { row in Text("row \(row)") }
        }
    }
}

private func column(_ x: Int, of buffer: CellBuffer) -> [Cell] {
    (0..<buffer.height).map { buffer[x, $0] }
}

@Suite("Framework-drawn affordances wear the theme and an app-set shape")
@MainActor
struct AffordanceThemeTests {

    // MARK: - Scrollbar colour

    @Test func thumbAndEdgeMarkerTakeTheActiveBorderAndTheTrackTheSeparator() {
        let buffer = render(tallScroll().environment(\.theme, LoudTheme()), width: 10, height: 5)
        let bar = column(9, of: buffer)
        let glyphs = ScrollbarStyle.thin
        let thumb = bar.filter { $0.character == glyphs.verticalThumb }
        let track = bar.filter { $0.character == glyphs.verticalTrack }
        let edge = bar.filter { $0.character == "▼" }
        #expect(!thumb.isEmpty && !track.isEmpty && !edge.isEmpty)
        #expect(thumb.allSatisfy { $0.style.foreground == LoudTheme().borderActive })
        #expect(edge.allSatisfy { $0.style.foreground == LoudTheme().borderActive })
        #expect(track.allSatisfy { $0.style.foreground == LoudTheme().separator })
    }

    /// The stock theme's roles are the literals the bar used to draw, so an
    /// app that never set a theme sees no colour change.
    @Test func theDefaultThemeKeepsTheOriginalColours() {
        let bar = column(9, of: render(tallScroll(), width: 10, height: 5))
        #expect(bar.first { $0.character == ScrollbarStyle.thin.verticalThumb }?.style.foreground == .cyan)
        #expect(bar.first { $0.character == ScrollbarStyle.thin.verticalTrack }?.style.foreground == .gray)
    }

    /// A theme set on one pane reaches that pane's bar, not only an app-wide one.
    @Test func aThemeOnOnePaneReachesOnlyThatPanesBar() {
        let buffer = render(HStack {
            tallScroll().frame(width: 10).environment(\.theme, LoudTheme())
            tallScroll().frame(width: 10)
        }, width: 20, height: 5)
        let themed = column(9, of: buffer).first { $0.character == ScrollbarStyle.thin.verticalThumb }
        let stock = column(19, of: buffer).first { $0.character == ScrollbarStyle.thin.verticalThumb }
        #expect(themed?.style.foreground == LoudTheme().borderActive)
        #expect(stock?.style.foreground == .cyan)
    }

    // MARK: - Scrollbar shape

    @Test func theDefaultBarIsThin() {
        let bar = column(9, of: render(tallScroll(), width: 10, height: 5)).map(\.character)
        #expect(bar.contains("┃"))
        #expect(!bar.contains("█"))
    }

    @Test func blockStyleDrawsAFullBlockThumb() {
        let bar = column(9, of: render(tallScroll().scrollbarStyle(.block), width: 10, height: 5))
            .map(\.character)
        #expect(bar.contains("█"))
    }

    @Test func aCustomStyleDrawsItsOwnGlyphs() {
        let style = ScrollbarStyle(verticalTrack: "·", verticalThumb: "▐",
                                   horizontalTrack: "·", horizontalThumb: "▄")
        let bar = column(9, of: render(tallScroll().scrollbarStyle(style), width: 10, height: 5))
            .map(\.character)
        #expect(bar.contains("▐"))
        #expect(bar.contains("·"))
    }

    @Test func aStyleOnOnePaneLeavesItsNeighbourAlone() {
        let buffer = render(HStack {
            tallScroll().frame(width: 10).scrollbarStyle(.block)
            tallScroll().frame(width: 10)
        }, width: 20, height: 5)
        #expect(column(9, of: buffer).map(\.character).contains("█"))
        #expect(!column(19, of: buffer).map(\.character).contains("█"))
    }

    @Test func theHorizontalBarFollowsTheStyleAndTheme() {
        let view = ScrollView(.horizontal) { Text(String(repeating: "x", count: 40)) }
            .scrollbarStyle(.thin)
            .environment(\.theme, LoudTheme())
        let buffer = render(view, width: 10, height: 3)
        let bottom = (0..<buffer.width).map { buffer[$0, 2] }
        let thumb = bottom.filter { $0.character == ScrollbarStyle.thin.horizontalThumb }
        #expect(!thumb.isEmpty)
        #expect(thumb.allSatisfy { $0.style.foreground == LoudTheme().borderActive })
    }

    // MARK: - Edge markers

    /// The quiet bar: no arrows, so the column is track and thumb from top
    /// to bottom, and the thumb is told apart by colour.
    @Test func hairlineDrawsNoMarkersAndRunsTheFullHeight() {
        let view = tallScroll().scrollbarStyle(.hairline).environment(\.theme, LoudTheme())
        let bar = column(9, of: render(view, width: 10, height: 5))
        #expect(bar.allSatisfy { $0.character == "│" })
        #expect(bar.contains { $0.style.foreground == LoudTheme().borderActive })
        #expect(bar.contains { $0.style.foreground == LoudTheme().separator })
    }

    @Test func markersCanBeTurnedOffWithoutLosingTheBar() {
        var style = ScrollbarStyle.thin
        style.edgeMarkers = nil
        let bar = column(9, of: render(tallScroll().scrollbarStyle(style), width: 10, height: 5))
            .map(\.character)
        #expect(!bar.contains("▼"))
        #expect(bar.contains(style.verticalThumb))
    }

    @Test func customMarkersAreDrawn() {
        var style = ScrollbarStyle.thin
        style.edgeMarkers = ScrollEdgeMarkers(up: "^", down: "v", left: "<", right: ">")
        let bar = column(9, of: render(tallScroll().scrollbarStyle(style), width: 10, height: 5))
            .map(\.character)
        #expect(bar.last == "v")
    }

    @Test func hidingTheIndicatorsStillHidesEverything() {
        let bar = column(9, of: render(tallScroll().scrollIndicators(.hidden), width: 10, height: 5))
            .map(\.character)
        #expect(!bar.contains("│") && !bar.contains("┃") && !bar.contains("▼"))
    }

    // MARK: - Focus and hover bars

    /// A focusable leaf inside a subtree themed with `LoudTheme`, so the bar
    /// can only pick the theme up from the node's own environment. Rendered
    /// first, as every frame is: the render walk is what records each node's
    /// environment, and the focus pass runs after it.
    private func focusedLeaf(readOnly: Bool = false) -> (AttributeNode, FocusEngine, AttributeNode) {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 20, height: 5)
        let rect = Rect(x: 0, y: 0, width: 20, height: 5)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: VStack { Text("x") }
                .environment(\.focusIsReadOnly, readOnly)
                .environment(\.theme, LoudTheme()))
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        let root = graph.root!
        var leaf = root
        while let child = leaf.children.first { leaf = child }
        leaf.isFocusable = true
        leaf.rect = Rect(x: 3, y: 1, width: 5, height: 1)
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        return (root, engine, leaf)
    }

    @Test func theFocusBarTakesTheFocusedViewsAccent() {
        let (root, engine, leaf) = focusedLeaf()
        engine.keyboardFocusID = leaf.id
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1].character == "▎")
        #expect(buffer[2, 1].style.foreground == LoudTheme().accent)
    }

    @Test func aReadOnlyFocusBarIsMuted() {
        let (root, engine, leaf) = focusedLeaf(readOnly: true)
        engine.keyboardFocusID = leaf.id
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1].character == "┆")
        #expect(buffer[2, 1].style.foreground == LoudTheme().foregroundMuted)
    }

    @Test func theHoverBarIsMuted() {
        let (root, engine, leaf) = focusedLeaf()
        engine.mouseHoverID = leaf.id
        var buffer = CellBuffer(width: 20, height: 5)
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: root)
        #expect(buffer[2, 1].character == "▏")
        #expect(buffer[2, 1].style.foreground == LoudTheme().foregroundMuted)
    }
}
