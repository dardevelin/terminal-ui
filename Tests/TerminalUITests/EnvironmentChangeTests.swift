import Testing
import Observation
@testable import TerminalUI

// The update walk skips a view whose inputs compare equal, and with it the
// subtree below — the views under it were built from the same values, so they
// would build the same thing. The environment is the exception: it reaches a
// view without passing through its inputs, so a theme switched above an
// unchanged view went unseen by everything under it. A body now remembers
// the environment values it read, and a skipped view still re-runs the bodies
// below it whose values changed — those, and no others.

private struct ArrowsLabel: TerminalView {
    @TerminalEnvironment(\.allowArrowFocusNavigation) var arrows
    var body: some TerminalView { Text(arrows ? "on" : "off") }
}

private struct Plain: TerminalView {
    let name: String
    var body: some TerminalView { Text(name) }
}

/// Holds a reader without reading anything itself, so its inputs never change.
private struct Panel: TerminalView {
    var body: some TerminalView {
        VStack(spacing: 0) {
            ArrowsLabel()
            Plain(name: "plain")
        }
    }
}

private struct Root: TerminalView {
    let arrows: Bool
    var body: some TerminalView {
        Panel().environment(\.allowArrowFocusNavigation, arrows)
    }
}

/// A transform between the unchanged view and the reader: what the reader
/// sees is decided at the reader, not where the walk stopped.
private struct InvertingRoot: TerminalView {
    let arrows: Bool
    var body: some TerminalView {
        Panel()
            .transformEnvironment(\.allowArrowFocusNavigation) { $0.toggle() }
            .environment(\.allowArrowFocusNavigation, arrows)
    }
}

@MainActor
private func rows(_ graph: AttributeGraph, width: Int = 8, height: Int = 2) -> [String] {
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return (0..<height).map { y in
        var line = String((0..<width).map { buffer[$0, y].character })
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}

@MainActor
private func update(_ graph: AttributeGraph, _ view: some TerminalView) {
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { _ = graph.update(from: view) }
}

@Suite("An environment change reaches views whose inputs did not change")
@MainActor
struct EnvironmentChangeTests {

    @Test func aReaderUnderAnUnchangedViewSeesTheNewValue() {
        let graph = AttributeGraph()
        update(graph, Root(arrows: false))
        #expect(rows(graph) == ["off", "plain"])

        update(graph, Root(arrows: true))
        #expect(rows(graph) == ["on", "plain"])
    }

    @Test func onlyTheReaderRunsAgain() {
        let graph = AttributeGraph()
        update(graph, Root(arrows: false))
        graph.resetFrameStats()

        // Root's own input changed, so it runs; of everything under it, only
        // the body that read the value does.
        update(graph, Root(arrows: true))
        #expect(graph.bodyEvaluationCount == 2)
    }

    @Test func anUnchangedEnvironmentRunsNothing() {
        let graph = AttributeGraph()
        update(graph, Panel().environment(\.allowArrowFocusNavigation, true))
        graph.resetFrameStats()

        update(graph, Panel().environment(\.allowArrowFocusNavigation, true))
        #expect(graph.bodyEvaluationCount == 0)
        #expect(rows(graph) == ["on", "plain"])
    }

    @Test func aTransformBelowTheSkippedViewStillApplies() {
        let graph = AttributeGraph()
        update(graph, InvertingRoot(arrows: false))
        #expect(rows(graph) == ["on", "plain"])

        update(graph, InvertingRoot(arrows: true))
        #expect(rows(graph) == ["off", "plain"])
    }

    @Test func theRootViewItselfSeesTheNewValue() {
        let graph = AttributeGraph()
        update(graph, ArrowsLabel().environment(\.allowArrowFocusNavigation, false))
        #expect(rows(graph) == ["off", ""])

        update(graph, ArrowsLabel().environment(\.allowArrowFocusNavigation, true))
        #expect(rows(graph) == ["on", ""])
    }

    @Test func aThemeSwitchRedrawsWhatDrewWithTheTheme() {
        var loud = DefaultTheme()
        loud.accent = .magenta
        let graph = AttributeGraph()
        update(graph, Panel().environment(\.theme, DefaultTheme()))
        graph.resetFrameStats()

        update(graph, Panel().environment(\.theme, DefaultTheme()))
        #expect(graph.bodyEvaluationCount == 0)

        update(graph, ThemedPanel().environment(\.theme, DefaultTheme()))
        graph.resetFrameStats()
        update(graph, ThemedPanel().environment(\.theme, loud))
        #expect(graph.bodyEvaluationCount == 1)
        #expect(cell(graph).style.foreground == .magenta)
    }

    @Test func aDrainedBodyPassesTheNewValueDown() {
        let model = Model()
        let graph = AttributeGraph()
        update(graph, ModelRoot(model: model))
        #expect(rows(graph) == ["off", "plain"])

        model.arrows = true
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) { _ = graph.drain() }
        #expect(rows(graph) == ["on", "plain"])
    }
}

private struct Swatch: TerminalView {
    @TerminalEnvironment(\.theme) var theme
    var body: some TerminalView { Text("x").foreground(theme.accent) }
}

private struct ThemedPanel: TerminalView {
    var body: some TerminalView {
        VStack(spacing: 0) {
            Swatch()
            Plain(name: "plain")
        }
    }
}

@MainActor
private func cell(_ graph: AttributeGraph) -> Cell {
    var buffer = CellBuffer(width: 4, height: 2)
    let rect = Rect(x: 0, y: 0, width: 4, height: 2)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return buffer[0, 0]
}

@Observable
private final class Model {
    var arrows = false
}

/// The value comes from an observable, so the change arrives by the drain,
/// which re-runs this body alone and not the walk from the root.
private struct ModelRoot: TerminalView {
    let model: Model
    var body: some TerminalView {
        Panel().environment(\.allowArrowFocusNavigation, model.arrows)
    }
}
