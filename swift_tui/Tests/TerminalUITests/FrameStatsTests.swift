import Testing
@testable import TerminalUI

// AttributeGraph exposes three DEBUG-only frame-stat counters that
// pin the cost of one render cycle:
//
//   bodyEvaluationCount — how many composite-view bodies actually ran.
//                         Increments inside every `withObservationTracking`
//                         scope; a primitive (Text, Spacer, etc.) leaves
//                         it untouched.
//   rootWalkCount       — how many times update(from:) walked the tree
//                         from the root. The drain path bypasses this.
//   dirtyDrainCount     — how many times drain() re-evaluated dirty
//                         nodes in place without a root walk.
//
// Tests for the reflective-compare and dirty-drain features assert
// against these to prove their parity claims; this file pins the
// counters' own invariants so a regression there is caught before
// the dependent suites get blamed.

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
    var body: some TerminalView { Mid() }
}

private struct Mid: TerminalView {
    var body: some TerminalView { Inner() }
}

private struct Inner: TerminalView {
    var body: some TerminalView { Text("inner") }
}

@Suite("AttributeGraph — frame-stat counters")
@MainActor
struct FrameStatsTests {

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
                "three update calls = three root walks; got \(graph.rootWalkCount)")
    }

    @Test("dirtyDrainCount stays zero when nothing is dirty")
    func dirtyDrainCount_isZeroWithoutMutation() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.resetFrameStats()
        graph.update(from: LeafComposite(label: "a"))
        graph.update(from: LeafComposite(label: "a"))
        #expect(graph.dirtyDrainCount == 0,
                "no observable mutated → no drain; got \(graph.dirtyDrainCount)")
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
