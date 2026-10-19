import Testing
import Observation
@testable import TerminalUI

// A body evaluated by the root walk sees every environment modifier above it:
// the walk applies them on the way down. Two paths evaluate bodies *outside*
// that walk — the dirty drain, which re-runs one body in place after an
// observable changes, and a reader's rebuild during layout — and both must
// see the same environment the walk would have shown, not the frame's bare
// one.

@Observable
private final class Ticker {
    var count = 0
}

private struct ReadsArrows: TerminalView {
    let ticker: Ticker
    @TerminalEnvironment(\.allowArrowFocusNavigation) var arrows

    var body: some TerminalView {
        Text("\(ticker.count) \(arrows ? "on" : "off")")
    }
}

@MainActor
private func firstRow(_ graph: AttributeGraph, width: Int = 20) -> String {
    var buffer = CellBuffer(width: width, height: 1)
    let rect = Rect(x: 0, y: 0, width: width, height: 1)
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    var line = String((0..<width).map { buffer[$0, 0].character })
    while line.hasSuffix(" ") { line.removeLast() }
    return line
}

@Suite("Bodies rebuilt outside the walk see their ancestors' environment")
@MainActor
struct RebuiltBodyEnvironmentTests {

    @Test func aDrainedBodyKeepsItsEnvironment() {
        let ticker = Ticker()
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: ReadsArrows(ticker: ticker).environment(\.allowArrowFocusNavigation, true))
        }
        #expect(firstRow(graph) == "0 on")

        ticker.count = 1
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            _ = graph.drain()
        }
        #expect(firstRow(graph) == "1 on")
    }

    @Test func aReaderRebuiltInLayoutKeepsItsEnvironment() {
        let ticker = Ticker()
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: GeometryReader { _ in ReadsArrows(ticker: ticker) }
                .environment(\.allowArrowFocusNavigation, true))
        }
        #expect(firstRow(graph) == "0 on")
    }

    /// The measurer applies an environment modifier to the bound environment
    /// before it measures what is under it, and builds a `WidthReader` it
    /// meets there. An edit must still be applied once: a toggle applied
    /// twice reads as if it were never there.
    @Test func anEditAboveAMeasuredReaderAppliesOnce() {
        let ticker = Ticker()
        let graph = AttributeGraph()
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: WidthReader { _ in ReadsArrows(ticker: ticker) }
                .transformEnvironment(\.allowArrowFocusNavigation) { $0.toggle() })
            _ = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 12)
        }
        #expect(firstRow(graph, width: 12) == "0 on")
    }
}
