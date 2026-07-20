import Testing
import Observation
@testable import TerminalUI

// `GraphMeasurer.containsViewBody(_:)` used to be a recursive
// descendant walk on every measurement call. For deep trees that
// was a real cost on the measurement hot path. The fix caches the
// result on AttributeNode and stamps it bottom-up at the end of
// every `AttributeGraph.update(from:)` so reads during the render
// walk are O(1).

@Suite("GraphMeasurer.containsViewBody — cache")
@MainActor
struct BodyContainmentCacheTests {

    @Test("post-update walk count is zero for repeated reads")
    func cachedReadsDoNotWalk() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b"); Text("c") })
        guard let root = graph.root else {
            Issue.record("no root after update")
            return
        }

        #if DEBUG
        GraphMeasurer.containsViewBodyWalkCount = 0
        // Three reads in a row must not perform any descendant walks
        // once the post-update stamp has filled `_containsViewBody`.
        _ = GraphMeasurer._containsViewBodyForTesting(root)
        _ = GraphMeasurer._containsViewBodyForTesting(root)
        _ = GraphMeasurer._containsViewBodyForTesting(root)
        #expect(
            GraphMeasurer.containsViewBodyWalkCount == 0,
            "Cached reads must short-circuit at the stamped value, not walk descendants"
        )
        #endif
    }

    @Test("answer matches uncached truth on a primitives-only tree")
    func primitivesOnlyTree() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        guard let root = graph.root else {
            Issue.record("no root after update")
            return
        }
        #if DEBUG
        let cached = GraphMeasurer._containsViewBodyForTesting(root)
        // No composite views in this tree → no .viewBody descendants.
        #expect(cached == false, "VStack of two Text primitives has no viewBody descendants")
        #endif
    }

    @Test("drain() re-stamps after a body re-evaluation")
    func drainRefreshesCache() {
        let graph = AttributeGraph()
        let bindable = _ConditionalHarnessState()
        graph.update(from: _ConditionalHarness(state: bindable))
        guard let root = graph.root else {
            Issue.record("no root after first build")
            return
        }
        #if DEBUG
        // First build with `showInner == false`: the harness's body
        // returns just a primitive, so the only `.viewBody` in the
        // tree is the root composite itself. Toggle to true and
        // re-render — the inner composite now lives under the root.
        let firstAnswer = GraphMeasurer._containsViewBodyForTesting(root)
        #expect(firstAnswer == true, "root composite is itself a viewBody node")
        bindable.showInner = true
        _ = graph.drain()
        // After drain, the cache must reflect the new structure even
        // though `update(from:)` did not run.
        let secondAnswer = GraphMeasurer._containsViewBodyForTesting(root)
        #expect(secondAnswer == true, "drain must keep the cache truthful for the new tree")
        #endif
    }

    @Test("structural change re-stamps on next update")
    func structuralChangeRefreshesCache() {
        let graph = AttributeGraph()
        // First build: primitives only.
        graph.update(from: VStack { Text("a"); Text("b") })
        guard let firstRoot = graph.root else {
            Issue.record("no root")
            return
        }
        #if DEBUG
        #expect(
            GraphMeasurer._containsViewBodyForTesting(firstRoot) == false,
            "primitives-only tree must report false"
        )
        #endif

        // Second build: introduce a composite (PromptInput is a known
        // .viewBody-producing component). The post-update walk must
        // re-stamp; old `_containsViewBody = false` cache must not
        // survive the structural change.
        let bindable = _CompositeHarnessState()
        graph.update(from: VStack {
            Text("a")
            _CompositeHarness(state: bindable)
        })
        guard let secondRoot = graph.root else {
            Issue.record("no root after second update")
            return
        }
        #if DEBUG
        #expect(
            GraphMeasurer._containsViewBodyForTesting(secondRoot) == true,
            "tree with a composite descendant must report true after re-stamp"
        )
        #endif
    }
}

// Minimal composite that produces a `.viewBody` graph node — wraps a
// primitive in a body so the build pipeline emits the viewBody kind
// for the wrapper.
@Observable
private final class _CompositeHarnessState {
    var label: String = "harness"
}

private struct _CompositeHarness: TerminalView {
    let state: _CompositeHarnessState
    var body: some TerminalView {
        Text(state.label)
    }
}

@Observable
private final class _ConditionalHarnessState {
    var showInner: Bool = false
}

private struct _ConditionalHarness: TerminalView {
    let state: _ConditionalHarnessState
    var body: some TerminalView {
        VStack {
            Text("outer")
            if state.showInner {
                _CompositeHarness(state: _CompositeHarnessState())
            }
        }
    }
}
