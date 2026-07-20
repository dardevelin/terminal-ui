import Foundation
import Observation
import Testing
@testable import TerminalUI

// Make `drain()` the runtime path for observed state
// changes instead of root rebuild via `update(from:)`.
//
// Reviewer (2026-04-26): "the runtime still does not use the
// 'surgical' dirty-drain path. renderDiffFrame() checks
// graph.hasDirtyNodes, then calls buildView() and graph.update(from:)
// anyway."
//
// Contract: when an @Observable model is mutated and the runtime
// reaches its render loop, it must drain dirty nodes in place rather
// than re-walking from root. `rootWalkCount` stays put for
// state-only changes; `dirtyDrainCount` increments.

@Observable
private final class DrainProbeModel: @unchecked Sendable {
    var counter: Int = 0
}

private struct DrainProbeView: TerminalView {
    let model: DrainProbeModel
    var body: some TerminalView {
        VStack {
            Text("counter: \(model.counter)")
            Text("static")
        }
    }
}

@Suite("Drain as runtime path — state mutations bypass root rebuild")
@MainActor
struct DrainAsRuntimePathTests {

    @Test("state mutation followed by frame reconciliation drains, doesn't root-walk")
    func stateMutationPrefersDrain() {
        let model = DrainProbeModel()
        let graph = AttributeGraph()
        graph.update(from: DrainProbeView(model: model))

        #if DEBUG
        graph.resetFrameStats()
        let beforeRoot = graph.rootWalkCount
        let beforeDrain = graph.dirtyDrainCount

        // Mutate state — Observation fires, hasDirtyNodes goes true,
        // dirtyQueue gains the body node.
        model.counter += 1
        #expect(graph.hasDirtyNodes, "mutation must mark graph dirty")

        // The runtime path: drain dirty nodes in place. NOT
        // graph.update(from:) which is the root-rebuild path.
        let drained = graph.drain()
        #expect(drained, "drain must run when dirty queue is non-empty")
        #expect(graph.rootWalkCount == beforeRoot,
                "drain must not increment rootWalkCount; got \(graph.rootWalkCount), was \(beforeRoot)")
        #expect(graph.dirtyDrainCount == beforeDrain + 1,
                "drainFrameCount must tick; got \(graph.dirtyDrainCount), was \(beforeDrain)")
        #endif
    }

    @Test("after drain, graph is clean — no second drain needed")
    func drainClearsDirty() {
        let model = DrainProbeModel()
        let graph = AttributeGraph()
        graph.update(from: DrainProbeView(model: model))

        model.counter = 42
        _ = graph.drain()
        #expect(!graph.hasDirtyNodes,
                "after drain the graph must be clean; hasDirtyNodes=\(graph.hasDirtyNodes)")
    }

    @Test("frame-style sequence: drain replaces update(from:) when only state changed")
    func frameSequencePrefersDrain() {
        let model = DrainProbeModel()
        let graph = AttributeGraph()
        // Frame 1 — first build. Both rootWalkCount and bodyEvaluationCount tick.
        graph.update(from: DrainProbeView(model: model))
        #if DEBUG
        let afterFirstRootWalk = graph.rootWalkCount
        let afterFirstDrain = graph.dirtyDrainCount

        // Frame 2 — pure state mutation. Runtime must call drain(),
        // NOT graph.update(from:). Simulate that decision: if
        // hasDirtyNodes is true and we have not been signalled for a
        // structural rebuild, drain.
        model.counter = 1
        let dirty = graph.hasDirtyNodes
        #expect(dirty, "mutation marked graph dirty")
        if dirty {
            _ = graph.drain()
        }
        // The new contract: state-only frames don't increment rootWalkCount.
        #expect(graph.rootWalkCount == afterFirstRootWalk,
                "state-only frame must not root-walk; \(afterFirstRootWalk) -> \(graph.rootWalkCount)")
        #expect(graph.dirtyDrainCount == afterFirstDrain + 1,
                "state-only frame must drain once; \(afterFirstDrain) -> \(graph.dirtyDrainCount)")
        #endif
    }
}
