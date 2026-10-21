import Foundation
import Testing
@testable import TerminalUI

// HYP-277 (i3 epic Slice 1) — tree-as-state SwiftUI-shaped split
// layout primitive. Recursive SplitNode enum, @Observable SplitState,
// SplitView consumer view + native LayoutKind.split(SplitAxis) graph
// primitive with ratio-based child distribution.
//
// This slice ships fixed ratios at construction time. Mutation API,
// nested splits, mouse-resize, and i3 hotkeys come in slices 2-7.
// Layer-2 layout/render contract from HYP-204 Layer 2 is preserved:
// Layout.measureAndPlace stamps child.rect; render reads pre-stamped
// rects and draws content + dividers.

@Suite("SplitView — tree-as-state model + ratio-based distribution")
@MainActor
struct SplitViewTests {

    // MARK: - SplitNode value semantics

    @Test("SplitNode is a value type — copying then mutating leaves original unchanged")
    func splitNodeIsValueType() {
        let leaf1 = SplitNode.leaf(Text("alpha"))
        let leaf2 = SplitNode.leaf(Text("beta"))
        let original: SplitNode = .split(axis: .horizontal, children: [leaf1, leaf2], ratios: [0.5, 0.5])
        var copy = original
        // Mutate the copy. With a value type the original must be unaffected.
        copy = .leaf(Text("mutated"))
        guard case .split = original else {
            Issue.record("original lost its split shape")
            return
        }
        guard case .leaf = copy else {
            Issue.record("copy didn't take the new leaf value")
            return
        }
    }

    @Test("SplitAxis is exhaustive — .horizontal and .vertical")
    func splitAxisIsExhaustive() {
        // Compile-only check: switch must be exhaustive for SW-TYPE-ENUM-STATE.
        for axis in [SplitAxis.horizontal, .vertical] {
            switch axis {
            case .horizontal:
                #expect(true)
            case .vertical:
                #expect(true)
            }
        }
    }

    // MARK: - SplitState observability

    @Test("SplitState is @Observable — root mutation is observable")
    func splitStateIsObservable() {
        let state = SplitState(root: .leaf(Text("a")))
        // Mutating root triggers observation. We can't directly test
        // body re-evaluation in a unit context (no graph), but we
        // CAN verify the value mutation works and the type bears the
        // @Observable macro (compile-only check).
        state.root = .split(axis: .horizontal, children: [.leaf(Text("a")), .leaf(Text("b"))], ratios: [0.5, 0.5])
        guard case .split = state.root else {
            Issue.record("root mutation didn't take")
            return
        }
    }

    @Test("SplitState init defaults to a single leaf when omitted")
    func splitStateConvenienceInit() {
        // Convenience: `SplitState()` produces an empty placeholder
        // that consumers can replace later. Avoids force-unwrapping
        // in app code that builds the tree lazily.
        let state = SplitState()
        guard case .leaf = state.root else {
            Issue.record("default root should be a placeholder leaf")
            return
        }
    }

    // MARK: - Layout-phase ratio distribution

    @Test("horizontal split distributes width by ratio")
    func horizontalSplitDistributesWidthByRatio() {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("L")), .leaf(Text("R"))],
            ratios: [0.6, 0.4]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else {
            Issue.record("graph has no root after build")
            return
        }
        // 100-wide rect: 60% = 60, 40% = 40, minus 1 column for divider
        // shared between them. Spec: divider lives between siblings, so
        // total = sum(child widths) + (n - 1). For 100 cells: child0 = 60,
        // child1 = 39, divider takes one column between them. Test pins
        // child widths after divider accounting.
        Layout.measureAndPlace(graph: root, in: Rect(x: 0, y: 0, width: 100, height: 10))

        let primitives = collectPrimitives(in: root)
        #expect(primitives.count == 2, "split should have 2 leaf descendants")
        let widths = primitives.map { $0.rect.width }
        let totalChildren = widths.reduce(0, +)
        // Children + 1 divider column = 100.
        #expect(totalChildren == 99, "child widths + 1 divider = 100; got widths=\(widths)")
        // 60/40 split: child0 ~60, child1 ~39.
        #expect(widths[0] == 60, "left child should be 60 cols; got \(widths[0])")
        #expect(widths[1] == 39, "right child should be 39 cols; got \(widths[1])")
    }

    @Test("vertical split distributes height by ratio")
    func verticalSplitDistributesHeightByRatio() {
        let state = SplitState(root: .split(
            axis: .vertical,
            children: [.leaf(Text("T")), .leaf(Text("B"))],
            ratios: [0.5, 0.5]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else {
            Issue.record("graph has no root after build")
            return
        }
        // 20-tall rect, 50/50 + 1 divider row = total 20.
        Layout.measureAndPlace(graph: root, in: Rect(x: 0, y: 0, width: 30, height: 20))

        let primitives = collectPrimitives(in: root)
        #expect(primitives.count == 2)
        let heights = primitives.map { $0.rect.height }
        #expect(heights.reduce(0, +) == 19, "child heights + 1 divider row = 20; got heights=\(heights)")
        // 50/50 of (20 - 1 divider) = 19/2 = 9 + 10 (or 10 + 9 depending
        // on rounding — pin half ± 1).
        #expect(abs(heights[0] - heights[1]) <= 1, "halves should differ by ≤ 1; got \(heights)")
    }

    // MARK: - Renderer dispatch + divider drawing

    @Test("divider renders between children — vertical bar for horizontal split")
    func dividerRendersBetweenHorizontalChildren() {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("L")), .leaf(Text("R"))],
            ratios: [0.5, 0.5]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else { Issue.record("no root"); return }
        let rect = Rect(x: 0, y: 0, width: 10, height: 4)
        Layout.measureAndPlace(graph: root, in: rect)
        var buffer = CellBuffer(width: rect.width, height: rect.height)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: rect))
        // 50/50 of 10 cols = 5 + 4 + 1 divider col. Divider sits at col 5
        // (after left child of width 5, before right child).
        // Spec: vertical bar `│` for horizontal-axis splits.
        #expect(buffer[5, 0].character == "│",
                "divider column at col 5 row 0 should be │; got \(buffer[5, 0].character)")
        #expect(buffer[5, 2].character == "│",
                "divider column at col 5 row 2 should be │; got \(buffer[5, 2].character)")
    }

    @Test("divider renders between children — horizontal bar for vertical split")
    func dividerRendersBetweenVerticalChildren() {
        let state = SplitState(root: .split(
            axis: .vertical,
            children: [.leaf(Text("T")), .leaf(Text("B"))],
            ratios: [0.5, 0.5]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else { Issue.record("no root"); return }
        let rect = Rect(x: 0, y: 0, width: 10, height: 5)
        Layout.measureAndPlace(graph: root, in: rect)
        var buffer = CellBuffer(width: rect.width, height: rect.height)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: rect))
        // 50/50 of 5 rows = 2 + 2 + 1 divider row. Divider row at y=2.
        // Spec: horizontal bar `─` for vertical-axis splits.
        #expect(buffer[0, 2].character == "─",
                "divider row at row 2 col 0 should be ─; got \(buffer[0, 2].character)")
        #expect(buffer[5, 2].character == "─",
                "divider row at row 2 col 5 should be ─; got \(buffer[5, 2].character)")
    }

    // MARK: - Ratio normalization

    @Test("ratios that don't sum to 1.0 normalize correctly")
    func ratiosNormalize() {
        // Ratios [3, 7] should normalize to [0.3, 0.7].
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("L")), .leaf(Text("R"))],
            ratios: [3.0, 7.0]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else { Issue.record("no root"); return }
        Layout.measureAndPlace(graph: root, in: Rect(x: 0, y: 0, width: 100, height: 5))
        let primitives = collectPrimitives(in: root)
        #expect(primitives.count == 2)
        // 30/70 of (100 - 1 divider) = 99 → 29.7 / 69.3 → ~30/69 with
        // larger child getting the leftover.
        #expect(primitives[0].rect.width == 30, "left should be ~30; got \(primitives[0].rect.width)")
        #expect(primitives[1].rect.width == 69, "right should be ~69; got \(primitives[1].rect.width)")
    }

    // MARK: - Layer-2 contract

    @Test("Layer-2 contract: render reads pre-stamped child rects, doesn't recompute")
    func renderReadsPreStampedRects() {
        let state = SplitState(root: .split(
            axis: .horizontal,
            children: [.leaf(Text("L")), .leaf(Text("R"))],
            ratios: [0.5, 0.5]
        ))
        let graph = AttributeGraph()
        graph.update(from: SplitView(state: state))
        guard let root = graph.root else { Issue.record("no root"); return }
        let rect = Rect(x: 0, y: 0, width: 20, height: 5)
        Layout.measureAndPlace(graph: root, in: rect)

        // Snapshot rects after layout.
        let primitivesBefore = collectPrimitives(in: root)
        let rectsBefore = primitivesBefore.map { $0.rect }

        var buffer = CellBuffer(width: rect.width, height: rect.height)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: rect))

        // Rects must be unchanged after render (Layer-2 contract).
        let rectsAfter = primitivesBefore.map { $0.rect }
        #expect(rectsBefore == rectsAfter,
                "render must not mutate Layer-2 child rects; before=\(rectsBefore), after=\(rectsAfter)")
    }
}

// MARK: - Helpers

@MainActor
private func collectPrimitives(in node: AttributeNode) -> [AttributeNode] {
    var out: [AttributeNode] = []
    walk(node, into: &out)
    return out
}

@MainActor
private func walk(_ node: AttributeNode, into out: inout [AttributeNode]) {
    if case .primitive = node.kind { out.append(node) }
    for child in node.children {
        walk(child, into: &out)
    }
}
