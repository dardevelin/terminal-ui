import Observation
import Synchronization
import Testing
@testable import TerminalUI

// Observation calls `onChange` on whichever thread made the change, and an
// app may change an `@Observable` model from a background task — SwiftUI
// accepts that from `@Observable` models and updates the view. The graph is
// main-actor state, so a change made elsewhere may only leave a note for the
// main actor to act on; marking the node or touching the drain queue from the
// changing thread raced the frame that was reading them.
//
// The model here is thread-safe on its own, so any race TSan reports is the
// framework's, not the test's.

private final class LockedCounter: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storage = Mutex(0)

    var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return storage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) {
                storage.withLock { $0 = newValue }
            }
        }
    }
}

private struct CounterView: TerminalView {
    let counter: LockedCounter
    var body: some TerminalView {
        Text("value \(counter.value)")
    }
}

/// Changes the value it reads the first time its body runs — a change that
/// lands while the graph is in the middle of an update, as one from another
/// thread can.
private struct ChangesWhileUpdating: TerminalView {
    let counter: LockedCounter
    var body: some TerminalView {
        if counter.value == 0 {
            counter.value = 1
        }
        return Text("")
    }
}

private struct ReaderThenWriter: TerminalView {
    let counter: LockedCounter
    var body: some TerminalView {
        VStack {
            CounterView(counter: counter)
            ChangesWhileUpdating(counter: counter)
        }
    }
}

@MainActor
private func firstLine(of graph: AttributeGraph) -> String {
    let width = 20
    var buffer = CellBuffer(width: width, height: 2)
    guard let root = graph.root else { return "" }
    let rect = Rect(x: 0, y: 0, width: width, height: 2)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    return (0..<width).map { String(buffer[$0, 0].character) }.joined()
        .trimmingCharacters(in: .whitespaces)
}

@Suite("Observed state may change on any thread")
@MainActor
struct OffMainObservationTests {

    @Test func aChangeOnAnotherThreadLeavesTheNodesToTheMainActor() async throws {
        let counter = LockedCounter()
        let graph = AttributeGraph()
        graph.update(from: CounterView(counter: counter))
        let root = try #require(graph.root)
        #expect(!root.isDirty)

        await Task.detached { counter.value = 7 }.value

        #expect(graph.hasDirtyNodes, "the frame loop must learn there is work")
        #expect(!root.isDirty, "the changing thread must not write the node")

        #expect(graph.drain())
        #expect(firstLine(of: graph) == "value 7")
        #expect(!graph.hasDirtyNodes)
    }

    @Test func changesRacingTheFrameLoopAllReachTheScreen() async {
        let counter = LockedCounter()
        let graph = AttributeGraph()
        graph.update(from: CounterView(counter: counter))
        let changes = 2_000

        let writer = Task.detached {
            for _ in 0..<changes { counter.value += 1 }
        }
        while counter.value < changes {
            graph.drain()
            await Task.yield()
        }
        await writer.value
        graph.drain()

        #expect(firstLine(of: graph) == "value \(changes)")
        #expect(!graph.hasDirtyNodes)
    }

    @Test func aChangeDuringAnUpdateIsNotLost() throws {
        let counter = LockedCounter()
        let graph = AttributeGraph()
        graph.update(from: ReaderThenWriter(counter: counter))

        #expect(graph.hasDirtyNodes, "the reader saw 0 and the value is now 1")
        #expect(graph.drain())
        #expect(firstLine(of: graph) == "value 1")
        #expect(!graph.hasDirtyNodes)
    }
}
