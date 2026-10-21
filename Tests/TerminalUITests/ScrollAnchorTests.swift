import Testing
@testable import TerminalUI

// A chat transcript opens on its latest entry and keeps it in view as entries
// arrive — until the reader scrolls up to read something, when it must stay
// where they put it. Scrolling back to the end picks the tail up again. A
// scroll view without an anchor kept opening at the top, so a message sent in
// the demo landed below the fold.

private struct Log: TerminalView {
    let count: Int
    let anchor: Alignment?

    var body: some TerminalView {
        ScrollView {
            VStack(spacing: 0) {
                ForEachWithID(Array(0..<count), id: \.self) { index in
                    Text("line \(index)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(anchor)
    }
}

private let viewport = 3

@MainActor
private final class Harness {
    let graph = AttributeGraph()
    let engine = FocusEngine()

    func show(_ view: some TerminalView) -> [String] {
        var buffer = CellBuffer(width: 10, height: viewport)
        let rect = Rect(x: 0, y: 0, width: 10, height: viewport)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        return (0..<viewport).map { y in
            var line = String((0..<10).map { buffer[$0, y].character })
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    func scroll(_ key: Key) {
        let node = engine.findScrollNodeAt(x: 0, y: 0, root: graph.root!)!
        _ScrollMath.mutateOffset(event: KeyEvent(key: key), axis: .vertical, node: node)
    }
}

@Suite("A scroll view anchored to its end follows it")
@MainActor
struct ScrollAnchorTests {

    @Test func itOpensOnTheEnd() {
        let harness = Harness()
        #expect(harness.show(Log(count: 6, anchor: .bottom)) == ["line 3", "line 4", "line 5"])
    }

    @Test func withoutAnAnchorItOpensAtTheTop() {
        let harness = Harness()
        #expect(harness.show(Log(count: 6, anchor: nil)) == ["line 0", "line 1", "line 2"])
    }

    @Test func itFollowsWhatArrives() {
        let harness = Harness()
        _ = harness.show(Log(count: 2, anchor: .bottom))
        _ = harness.show(Log(count: 6, anchor: .bottom))
        #expect(harness.show(Log(count: 7, anchor: .bottom)) == ["line 4", "line 5", "line 6"])
    }

    @Test func aReaderWhoScrolledAwayStaysWhereTheyAre() {
        let harness = Harness()
        _ = harness.show(Log(count: 6, anchor: .bottom))
        harness.scroll(.up)
        #expect(harness.show(Log(count: 6, anchor: .bottom)) == ["line 2", "line 3", "line 4"])
        #expect(harness.show(Log(count: 9, anchor: .bottom)) == ["line 2", "line 3", "line 4"])
    }

    @Test func returningToTheEndFollowsAgain() {
        let harness = Harness()
        _ = harness.show(Log(count: 6, anchor: .bottom))
        harness.scroll(.up)
        _ = harness.show(Log(count: 8, anchor: .bottom))
        harness.scroll(.end)
        _ = harness.show(Log(count: 8, anchor: .bottom))
        #expect(harness.show(Log(count: 10, anchor: .bottom)) == ["line 7", "line 8", "line 9"])
    }

    @Test func aCentreAnchorOpensOnTheMiddle() {
        let harness = Harness()
        #expect(harness.show(Log(count: 7, anchor: .center)) == ["line 2", "line 3", "line 4"])
    }
}
