import Foundation
import Testing
@testable import TerminalUI

// Reviewer (2026-04-26): "render should not be a hidden graph-update pass.
// GeometryReader rebuilds children during render in
// Sources/TerminalUI/Graph/GraphRenderer.swift:68."
//
// Phase-separation contract: `GraphRenderer.render` reads from the
// graph and writes only to the cell buffer (and to per-node layout
// outputs like `rect` / `_resolvedEnv`). It must NOT mutate the view
// tree itself — `node.children` arrays and `node.kind` values must
// be identical before and after a render call.
//
// Today this fails for any tree containing a `GeometryReader`: the
// rebuilder closure runs during render and rewrites `node.children`.
// The fix lives in HYP-203 phase separation: GR's rebuild moves to
// the layout phase, render becomes pure.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite("Render phase purity — render must not mutate the view tree")
@MainActor
struct RenderPhasePurityTests {

    @Test("render does not change node.children identities")
    func renderPreservesChildrenArrays() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("alpha")
            Text("beta")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let snapshot = ChildIdentitySnapshot.capture(from: root)
        var buffer = CellBuffer(width: 40, height: 8)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 40, height: 8)))
        let after = ChildIdentitySnapshot.capture(from: root)
        #expect(snapshot == after,
                "render must not change any node's children-identity chain")
    }

    @Test("render does not mutate node.kind values")
    func renderPreservesKinds() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("a"); Text("b"); Text("c")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let kindsBefore = collectKindDescriptions(from: root)
        var buffer = CellBuffer(width: 30, height: 4)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 4)))
        let kindsAfter = collectKindDescriptions(from: root)
        #expect(kindsBefore == kindsAfter,
                "render must not change any node's NodeKind")
    }

    @Test("GeometryReader render does not rewrite node.children")
    func geometryReaderRenderIsPure() {
        resetGraphContext()
        let graph = AttributeGraph()
        // GR's child closure depends on size. Today GraphRenderer.render
        // calls the rebuilder, which writes back into node.children.
        // Phase-separation contract requires that to move to layout.
        graph.update(from: GeometryReader { size in
            Text("\(size.width)x\(size.height)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let snapshot = ChildIdentitySnapshot.capture(from: root)
        var buffer = CellBuffer(width: 32, height: 6)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 32, height: 6)))
        let after = ChildIdentitySnapshot.capture(from: root)
        #expect(snapshot == after,
                "GeometryReader's child rebuild must run before render, not during render")
    }

    @Test("render does not trigger body re-evaluation (composite GR child)")
    func renderDoesNotReEvaluateBodies() {
        resetGraphContext()
        let graph = AttributeGraph()
        // The GR's child is a composite (HeadlessRow) so re-evaluating
        // its body is observable via bodyEvaluationCount.
        graph.update(from: GeometryReader { _ in
            _HeadlessRow(label: "purity-probe")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        #if DEBUG
        let before = graph.bodyEvaluationCount
        var buffer = CellBuffer(width: 30, height: 4)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 4)))
        let after = graph.bodyEvaluationCount
        #expect(after == before,
                "render must not trigger body re-evaluation; bodyEvaluationCount went \(before) → \(after)")
        #endif
    }

    @Test("render does not trigger graph reconciliation (existing child updated through update path)")
    func renderDoesNotReconcile() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            Text("\(size.width)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        #if DEBUG
        let beforeRoot = graph.rootWalkCount
        let beforeDrain = graph.dirtyDrainCount
        var buffer = CellBuffer(width: 30, height: 4)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 4)))
        #expect(graph.rootWalkCount == beforeRoot,
                "render must not call update(from:); rootWalkCount drift indicates render → reconcile leak")
        #expect(graph.dirtyDrainCount == beforeDrain,
                "render must not invoke drain(); dirtyDrainCount drift indicates render → drain leak")
        #endif
    }

    @Test("render does not invoke rebuilder when layout has already placed the GR")
    func renderDoesNotInvokeRebuilderAfterLayout() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            Text("\(size.width)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        // Layout pass first — production runtime always does this.
        Layout.measureAndPlace(graph: root, in: Rect(x: 0, y: 0, width: 30, height: 4))

        let gr = findGeometryReaderNode(from: root)!
        let originalRebuild = gr.geometryRebuilder!
        let counter = RebuildCounter()
        gr.geometryRebuilder = { size, parent in
            counter.bump()
            originalRebuild(size, parent)
        }
        var buffer = CellBuffer(width: 30, height: 4)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 4)))
        #expect(counter.value == 0,
                "after Layout.measureAndPlace, render must not invoke geometryRebuilder; got \(counter.value)")
    }

    @Test("repeated render calls produce identical output (no first-call-mutates-second)")
    func repeatedRenderIsIdempotent() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            VStack {
                Text("size: \(size.width)x\(size.height)")
                Text("static row")
            }
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        var buffer1 = CellBuffer(width: 30, height: 6)
        GraphRenderer.render(root, into: &buffer1, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 6)))
        let snapAfterFirst = ChildIdentitySnapshot.capture(from: root)

        var buffer2 = CellBuffer(width: 30, height: 6)
        GraphRenderer.render(root, into: &buffer2, context: .init(rect: Rect(x: 0, y: 0, width: 30, height: 6)))
        let snapAfterSecond = ChildIdentitySnapshot.capture(from: root)

        #expect(snapAfterFirst == snapAfterSecond,
                "second render must observe the same tree the first render produced — render is pure")
    }
}

/// Captures a tree's children-identity chain for before/after comparison.
/// Equality means every node in the tree has the same children pointers
/// (ObjectIdentifier) in the same order. A render that rewrites
/// node.children breaks this; a pure render preserves it.
private struct ChildIdentitySnapshot: Equatable {
    let entries: [Entry]

    struct Entry: Equatable {
        let nodeIdentity: ObjectIdentifier
        let childIdentities: [ObjectIdentifier]
    }

    static func capture(from root: AttributeNode) -> ChildIdentitySnapshot {
        var entries: [Entry] = []
        walk(root, into: &entries)
        return ChildIdentitySnapshot(entries: entries)
    }

    private static func walk(_ node: AttributeNode, into entries: inout [Entry]) {
        entries.append(Entry(
            nodeIdentity: ObjectIdentifier(node),
            childIdentities: node.children.map(ObjectIdentifier.init)
        ))
        for child in node.children {
            walk(child, into: &entries)
        }
    }
}

private func collectKindDescriptions(from node: AttributeNode) -> [String] {
    var result: [String] = []
    walkKinds(node, into: &result)
    return result
}

private func walkKinds(_ node: AttributeNode, into result: inout [String]) {
    result.append(node.kind.debugName)
    for child in node.children {
        walkKinds(child, into: &result)
    }
}

/// Composite view for the GR-purity probe. Body evaluation counts
/// against `AttributeGraph.bodyEvaluationCount` so a render-time
/// rebuild surfaces as drift in that counter.
private struct _HeadlessRow: TerminalView {
    let label: String
    var body: some TerminalView {
        Text(label)
    }
}

/// Counts how many times a wrapped geometryRebuilder fires. Used by
/// the render-purity test to assert render does NOT invoke rebuilders.
@MainActor
private final class RebuildCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// Walk the tree finding the first node carrying a geometryRebuilder.
@MainActor
private func findGeometryReaderNode(from node: AttributeNode) -> AttributeNode? {
    if node.geometryRebuilder != nil { return node }
    for child in node.children {
        if let found = findGeometryReaderNode(from: child) { return found }
    }
    return nil
}
