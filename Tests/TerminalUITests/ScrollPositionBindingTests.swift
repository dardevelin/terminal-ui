import Testing
@testable import TerminalUI

// `.scrollPosition(id:)` took a value and re-applied it every frame, so the
// tagged view was pinned in sight: a reader could not scroll away from it.
// SwiftUI's takes a binding and is two-way — the app moves the view by
// setting it, and a reader's scroll writes back the view now in position.

private struct Rows: TerminalView {
    let position: Binding<Int?>
    let anchor: Alignment?

    var body: some TerminalView {
        ScrollView {
            VStack(spacing: 0) {
                ForEachWithID(Array(0..<20), id: \.self) { row in
                    Text("row \(row)").id(row)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: position, anchor: anchor)
    }
}

private let viewport = 4

@MainActor
private final class Harness {
    var position: Int?
    let anchor: Alignment?
    let graph = AttributeGraph()
    let engine = FocusEngine()

    init(position: Int?, anchor: Alignment? = nil) {
        self.position = position
        self.anchor = anchor
    }

    var binding: Binding<Int?> { Binding(get: { self.position }, set: { self.position = $0 }) }

    /// One frame as the runtime draws it: update, the scroll passes, render.
    func frame() -> [String] {
        var buffer = CellBuffer(width: 10, height: viewport)
        let rect = Rect(x: 0, y: 0, width: 10, height: viewport)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: Rows(position: binding, anchor: anchor))
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.adjustScrollForExplicitTarget(root: graph.root,
                                                            viewportWidth: 10, viewportHeight: viewport)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        return (0..<viewport).map { y in
            var line = String((0..<10).map { buffer[$0, y].character })
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    func wheel(_ key: Key, times: Int = 1) {
        let node = engine.findScrollNodeAt(x: 0, y: 0, root: graph.root!)!
        for _ in 0..<times {
            _ScrollMath.mutateOffset(event: KeyEvent(key: key), axis: .vertical, node: node)
        }
    }
}

@Suite(".scrollPosition(id:) with a binding is two-way")
@MainActor
struct ScrollPositionBindingTests {

    @Test func settingItBringsTheViewIntoSight() {
        let harness = Harness(position: nil)
        _ = harness.frame()
        harness.position = 10
        #expect(harness.frame() == ["row 7", "row 8", "row 9", "row 10"])
    }

    @Test func anAnchorPlacesTheView() {
        let harness = Harness(position: 10, anchor: .top)
        #expect(harness.frame() == ["row 10", "row 11", "row 12", "row 13"])
    }

    @Test func aReaderCanScrollAwayAndThePositionFollowsThem() {
        let harness = Harness(position: 10, anchor: .top)
        _ = harness.frame()
        harness.wheel(.up, times: 3)
        #expect(harness.frame() == ["row 7", "row 8", "row 9", "row 10"])
        #expect(harness.position == 7)
        #expect(harness.frame() == ["row 7", "row 8", "row 9", "row 10"])
    }

    @Test func settingItAgainAfterAScrollMovesTheView() {
        let harness = Harness(position: 10, anchor: .top)
        _ = harness.frame()
        harness.wheel(.up, times: 3)
        _ = harness.frame()
        harness.position = 15
        #expect(harness.frame() == ["row 15", "row 16", "row 17", "row 18"])
    }

    @Test func aBottomAnchorReportsTheViewAtTheBottom() {
        let harness = Harness(position: 10, anchor: .bottom)
        #expect(harness.frame() == ["row 7", "row 8", "row 9", "row 10"])
        harness.wheel(.down, times: 2)
        _ = harness.frame()
        #expect(harness.position == 12)
    }
}
