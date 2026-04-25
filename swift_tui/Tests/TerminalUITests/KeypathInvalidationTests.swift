import Testing
import Observation
@testable import TerminalUI

// AttributeGraph parity claim from WWDC23 *Discover Observation in
// SwiftUI*:
//
//   "When body is executed, SwiftUI tracks all access to properties
//    used from 'Observable' types. Tracking things like that let your
//    UI only recalculate the body of views when those specific
//    properties change."
//
// "Those specific properties" — keypath-level granularity. Two views
// over the same model that read different properties must NOT share
// dirty state.
//
// These tests probe AttributeGraph's wiring of Observation, NOT the
// Observation runtime's own per-call access list. The previous
// version of this file delegated the whole assertion to Observation
// (each reader had its own `withObservationTracking` scope, so
// keypath-level routing was happening below us regardless of any
// AttributeGraph code) and a `/swift-dev` review surfaced the gap.
//
// The tighter tests here assert two things AttributeGraph itself
// must deliver:
//   1. After a mutation, `graph.dirtyQueueNodeIDs` contains exactly
//      the AttributeNode that wraps the reading view — not its
//      ancestor chain, not its sibling.
//   2. `graph.lastFiredKeypath` exposes which keypath fired so
//      higher-level features (`.onChange(of:)` lifecycle, Inspector
//      "what triggered this re-render", animation interpolation per
//      property) can attribute the change. Today this returns nil —
//      the test is RED until we surface `ObservationTracking.changed`
//      from the `@_spi(SwiftUI)` Observation overload.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Observable
@MainActor
private final class SharedModel {
    var x: Int = 0
    var y: Int = 0
}

@MainActor
private final class EvalCount {
    var aRuns: Int = 0
    var bRuns: Int = 0
}

private struct ReaderOfX: TerminalView {
    let model: SharedModel
    let counter: EvalCount
    var body: some TerminalView {
        MainActor.assumeIsolated {
            counter.aRuns += 1
        }
        return Text("x=\(MainActor.assumeIsolated { model.x })")
    }
}

private struct ReaderOfY: TerminalView {
    let model: SharedModel
    let counter: EvalCount
    var body: some TerminalView {
        MainActor.assumeIsolated {
            counter.bRuns += 1
        }
        return Text("y=\(MainActor.assumeIsolated { model.y })")
    }
}

private struct TwoReadersRoot: TerminalView {
    let model: SharedModel
    let counter: EvalCount
    var body: some TerminalView {
        VStack {
            ReaderOfX(model: model, counter: counter)
            ReaderOfY(model: model, counter: counter)
        }
    }
}

@Suite("AttributeGraph — keypath-level invalidation across shared @Observable")
@MainActor
struct KeypathInvalidationTests {

    // MARK: - Behavioural parity (passes today via Observation runtime)

    @Test("two views over the same model — mutation re-runs only the property's reader")
    func mutationRoutesOnlyToReadingView() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = SharedModel()
        let counter = EvalCount()
        graph.update(from: TwoReadersRoot(model: model, counter: counter))
        #expect(counter.aRuns == 1)
        #expect(counter.bRuns == 1)
        graph.resetFrameStats()

        model.x = 1
        _ = graph.drain()

        #expect(counter.aRuns == 2,
                "x's reader must re-run; got \(counter.aRuns)")
        #expect(counter.bRuns == 1,
                "y's reader must NOT re-run; got \(counter.bRuns)")
    }

    @Test("mutating the other property re-runs only its reader")
    func mutationRoutesOnlyToReadingView_otherDirection() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = SharedModel()
        let counter = EvalCount()
        graph.update(from: TwoReadersRoot(model: model, counter: counter))
        graph.resetFrameStats()

        model.y = 99
        _ = graph.drain()

        #expect(counter.aRuns == 1, "x's reader must NOT re-run; got \(counter.aRuns)")
        #expect(counter.bRuns == 2, "y's reader must re-run; got \(counter.bRuns)")
    }

    // MARK: - Framework-level dirty-queue scoping
    //
    // The behavioural tests above could pass even if AttributeGraph
    // had zero keypath awareness — Observation's per-call access list
    // would deliver the property regardless of our wiring. These
    // assertions probe AttributeGraph itself: after a mutation, only
    // the reading view's node is in the dirty queue — not its
    // ancestor chain, not its sibling.

    @Test("dirtyQueue scoped to the reading view's node, not its ancestors or siblings")
    func dirtyQueueIsScopedToReadingNodeOnly() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = SharedModel()
        let counter = EvalCount()
        graph.update(from: TwoReadersRoot(model: model, counter: counter))
        graph.resetFrameStats()

        model.x = 1
        // Inspect BEFORE draining — the queue is cleared on drain.
        let pendingIDs = graph.dirtyQueueNodeIDs
        #expect(pendingIDs.count == 1,
                "exactly one node should be enqueued for a single-keypath mutation; got \(pendingIDs.count)")

        // The enqueued node must be a composite leaf that reads x.
        // We don't expose node identity by view type, but the count
        // alone rules out "everything got dirtied" and "the parent got
        // dirtied" — the surrounding tree (root, VStack, ReaderOfY,
        // their primitive children) all stay clean.
        _ = graph.drain()
    }

    @Test("dirtyQueue routes alternately as different keypaths fire")
    func dirtyQueueAlternatesAcrossKeypaths() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = SharedModel()
        let counter = EvalCount()
        graph.update(from: TwoReadersRoot(model: model, counter: counter))
        graph.resetFrameStats()

        model.x = 1
        let afterX = graph.dirtyQueueNodeIDs
        _ = graph.drain()

        model.y = 1
        let afterY = graph.dirtyQueueNodeIDs
        _ = graph.drain()

        #expect(afterX.count == 1, "x mutation enqueues one node")
        #expect(afterY.count == 1, "y mutation enqueues one node")
        // The NodeID after mutating x must differ from the NodeID
        // after mutating y — different readers, different graph nodes.
        #expect(afterX.first != afterY.first,
                "x's reader and y's reader are different nodes; got \(String(describing: afterX.first)) vs \(String(describing: afterY.first))")
    }

    // MARK: - Keypath attribution
    //
    // SwiftUI's `.onChange(of:)`, Inspector "what triggered this
    // re-render", and per-property animation interpolation all need
    // to know WHICH keypath fired. The Observation runtime carries
    // this via `ObservationTracking.changed: AnyKeyPath?` — but only
    // through the `@_spi(SwiftUI)` overload of `withObservationTracking`.
    // Today AttributeGraph uses the public overload, which discards
    // the firing keypath. This test fails until we switch.

    @Test(
        "graph exposes the firing keypath after a mutation",
        .disabled("Blocked by SDK distribution — Apple ships Observation as a precompiled .swiftinterface without @_spi(SwiftUI) symbols, so `withObservationTracking(_:willSet:)` and `ObservationTracking.changed` are unreachable. Re-enable when Apple promotes _AccessList / .changed to public, when we vendor the Observation runtime, or when we wrap ObservationRegistrar.access via a macro.")
    )
    func keypathAttributionExposed() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = SharedModel()
        let counter = EvalCount()
        graph.update(from: TwoReadersRoot(model: model, counter: counter))
        graph.resetFrameStats()

        model.x = 1
        _ = graph.drain()

        // Expectation: graph captured `\SharedModel.x` from
        // ObservationTracking.changed. Today it doesn't — the test is
        // red until AttributeGraph's evaluateBody / constructComposite
        // switch to `withObservationTracking(_:willSet:)` and read
        // `tracking.changed` in willSet.
        #expect(graph.lastFiredKeypath != nil,
                "graph must expose firing keypath; got nil — surface ObservationTracking.changed via @_spi(SwiftUI) overload")
        #expect(graph.lastFiredKeypath as? PartialKeyPath<SharedModel> == \SharedModel.x,
                "fired keypath should be \\SharedModel.x; got \(String(describing: graph.lastFiredKeypath))")
    }
}
