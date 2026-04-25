import Testing
@testable import TerminalUI

// HYP-124 — Layer 3 frame-stat counters for invalidation parity tests.
//
// Layers 1 (HYP-125 reflective compare) and 2 (HYP-126 dirty drain)
// need precise instrumentation to make TDD assertions meaningful.
// This file ships first; counters are DEBUG-only so release builds
// elide them entirely.
//
// Counters live on `AttributeGraph`:
//   - bodyEvaluationCount: total composite-body evaluations since reset.
//   - rootWalkCount:       frames where graph.update walked from root.
//   - dirtyDrainCount:     frames where dirtyQueue was drained in place
//                          (placeholder zero until HYP-126 lands).

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

private struct LeafComposite: TerminalView {
    let label: String
    var body: some TerminalView { Text(label) }
}

private struct DepthThreeRoot: TerminalView {
    var body: some TerminalView {
        Mid()
    }
}

private struct Mid: TerminalView {
    var body: some TerminalView {
        Inner()
    }
}

private struct Inner: TerminalView {
    var body: some TerminalView {
        Text("inner")
    }
}

@Suite("HYP-124 — Frame-stat counters")
@MainActor
struct Hyp124FrameStatsTests {

    @Test("bodyEvaluationCount increments when a composite body runs")
    func bodyEvaluationCount_incrementsOnComposite() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: LeafComposite(label: "a"))
        #expect(graph.bodyEvaluationCount == 1,
                "single composite render should evaluate exactly one body; got \(graph.bodyEvaluationCount)")
    }

    @Test("bodyEvaluationCount counts each composite body in a depth-3 tree")
    func bodyEvaluationCount_incrementsPerLeafBody() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: DepthThreeRoot())
        // DepthThreeRoot.body → Mid.body → Inner.body → Text (primitive, no body)
        #expect(graph.bodyEvaluationCount == 3,
                "depth-3 composite chain should evaluate three bodies; got \(graph.bodyEvaluationCount)")
    }

    @Test("bodyEvaluationCount stays zero rendering only a primitive")
    func bodyEvaluationCount_doesNotIncrementOnPrimitive() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: Text("a"))
        #expect(graph.bodyEvaluationCount == 0,
                "Text is a primitive with no body; counter must stay zero; got \(graph.bodyEvaluationCount)")
    }

    @Test("rootWalkCount increments on first update")
    func rootWalkCount_incrementsOnFirstUpdate() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: LeafComposite(label: "a"))
        #expect(graph.rootWalkCount == 1,
                "first update walks from root; got \(graph.rootWalkCount)")
    }

    @Test("rootWalkCount increments on every update(from:) call")
    func rootWalkCount_incrementsPerUpdate() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: LeafComposite(label: "a"))
        graph.update(from: LeafComposite(label: "a"))
        graph.update(from: LeafComposite(label: "a"))
        #expect(graph.rootWalkCount == 3,
                "three update calls = three root walks pre-HYP-126; got \(graph.rootWalkCount)")
    }

    @Test("dirtyDrainCount stays zero before HYP-126 ships")
    func dirtyDrainCount_isZeroBeforeHYP126() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: LeafComposite(label: "a"))
        graph.update(from: LeafComposite(label: "a"))
        #expect(graph.dirtyDrainCount == 0,
                "drain path doesn't exist yet; counter must be zero; got \(graph.dirtyDrainCount)")
    }

    @Test("resetFrameStats zeros all three counters")
    func resetFrameStats_zeroesAllCounters() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: DepthThreeRoot())
        #expect(graph.bodyEvaluationCount > 0)
        #expect(graph.rootWalkCount > 0)
        graph.resetFrameStats()
        #expect(graph.bodyEvaluationCount == 0)
        #expect(graph.rootWalkCount == 0)
        #expect(graph.dirtyDrainCount == 0)
    }
}
