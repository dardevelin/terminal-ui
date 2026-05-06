import Foundation
import Testing
@testable import TerminalUI

// HYP-326 Slice 0a — FocusableContainer protocol + directional FocusEngine.move(_:)
//
// Engine-level focus primitives that the i3 family depends on. Container types
// expose their focusable children + a traversal-axis hint; FocusEngine consults
// the protocol via the AttributeNode existential — no `as?` casts to concrete
// container types. Two env values customize behaviour: focusBoundaryPolicy
// (escapeToParent / wrap / stay) and focusGranularity (container / leaf).

@Suite("FocusableContainer — engine-level directional navigation primitives")
@MainActor
struct FocusableContainerTests {

    // MARK: - Protocol conformance shape

    @Test("FocusableContainer exposes focusableChildren + traversalGeometry")
    func protocolShape() {
        // Compile-only check: the protocol requirements compile through the
        // AttributeNode existential. If the protocol shape ever drifts, this
        // test fails to compile — which is the correct red-phase signal.
        let node = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        let container: any FocusableContainer = node
        let children = container.focusableChildren()
        #expect(children.isEmpty, "fresh node has no children yet")
        let geom = container.traversalGeometry
        #expect(geom.axis == .horizontal, "horizontal split → horizontal geometry")
    }

    @Test("TraversalGeometry axis enum is exhaustive")
    func traversalGeometryAxisExhaustive() {
        let axes: [TraversalGeometry.Axis] = [.horizontal, .vertical, .both]
        for a in axes {
            switch a {
            case .horizontal: #expect(true)
            case .vertical: #expect(true)
            case .both: #expect(true)
            }
        }
    }

    @Test("Vertical split exposes vertical traversal geometry")
    func verticalSplitGeometry() {
        let node = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .layout(LayoutInfo(kind: .split(.vertical))))
        let geom = (node as any FocusableContainer).traversalGeometry
        #expect(geom.axis == .vertical)
    }

    // MARK: - Boundary policy + granularity env values

    @Test("EnvironmentValues defaults match i3 conventions")
    func envDefaults() {
        let env = EnvironmentValues()
        #expect(env.focusBoundaryPolicy == .escapeToParent,
                "i3 default: arrow at scope edge bubbles up")
        #expect(env.focusGranularity == .container,
                "SwiftUI list-row default: container is focusable as a unit")
    }

    @Test("focusBoundaryPolicy modifier sets env value through the chain")
    func boundaryPolicyModifierApplies() {
        var env = EnvironmentValues()
        let mod = EnvironmentModifier<FocusBoundaryPolicy>(
            keyPath: \EnvironmentValues.focusBoundaryPolicy,
            value: .wrap
        )
        mod.apply(to: &env)
        #expect(env.focusBoundaryPolicy == .wrap)
    }

    @Test("focusGranularity modifier sets env value through the chain")
    func granularityModifierApplies() {
        var env = EnvironmentValues()
        let mod = EnvironmentModifier<FocusGranularity>(
            keyPath: \EnvironmentValues.focusGranularity,
            value: .leaf
        )
        mod.apply(to: &env)
        #expect(env.focusGranularity == .leaf)
    }

    // MARK: - Directional move API

    @Test("move(.right) within horizontal container lands on right sibling")
    func moveRightLandsOnRightSibling() {
        // Build: split(h, [leaf(A), leaf(B)]). Both leaves focusable.
        let split = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        split.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        let a = makeFocusableLeaf(parent: split, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 5))
        let b = makeFocusableLeaf(parent: split, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 5))

        let engine = FocusEngine()
        engine.rebuildIndex(root: split)
        engine.keyboardFocusID = a.id

        engine.move(.right, root: split)
        #expect(engine.keyboardFocusID == b.id, "move right should land on B; got \(String(describing: engine.keyboardFocusID))")
    }

    @Test("move(.left) at left edge with .escapeToParent policy fires onBoundaryHit")
    func moveLeftAtLeftEdgeEscapes() {
        // Single-container case: at left edge with no parent container, the
        // engine should not move and should report the boundary.
        let split = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        split.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        let a = makeFocusableLeaf(parent: split, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 5))
        _ = makeFocusableLeaf(parent: split, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 5))

        let engine = FocusEngine()
        engine.rebuildIndex(root: split)
        engine.keyboardFocusID = a.id

        engine.move(.left, root: split)
        #expect(engine.keyboardFocusID == a.id,
                "no neighbor on the left → focus should stay on A under .escapeToParent")
    }

    @Test("move(.left) at left edge with .wrap policy lands on rightmost sibling")
    func moveLeftWrapsToRightmost() {
        let split = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        split.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        var env = EnvironmentValues()
        env.focusBoundaryPolicy = .wrap
        split._resolvedEnv = env
        let a = makeFocusableLeaf(parent: split, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 5), env: env)
        let b = makeFocusableLeaf(parent: split, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 5), env: env)

        let engine = FocusEngine()
        engine.rebuildIndex(root: split)
        engine.keyboardFocusID = a.id

        engine.move(.left, root: split)
        #expect(engine.keyboardFocusID == b.id,
                ".wrap should wrap to the rightmost sibling; got \(String(describing: engine.keyboardFocusID))")
    }

    @Test("move(.up) on horizontal-only container is a no-op (axis mismatch)")
    func moveUpOnHorizontalContainerIsNoOp() {
        let split = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        split.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        let a = makeFocusableLeaf(parent: split, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 5))
        _ = makeFocusableLeaf(parent: split, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 5))

        let engine = FocusEngine()
        engine.rebuildIndex(root: split)
        engine.keyboardFocusID = a.id

        engine.move(.up, root: split)
        #expect(engine.keyboardFocusID == a.id,
                "horizontal container has no vertical axis → focus stays put")
    }

    @Test("move(.down) crosses axis boundary up the container chain")
    func moveDownCrossesAxisBoundary() {
        // outer-vertical [ inner-horizontal [A, B], C ]
        // Focus on A. move(.down) walks up to outer-vertical, finds C as
        // next vertical sibling.
        let outer = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.vertical))))
        outer.rect = Rect(x: 0, y: 0, width: 20, height: 10)

        let inner = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        inner.parent = outer
        inner.rect = Rect(x: 0, y: 0, width: 20, height: 4)
        outer.children.append(inner)

        let a = makeFocusableLeaf(parent: inner, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 4))
        _ = makeFocusableLeaf(parent: inner, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 4))
        let c = makeFocusableLeaf(parent: outer, at: 1, rect: Rect(x: 0, y: 5, width: 20, height: 5))

        let engine = FocusEngine()
        engine.rebuildIndex(root: outer)
        engine.keyboardFocusID = a.id

        engine.move(.down, root: outer)
        #expect(engine.keyboardFocusID == c.id,
                "should escape inner-horizontal to outer-vertical and land on C; got \(String(describing: engine.keyboardFocusID))")
    }

    // MARK: - Nested boundary-policy composition

    @Test("nested containers compose boundary policy — inner .wrap stops the walk")
    func nestedContainersInnerWrapStopsWalk() {
        // outer-vertical with inner-horizontal.wrap [A, B] as its only child.
        // Focus on A. move(.left) at left edge:
        //   inner.wrap → wraps inside inner → focus lands on B.
        // The walk MUST NOT continue up to outer (outer's policy is irrelevant).
        let outer = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.vertical))))
        outer.rect = Rect(x: 0, y: 0, width: 20, height: 5)

        var innerEnv = EnvironmentValues()
        innerEnv.focusBoundaryPolicy = .wrap
        let inner = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        inner.parent = outer
        inner.rect = Rect(x: 0, y: 0, width: 20, height: 5)
        inner._resolvedEnv = innerEnv
        outer.children.append(inner)

        let a = makeFocusableLeaf(parent: inner, at: 0, rect: Rect(x: 0, y: 0, width: 9, height: 5), env: innerEnv)
        let b = makeFocusableLeaf(parent: inner, at: 1, rect: Rect(x: 11, y: 0, width: 9, height: 5), env: innerEnv)

        let engine = FocusEngine()
        engine.rebuildIndex(root: outer)
        engine.keyboardFocusID = a.id

        engine.move(.left, root: outer)
        #expect(engine.keyboardFocusID == b.id,
                "inner .wrap should wrap to B inside the inner container; got \(String(describing: engine.keyboardFocusID))")
    }

    @Test("nested containers compose boundary policy — inner .escapeToParent bubbles, outer .wrap then wraps")
    func nestedContainersBubbleThenWrap() {
        // outer-horizontal.wrap with two children:
        //   - inner-horizontal.escapeToParent [A, B]
        //   - C
        // Focus on A. move(.left) at left edge:
        //   inner is .escapeToParent → bubbles past inner.
        //   outer-horizontal handles .left axis, A's container child is `inner`,
        //   inner's index is 0 in outer.children → no left neighbor.
        //   outer is .wrap → wraps to last child C.
        var outerEnv = EnvironmentValues()
        outerEnv.focusBoundaryPolicy = .wrap
        let outer = AttributeNode(id: NodeID.root, kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        outer.rect = Rect(x: 0, y: 0, width: 30, height: 5)
        outer._resolvedEnv = outerEnv

        // Inner explicitly carries .escapeToParent (same as default, but pinned for clarity)
        var innerEnv = EnvironmentValues()
        innerEnv.focusBoundaryPolicy = .escapeToParent
        let inner = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .layout(LayoutInfo(kind: .split(.horizontal))))
        inner.parent = outer
        inner.rect = Rect(x: 0, y: 0, width: 18, height: 5)
        inner._resolvedEnv = innerEnv
        outer.children.append(inner)

        let a = makeFocusableLeaf(parent: inner, at: 0, rect: Rect(x: 0, y: 0, width: 8, height: 5), env: innerEnv)
        _ = makeFocusableLeaf(parent: inner, at: 1, rect: Rect(x: 10, y: 0, width: 8, height: 5), env: innerEnv)

        // outer's second child is C — declared after inner so outer.children = [inner, C].
        let c = AttributeNode(id: NodeID.root.appending(.index(1)), kind: .primitive(.text([])))
        c.parent = outer
        c.rect = Rect(x: 20, y: 0, width: 10, height: 5)
        c.isFocusable = true
        c._resolvedEnv = outerEnv
        outer.children.append(c)

        let engine = FocusEngine()
        engine.rebuildIndex(root: outer)
        engine.keyboardFocusID = a.id

        engine.move(.left, root: outer)
        #expect(engine.keyboardFocusID == c.id,
                "inner.escapeToParent → bubble; outer.wrap → wrap to last child C; got \(String(describing: engine.keyboardFocusID))")
    }

    // MARK: - Helpers

    private func makeFocusableLeaf(
        parent: AttributeNode,
        at index: Int,
        rect: Rect,
        env: EnvironmentValues = EnvironmentValues()
    ) -> AttributeNode {
        let leaf = AttributeNode(id: parent.id.appending(.index(index)), kind: .primitive(.text([])))
        leaf.parent = parent
        leaf.rect = rect
        leaf.isFocusable = true
        leaf._resolvedEnv = env
        parent.children.append(leaf)
        return leaf
    }
}
