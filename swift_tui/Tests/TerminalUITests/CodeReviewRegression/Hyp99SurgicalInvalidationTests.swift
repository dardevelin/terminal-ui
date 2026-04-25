import Testing
import Observation
@testable import TerminalUI

// HYP-99 surgical invalidation — failing tests that pin the contract
// before any code changes. Tests instrument AttributeGraph with
// debug-only counters to prove that `body` re-evaluation is bounded
// by what *actually* changed, not by the size of the tree.
//
// Two-gate model (matches SwiftUI per WWDC21/23 + SE-0395):
//   Gate 1: a composite view's body re-runs when an @Observable property
//           it accessed during its last body evaluation is mutated.
//   Gate 2: when a parent's body re-runs and emits a new child view
//           value, the child's body re-runs only when the new value
//           differs from the cached one (Equatable opt-in, fall-through
//           to "always re-evaluate" otherwise).

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// MARK: - Counter helper
//
// Tests need to know how many times each composite view's body ran.
// We expose `bodyEvaluationCount` on `AttributeGraph` (DEBUG-only,
// bumped inside `evaluateBody`). Asserting on that counter is the
// whole point of HYP-99 — we want surgical, not blanket, evaluation.

// MARK: - HYP-99 Group A: per-node Observation tracking (Gate 1)

@Observable
private final class CounterModel {
    var x: Int = 0
    var y: Int = 0
}

// Plain final class — `body` runs on MainActor at runtime, but the View
// struct is nonisolated. `@unchecked Sendable` lets us mutate from inside
// body without a MainActor annotation that would force the compiler to
// stop us.
private final class EvalRecorder: @unchecked Sendable {
    var leafACount: Int = 0
    var leafBCount: Int = 0
}

// Equatable conformance opts these leaves into HYP-99 Gate 2 short-
// circuiting via `.equatable()`. Two leaves built with the same
// (model, recorder) pair compare equal — so when a parent's body
// re-runs and the leaf's inputs haven't changed, the leaf's body
// must NOT re-run. (Without `.equatable()` the leaves fall through to
// "always re-evaluate" — backward-compat with non-Equatable views.)
private struct LeafReadingX: TerminalView, Equatable {
    let model: CounterModel
    let recorder: EvalRecorder
    var body: some TerminalView {
        recorder.leafACount += 1
        return Text("x=\(model.x)")
    }
    static func == (lhs: LeafReadingX, rhs: LeafReadingX) -> Bool {
        lhs.model === rhs.model && lhs.recorder === rhs.recorder
    }
}

private struct LeafReadingY: TerminalView, Equatable {
    let model: CounterModel
    let recorder: EvalRecorder
    var body: some TerminalView {
        recorder.leafBCount += 1
        return Text("y=\(model.y)")
    }
    static func == (lhs: LeafReadingY, rhs: LeafReadingY) -> Bool {
        lhs.model === rhs.model && lhs.recorder === rhs.recorder
    }
}

private struct TwoLeafRoot: TerminalView {
    let model: CounterModel
    let recorder: EvalRecorder
    var body: some TerminalView {
        VStack {
            LeafReadingX(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
        }
    }
}

@Suite("HYP-99 — Group A: per-node Observation (Gate 1)")
@MainActor
struct PerNodeObservationTests {

    @Test("toggling x re-evaluates only the leaf that read x; sibling untouched")
    func mutateXDoesNotReevaluateY() {
        resetGraphContext()
        let model = CounterModel()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        graph.update(from: TwoLeafRoot(model: model, recorder: recorder))
        let aAfterFirstBuild = recorder.leafACount
        let bAfterFirstBuild = recorder.leafBCount
        #expect(aAfterFirstBuild == 1, "leaf A should have run body exactly once on initial build")
        #expect(bAfterFirstBuild == 1, "leaf B should have run body exactly once on initial build")

        // Mutate x — only the leaf that read x should re-evaluate.
        model.x = 1
        graph.update(from: TwoLeafRoot(model: model, recorder: recorder))
        #expect(recorder.leafACount == 2,
                "leaf A read x; mutating x must re-run its body (got \(recorder.leafACount))")
        #expect(recorder.leafBCount == 1,
                "leaf B did not read x; mutating x must NOT re-run its body (got \(recorder.leafBCount))")
    }

    @Test("mutating an unaccessed property re-evaluates nothing (with .equatable())")
    func mutateUnaccessedPropertyEvaluatesNothing() {
        resetGraphContext()
        let model = CounterModel()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        // Only LeafReadingX is in the tree — y is never accessed.
        // `.equatable()` opts the leaf into Gate-2 short-circuit; same
        // (model, recorder) refs across updates → Equatable-equal →
        // skipped unless something this leaf observed mutated.
        graph.update(from: LeafReadingX(model: model, recorder: recorder).equatable())
        #expect(recorder.leafACount == 1)

        // Touch y — leaf's onChange tracker is registered for `\.x`,
        // not `\.y`, so it should not fire. With Gate 2 active, the
        // wrapper sees Equatable-equal inputs + clean subtree and
        // short-circuits.
        model.y = 99
        graph.update(from: LeafReadingX(model: model, recorder: recorder).equatable())
        #expect(recorder.leafACount == 1,
                "leaf A read x but not y; mutating y must NOT re-run its body (got \(recorder.leafACount))")
    }

    @Test("mutating an accessed property re-evaluates exactly once per update")
    func mutateAccessedPropertyEvaluatesOnce() {
        resetGraphContext()
        let model = CounterModel()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        // .equatable() — but this time we mutate x which the body
        // reads, so subtreeIsDirty is true and the short-circuit
        // bows out, body re-runs.
        graph.update(from: LeafReadingX(model: model, recorder: recorder).equatable())
        #expect(recorder.leafACount == 1)

        model.x = 1
        graph.update(from: LeafReadingX(model: model, recorder: recorder).equatable())
        #expect(recorder.leafACount == 2, "after mutation: count must increment by exactly 1")
    }
}

// MARK: - HYP-99 Group B: Equatable fast-path (Gate 2)
//
// When a parent re-evaluates and emits a child view value that is
// `Equatable` AND `==` the cached previous value, the child's body
// must NOT re-run. Non-Equatable views fall through to "always
// re-evaluate" — backward-compat with current behavior.
//
// API to ship: `EquatableTerminalView<Content>` wrapper + `.equatable()`
// on `TerminalView where Self: Equatable`. Mirrors SwiftUI.

private struct EquatableLeaf: TerminalView, Equatable {
    let label: String
    let recorder: EvalRecorder
    var body: some TerminalView {
        recorder.leafACount += 1
        return Text(label)
    }
    static func == (lhs: EquatableLeaf, rhs: EquatableLeaf) -> Bool {
        lhs.label == rhs.label
    }
}

private struct NonEquatableLeaf: TerminalView {
    let label: String
    let recorder: EvalRecorder
    var body: some TerminalView {
        recorder.leafBCount += 1
        return Text(label)
    }
}

@Suite("HYP-99 — Group B: Equatable fast-path (Gate 2)")
@MainActor
struct EquatableFastPathTests {

    @Test("equal Equatable inputs across updates do not re-run body")
    func equalEquatableInputsSkipReevaluation() {
        resetGraphContext()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        // Note: `.equatable()` is the API the user-facing modifier
        // exposes — analogous to SwiftUI's View.equatable(). Until the
        // modifier ships this test fails to compile (red on main).
        graph.update(from: EquatableLeaf(label: "a", recorder: recorder).equatable())
        #expect(recorder.leafACount == 1, "first build runs body once")

        // Re-emit an equal value (same label).
        graph.update(from: EquatableLeaf(label: "a", recorder: recorder).equatable())
        #expect(recorder.leafACount == 1,
                "lhs == rhs → child body must NOT re-run (got \(recorder.leafACount))")
    }

    @Test("unequal Equatable inputs re-run body")
    func unequalEquatableInputsReevaluate() {
        resetGraphContext()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        graph.update(from: EquatableLeaf(label: "a", recorder: recorder).equatable())
        #expect(recorder.leafACount == 1)

        graph.update(from: EquatableLeaf(label: "b", recorder: recorder).equatable())
        #expect(recorder.leafACount == 2, "lhs != rhs → child body must re-run")
    }

    @Test("non-Equatable views always re-run body (backward-compat)")
    func nonEquatableAlwaysReevaluates() {
        resetGraphContext()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        graph.update(from: NonEquatableLeaf(label: "a", recorder: recorder))
        #expect(recorder.leafBCount == 1)

        graph.update(from: NonEquatableLeaf(label: "a", recorder: recorder))
        #expect(recorder.leafBCount == 2,
                "non-Equatable views must re-evaluate every update — current behaviour preserved")
    }
}

// MARK: - HYP-99 Group C: frame-stat assertions
//
// One toggle in a deep subtree must NOT cause O(tree size)
// re-evaluations. After the fix, only the path from the changed
// observed property's reader (and any ancestors whose body emitted
// it) re-runs.

private struct DeepRoot: TerminalView {
    let model: CounterModel
    let recorder: EvalRecorder
    var body: some TerminalView {
        VStack {
            LeafReadingX(model: model, recorder: recorder).equatable()
            // 8 sibling leaves opted into Equatable short-circuit —
            // they must not re-evaluate when x changes (their inputs
            // haven't changed: same model, same recorder reference).
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
            LeafReadingY(model: model, recorder: recorder).equatable()
        }
    }
}

@Suite("HYP-99 — Group C: frame-stat bound checks")
@MainActor
struct FrameStatBoundsTests {

    @Test("single x-mutation re-runs only the x reader, not the 8 y-readers")
    func singleMutationDoesNotEvaluateSiblings() {
        resetGraphContext()
        let model = CounterModel()
        let recorder = EvalRecorder()
        let graph = AttributeGraph()
        graph.update(from: DeepRoot(model: model, recorder: recorder))
        #expect(recorder.leafACount == 1)
        #expect(recorder.leafBCount == 8)

        model.x = 1
        graph.update(from: DeepRoot(model: model, recorder: recorder))
        #expect(recorder.leafACount == 2,
                "the one leaf that read x must re-run")
        #expect(recorder.leafBCount == 8,
                "the 8 y-leaves did not read x; must NOT re-run (got \(recorder.leafBCount))")
    }
}
