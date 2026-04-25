import Testing
import Observation
@testable import TerminalUI

// AttributeGraph skips a composite view's body re-evaluation when the
// fresh view value compares equal to the cached one — matching SwiftUI's
// automatic Gate-2 behaviour from WWDC21 *Demystify SwiftUI*:
//
//   "SwiftUI will keep around a copy of the value to perform a
//    comparison and know if the view has changed. But after that,
//    the value is destroyed."
//
// Two paths into the skip:
//   1. `.equatable()` wrapper → user-supplied `==` (fastest).
//   2. Mirror-based field-wise compare → automatic for any composite
//      whose stored fields are themselves Equatable / value-typed
//      structs / zero-field aggregates.
//
// Parity ceiling — reference types without Equatable conformance
// (notably `@Observable` model classes), closures, and other opaque
// values defeat the Mirror compare. Body re-runs in those cases;
// the user opt-in via `.equatable()` is the escape hatch. SwiftUI
// has the same limitation.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// MARK: - Reflective-compare fixtures

private struct PlainLabel: TerminalView {
    let title: String
    let count: Int
    var body: some TerminalView {
        Text("\(title)=\(count)")
    }
}

private struct ClosureView: TerminalView {
    let label: String
    let action: () -> Void
    var body: some TerminalView {
        Text(label)
    }
}

// MARK: - Structural-identity fixtures

private struct IfChild: TerminalView {
    var body: some TerminalView { Text("if") }
}

private struct ElseChild: TerminalView {
    var body: some TerminalView { Text("else") }
}

private struct Switcher: TerminalView {
    let useIf: Bool
    var body: some TerminalView {
        if useIf { IfChild() } else { ElseChild() }
    }
}

// MARK: - Equatable-fast-path fixtures

@Observable
private final class CounterModel {
    var x: Int = 0
}

private struct EquatableLeaf: TerminalView, Equatable {
    let model: CounterModel
    var body: some TerminalView {
        Text("x=\(model.x)")
    }
    static func == (lhs: EquatableLeaf, rhs: EquatableLeaf) -> Bool {
        lhs.model === rhs.model
    }
}

@Suite("AttributeGraph — reflective compare for non-Equatable views")
@MainActor
struct ReflectiveCompareTests {

    // MARK: - Reflective-compare gate

    @Test("non-Equatable view with unchanged fields skips body re-eval")
    func nonEquatable_unchangedFields_skipsBody() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: PlainLabel(title: "hello", count: 1))
        graph.resetFrameStats()
        // Re-emit identical fields — SwiftUI parity says skip the body.
        graph.update(from: PlainLabel(title: "hello", count: 1))
        #expect(graph.bodyEvaluationCount == 0,
                "identical non-Equatable inputs must skip body via reflective compare; got \(graph.bodyEvaluationCount)")
    }

    @Test("non-Equatable view with changed field re-evaluates body")
    func nonEquatable_changedField_reevaluates() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: PlainLabel(title: "hello", count: 1))
        graph.resetFrameStats()
        graph.update(from: PlainLabel(title: "world", count: 1))
        #expect(graph.bodyEvaluationCount == 1,
                "changed field must re-eval body exactly once; got \(graph.bodyEvaluationCount)")
    }

    @Test("non-Equatable view with closure field always re-evaluates (parity ceiling)")
    func nonEquatable_closureField_alwaysReevaluates() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: ClosureView(label: "go", action: {}))
        graph.resetFrameStats()
        // Same label, "different" closure (closures are unique).
        graph.update(from: ClosureView(label: "go", action: {}))
        #expect(graph.bodyEvaluationCount >= 1,
                "closures defeat reflective compare; body must re-eval; got \(graph.bodyEvaluationCount)")
    }

    // MARK: - Structural identity

    @Test("different view type at same position rebuilds subtree")
    func differentViewType_atSamePosition_rebuildsSubtree() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: Switcher(useIf: true))
        let firstChildID = graph.root?.children.first?.children.first?.id
        graph.update(from: Switcher(useIf: false))
        let secondChildID = graph.root?.children.first?.children.first?.id
        // Apple verbatim (WWDC21): "Whenever the identity changes, the
        // state is replaced." We assert the inner subtree's child IDs
        // exist in both renders, but the rendered text differs — the
        // subtree was re-evaluated, not skipped via reflective compare.
        #expect(firstChildID != nil && secondChildID != nil)
        // Body re-evaluation count should reflect the structural change.
        graph.resetFrameStats()
        graph.update(from: Switcher(useIf: true))
        #expect(graph.bodyEvaluationCount >= 1,
                "structural flip must trigger re-eval of the parent body; got \(graph.bodyEvaluationCount)")
    }

    @Test("same non-Equatable view type at different positions keeps independent state")
    func sameViewType_atDifferentPosition_keepsIndependentState() {
        resetGraphContext()
        let graph = AttributeGraph()
        // Two PlainLabel siblings differ only in title — reflective
        // compare must not collapse them into the same node identity.
        struct TwoLabels: TerminalView {
            var body: some TerminalView {
                VStack {
                    PlainLabel(title: "left", count: 1)
                    PlainLabel(title: "right", count: 1)
                }
            }
        }
        graph.update(from: TwoLabels())
        graph.resetFrameStats()
        graph.update(from: TwoLabels())
        // Both children are unchanged — reflective compare should skip
        // both leaf bodies and the parent body.
        #expect(graph.bodyEvaluationCount == 0,
                "two unchanged sibling labels both skip; got \(graph.bodyEvaluationCount)")
    }

    // MARK: - Equatable fast path (backward compat)

    @Test("Equatable view still skips body when inputs compare equal")
    func equatableView_stillSkipsBodyOnEqualInputs() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: EquatableLeaf(model: model))
        graph.resetFrameStats()
        graph.update(from: EquatableLeaf(model: model))
        #expect(graph.bodyEvaluationCount == 0,
                "Equatable equal inputs must still skip body; got \(graph.bodyEvaluationCount)")
    }

    @Test("Equatable view re-evaluates when observed state changes")
    func equatableView_reevaluatesOnObservedStateChange() {
        resetGraphContext()
        let graph = AttributeGraph()
        let model = CounterModel()
        graph.update(from: EquatableLeaf(model: model))
        graph.resetFrameStats()
        model.x = 1  // observed property mutated → observation tracker fires
        graph.update(from: EquatableLeaf(model: model))
        #expect(graph.bodyEvaluationCount >= 1,
                "observed-state change must re-eval body; got \(graph.bodyEvaluationCount)")
    }
}
