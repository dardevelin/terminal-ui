import Testing
@testable import TerminalUI

// A press, motion with the button held, and the release: nothing in the
// framework followed them. A press only clicked, so a scrollbar's thumb, a
// split's divider and a slider's knob could be clicked but never dragged,
// and an app had no drag to declare.

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let update: (AttributeGraph) -> Void
    let width: Int
    let height: Int

    init<V: TerminalView>(width: Int = 30, height: Int = 6, _ view: @escaping () -> V) {
        self.update = { graph in graph.update(from: view()) }
        self.width = width
        self.height = height
        frame()
    }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { update(graph) }
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: graph.root!)
        return (0..<height).map { y in (0..<width).map { String(buffer[$0, y].character) }.joined() }
    }

    /// Press at `from`, drag through `path`, release at the last point.
    func drag(from: (Int, Int), through path: [(Int, Int)]) {
        engine.handlePress(PointerPress(x: from.0, y: from.1), root: graph.root)
        frame()
        for (x, y) in path {
            engine.continueDrag(x: x, y: y)
            frame()
        }
        let end = path.last ?? from
        engine.endDrag(x: end.0, y: end.1)
        frame()
    }
}

@MainActor
private final class Drags {
    var changed: [DragGesture.Value] = []
    var ended: [DragGesture.Value] = []
}

@Suite("A drag follows the pointer")
@MainActor
struct DragGestureTests {

    private func draggable(_ drags: Drags, minimumDistance: Int = 1) -> some TerminalView {
        VStack(spacing: 0) {
            Text("above")
            Text("handle")
                .gesture(DragGesture(minimumDistance: minimumDistance)
                    .onChanged { drags.changed.append($0) }
                    .onEnded { drags.ended.append($0) })
        }
    }

    @Test func aDragReportsWhereItStartedAndWhereItIs() {
        let drags = Drags()
        let screen = Screen { self.draggable(drags) }
        screen.drag(from: (2, 1), through: [(4, 1), (6, 3)])
        #expect(drags.changed.map(\.location) == [Point(x: 4, y: 0), Point(x: 6, y: 2)])
        #expect(drags.changed.last?.startLocation == Point(x: 2, y: 0))
        #expect(drags.changed.last?.translation == Size(width: 4, height: 2))
        #expect(drags.ended.map(\.location) == [Point(x: 6, y: 2)])
    }

    @Test func aPressThatDoesNotMoveIsNoDrag() {
        let drags = Drags()
        let screen = Screen { self.draggable(drags) }
        screen.drag(from: (2, 1), through: [(2, 1)])
        #expect(drags.changed.isEmpty)
        #expect(drags.ended.isEmpty)
    }

    @Test func aDragWithNoMinimumBeginsAtThePress() {
        let drags = Drags()
        let screen = Screen { self.draggable(drags, minimumDistance: 0) }
        screen.drag(from: (2, 1), through: [])
        #expect(drags.changed.map(\.location) == [Point(x: 2, y: 0)])
        #expect(drags.ended.count == 1)
    }

    @Test func aPressBesideTheViewBeginsNoDrag() {
        let drags = Drags()
        let screen = Screen { self.draggable(drags) }
        screen.drag(from: (2, 0), through: [(5, 1)])
        #expect(drags.changed.isEmpty)
    }

    @Test func aDragDraggingASliderSlidesItsValue() {
        let model = DragValue(0)
        let screen = Screen(width: 40, height: 1) {
            Slider(value: model.binding, in: 0...100, label: "Vol")
        }
        let row = screen.frame()[0]
        let track = row.distance(from: row.startIndex, to: row.firstIndex(of: "─") ?? row.startIndex)
        screen.drag(from: (track, 0), through: [(track + 5, 0), (track + 30, 0)])
        #expect(model.value == 100, "dragged past the end, the slider stops at its maximum")
        screen.drag(from: (0, 0), through: [(track + 2, 0)])
        #expect(model.value == 100, "a drag from the label slides nothing")
    }
}

@MainActor
private final class DragValue {
    var value: Double
    init(_ value: Double) { self.value = value }
    var binding: Binding<Double> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

@Suite("A divider drags, and a scrollbar")
@MainActor
struct BuiltInDragTests {

    @Test func draggingADividerResizesThePanesAndWritesTheRatios() {
        let state = SplitState(root: .split(axis: .horizontal,
                                            children: [.leaf(Text("left")), .leaf(Text("right"))],
                                            ratios: [0.5, 0.5]))
        let screen = Screen(width: 31, height: 2) { SplitView(state: state) }
        let row = screen.frame()[0]
        let divider = row.distance(from: row.startIndex, to: row.firstIndex(of: "│")!)
        screen.drag(from: (divider, 0), through: [(divider + 3, 0), (20, 1)])
        let after = screen.frame()[0]
        #expect(after.distance(from: after.startIndex, to: after.firstIndex(of: "│")!) == 20)
        guard case .split(_, _, let ratios) = state.root else { Issue.record("not a split"); return }
        #expect(ratios[0] > 0.6)
    }

    @Test func draggingAlongAScrollbarScrolls() {
        let screen = Screen(width: 20, height: 4) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEachWithID(0..<40, id: \.self) { Text("row \($0)") }
                }
            }
        }
        // The track's second cell, then down past its last.
        screen.drag(from: (19, 1), through: [(19, 2), (19, 9)])
        #expect(screen.frame()[3].hasPrefix("row 39"))
        screen.drag(from: (19, 2), through: [(19, 0)])
        #expect(screen.frame()[0].hasPrefix("row 0"))
    }

    @Test func ratiosPlaceEveryPaneAtTheSizeDraggedTo() {
        for available in 2...90 {
            for first in 1..<available {
                let sizes = [first, available - first]
                let state = SplitState(root: .split(axis: .horizontal,
                                                    children: [.leaf(Text("a")), .leaf(Text("b"))],
                                                    ratios: Layout.splitRatios(placing: sizes)))
                let graph = AttributeGraph()
                graph.update(from: SplitView(state: state))
                Layout.measureAndPlace(graph: graph.root!, in: Rect(x: 0, y: 0, width: available + 1, height: 1))
                #expect(graph.root!.children.map(\.rect.width) == sizes, "\(sizes) in \(available + 1)")
            }
        }
    }
}
