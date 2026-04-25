import Testing
import Observation
@testable import TerminalUI

// AttributeGraph re-evaluates dirty bodies *in place* without walking
// the tree from root. This matches SwiftUI's behaviour per WWDC23
// *Discover Observation in SwiftUI*:
//
//   "When body is executed, SwiftUI tracks all access to properties
//    used from 'Observable' types. Tracking things like that let your
//    UI only recalculate the body of views when those specific
//    properties change."
//   "If a property that is used changes, the view will update."
//
// Mechanism: every per-node `withObservationTracking` `onChange`
// enqueues the dirty node into `graph.dirtyQueue`. `graph.drain()`
// re-evaluates exactly those nodes — bounded by the number of
// observable mutations, not the size of the tree. The root walk
// (`graph.update(from:)`) is reserved for first frame and structural
// rebuilds.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Observable
private final class CounterModel {
    var x: Int = 0
}

private struct LeafReadingX: TerminalView {
    let model: CounterModel
    var body: some TerminalView {
        Text("x=\(model.x)")
    }
}

private struct DepthFiveContainer: TerminalView {
    let model: CounterModel
    var body: some TerminalView {
        VStack {
            VStack {
                VStack {
                    VStack {
                        LeafReadingX(model: model)
                    }
                }
            }
        }
    }
}

@Suite("AttributeGraph — in-place dirty drain")
@MainActor
struct DirtyDrainTests {

    // MARK: - Drain mechanics

    @Test("first frame walks from root")
    func firstFrame_doesRootWalk() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        let model = CounterModel()
        graph.update(from: LeafReadingX(model: model))
        #expect(graph.rootWalkCount == 1, "first build must walk from root; got \(graph.rootWalkCount)")
        #expect(graph.dirtyDrainCount == 0, "no drain on first build; got \(graph.dirtyDrainCount)")
    }

    @Test("mutating leaf observable populates dirty queue, drain re-evaluates leaf only")
    func mutateLeafState_dirtyQueueDrainsLeafOnly() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: DepthFiveContainer(model: model))
        graph.resetFrameStats()

        model.x = 1  // Gate 1 — synchronous markDirty fires on the leaf

        // The drain entry point handles the next frame in place.
        let drained = graph.drain()
        #expect(drained == true, "drain must report work was done")
        #expect(graph.dirtyDrainCount == 1, "exactly one drain frame; got \(graph.dirtyDrainCount)")
        #expect(graph.rootWalkCount == 0, "drain must not walk from root; got \(graph.rootWalkCount)")
        // Leaf re-eval is bounded — only the leaf body runs, not the
        // 5 ancestor composite bodies.
        #expect(graph.bodyEvaluationCount == 1,
                "exactly one body re-evaluation (the dirty leaf); got \(graph.bodyEvaluationCount)")
    }

    @Test("sustained leaf mutations produce N drain frames, zero root walks")
    func mutateLeafState_otherFramesNoWalk() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: DepthFiveContainer(model: model))
        graph.resetFrameStats()

        for i in 1...5 {
            model.x = i
            _ = graph.drain()
        }

        #expect(graph.dirtyDrainCount == 5, "5 mutations → 5 drains; got \(graph.dirtyDrainCount)")
        #expect(graph.rootWalkCount == 0, "no root walks during sustained drains; got \(graph.rootWalkCount)")
    }

    @Test("drain returns false and bumps no counter when queue is empty")
    func emptyQueue_drainNoOps() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: LeafReadingX(model: model))
        graph.resetFrameStats()

        let drained = graph.drain()
        #expect(drained == false, "no dirty nodes → drain reports nothing happened")
        #expect(graph.dirtyDrainCount == 0)
        #expect(graph.bodyEvaluationCount == 0)
    }

    // MARK: - Surgical-cost invariants

    @Test("single leaf mutation in deep tree re-evaluates exactly one body")
    func bodyEval_singleLeafMutation_isOne() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: DepthFiveContainer(model: model))
        graph.resetFrameStats()

        model.x = 42
        _ = graph.drain()

        #expect(graph.bodyEvaluationCount == 1,
                "SwiftUI parity: only the dirty body runs, regardless of tree depth; got \(graph.bodyEvaluationCount)")
    }

    @Test("two mutations on same leaf within one frame dedupe to a single body run")
    func bodyEval_multipleLeafMutations_dedupesPerFrame() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: LeafReadingX(model: model))
        graph.resetFrameStats()

        model.x = 1
        model.x = 2
        _ = graph.drain()

        #expect(graph.bodyEvaluationCount == 1,
                "two mutations + one drain → one body run; got \(graph.bodyEvaluationCount)")
    }

    // MARK: - Tree integrity post-drain
    //
    // Drain re-evaluates bodies in place — root and the surviving
    // subtree must persist across drains so downstream layout, focus,
    // and lifecycle bookkeeping all stay valid.

    @Test("graph remains layout-queryable after drain")
    func graphRemainsLayoutQueryableAfterDrain() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: LeafReadingX(model: model))
        let initialRoot = graph.root
        #expect(initialRoot != nil)

        model.x = 99
        _ = graph.drain()

        #expect(graph.root === initialRoot, "drain must not replace root; got \(String(describing: graph.root))")
        #expect(graph.root?.children.isEmpty == false, "root must still have its body subtree after drain")
    }
}
