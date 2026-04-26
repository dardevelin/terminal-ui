import Testing
@testable import TerminalUI

// HYP-78 — Flexible / responsive sizing.
//
// Today: `.frame(width: 20, height: 5)` is the only fixed-size knob;
// `.frame(minWidth:maxWidth:)` exists but doesn't fill. Spacer fills
// remaining axis space; ScrollView fills its scroll axis. Plain views
// take intrinsic size with no growth.
//
// Goal (from ticket): SwiftUI-equivalent flex API.
//
//     Text("title").flexible()              // both axes
//     Text("title").flexible(.horizontal)   // single axis
//     Text("title").flexible(grow: 2)       // weighted
//
//     .frame(maxWidth: .infinity)           // SwiftUI alias
//     .frame(maxHeight: .infinity)
//
// Semantics:
// - Inside HStack: .flexible(.horizontal) children divide remaining
//   horizontal space by grow weight (default 1) AFTER fixed-size
//   siblings claim theirs. Same shape as Spacer / ScrollView today
//   (which already use spacerDistribution).
// - Inside VStack: .flexible(.vertical) divides remaining vertical.
// - Inside ZStack: fills both axes to match largest sibling or parent.
// - Outside a stack: fills the proposed size from parent.

@Suite("FrameDimension — SwiftUI-shaped infinity alias")
@MainActor
struct FrameDimensionTests {

    @Test("FrameDimension.infinity is a public case")
    func infinityCaseExists() {
        let dim: FrameDimension = .infinity
        #expect(dim == .infinity)
    }

    @Test("FrameDimension is ExpressibleByIntegerLiteral so .frame(maxWidth: 40) keeps working")
    func integerLiteralStillWorks() {
        let dim: FrameDimension = 40
        #expect(dim == .fixed(40))
    }

    @Test(".frame(maxWidth: .infinity) constructs a FrameModifier carrying .infinity")
    func frameMaxWidthInfinity() {
        let view = Text("x").frame(maxWidth: .infinity)
        // The constructed modifier must carry .infinity in maxWidth so
        // the layout pass can treat it as "fill horizontally".
        #expect(view.modifier.maxWidth == .infinity)
    }

    @Test(".frame(maxHeight: .infinity) constructs a FrameModifier carrying .infinity")
    func frameMaxHeightInfinity() {
        let view = Text("x").frame(maxHeight: .infinity)
        #expect(view.modifier.maxHeight == .infinity)
    }
}

@Suite(".flexible() modifier — explicit flex API")
@MainActor
struct FlexibleModifierTests {

    @Test(".flexible() defaults to both axes with grow=1")
    func defaultsBothAxes() {
        let view = Text("x").flexible()
        #expect(view.modifier.axes == .all)
        #expect(view.modifier.grow == 1)
    }

    @Test(".flexible(.horizontal) sets only the horizontal axis")
    func horizontalOnly() {
        let view = Text("x").flexible(.horizontal)
        #expect(view.modifier.axes == .horizontal)
    }

    @Test(".flexible(.vertical) sets only the vertical axis")
    func verticalOnly() {
        let view = Text("x").flexible(.vertical)
        #expect(view.modifier.axes == .vertical)
    }

    @Test(".flexible(grow: 2) carries the weight")
    func customGrow() {
        let view = Text("x").flexible(grow: 2)
        #expect(view.modifier.grow == 2)
    }
}

// MARK: - Layout integration

@Suite(".flexible() — layout distribution in HStack")
@MainActor
struct FlexibleHStackTests {

    @Test(".flexible(.horizontal) inside HStack fills remainder")
    func flexFillsRemainderInHStack() {
        // Total width 20. Fixed "abc" claims 3. Single .flexible() child
        // should occupy the remaining 17 cells.
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("abc")
            Text("flex").flexible(.horizontal)
        })
        let root = graph.root!
        var buffer = CellBuffer(width: 20, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 1))
        Layout.measureAndPlace(graph: root, in: ctx.rect)
        GraphRenderer.render(root, into: &buffer, context: ctx)

        // Walk to find the .flexible-modified node and confirm its rect.
        let flexNode = findFlexibleNode(in: root)
        #expect(flexNode != nil, "graph must contain a node carrying the flexible modifier")
        if let flex = flexNode {
            #expect(flex.rect.width == 17,
                    "flex child must claim remaining 17 cells of HStack(width=20) after Text(\"abc\")=3 cells; got \(flex.rect.width)")
        }
    }

    @Test("two .flexible() siblings split remainder equally with grow=1 each")
    func twoFlexEqualSplit() {
        // Total 20. Fixed "ab" = 2. Two flex children with grow=1 each
        // should split the remaining 18 → 9 + 9.
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("ab")
            Text("L").flexible(.horizontal)
            Text("R").flexible(.horizontal)
        })
        let root = graph.root!
        var buffer = CellBuffer(width: 20, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 1))
        Layout.measureAndPlace(graph: root, in: ctx.rect)
        GraphRenderer.render(root, into: &buffer, context: ctx)

        let flexes = findAllFlexibleNodes(in: root)
        #expect(flexes.count == 2, "must locate both flex modifier nodes; got \(flexes.count)")
        if flexes.count == 2 {
            #expect(flexes[0].rect.width == 9,
                    "first flex of two equal-weight should get 9 of remaining 18; got \(flexes[0].rect.width)")
            #expect(flexes[1].rect.width == 9,
                    "second flex of two equal-weight should get 9 of remaining 18; got \(flexes[1].rect.width)")
        }
    }

    @Test("two .flexible() siblings with grow=1 and grow=2 split remainder by weight")
    func twoFlexWeightedSplit() {
        // Total 30. Fixed "ab" = 2. Remaining 28. Grow weights 1 + 2 = 3.
        // First flex gets 28/3 = 9; second gets 28*2/3 ≈ 19. Allowing
        // for rounding, accept either 9+19 or 10+18.
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("ab")
            Text("L").flexible(grow: 1)
            Text("R").flexible(grow: 2)
        })
        let root = graph.root!
        var buffer = CellBuffer(width: 30, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 30, height: 1))
        Layout.measureAndPlace(graph: root, in: ctx.rect)
        GraphRenderer.render(root, into: &buffer, context: ctx)

        let flexes = findAllFlexibleNodes(in: root)
        #expect(flexes.count == 2)
        if flexes.count == 2 {
            let total = flexes[0].rect.width + flexes[1].rect.width
            #expect(total == 28, "weighted children must consume all remainder; got \(total)")
            // grow=2 child must be wider than grow=1 child
            #expect(flexes[1].rect.width > flexes[0].rect.width,
                    "grow=2 child should be wider than grow=1 sibling; got \(flexes[0].rect.width) vs \(flexes[1].rect.width)")
        }
    }
}

@Suite(".flexible() — layout distribution in VStack")
@MainActor
struct FlexibleVStackTests {

    @Test(".flexible(.vertical) inside VStack fills remainder")
    func flexFillsRemainderInVStack() {
        // Total height 10. Fixed two Texts each 1 row = 2. One flex
        // child should claim remaining 8 rows.
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("top")
            Text("flex").flexible(.vertical)
            Text("bot")
        })
        let root = graph.root!
        var buffer = CellBuffer(width: 5, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 5, height: 10))
        Layout.measureAndPlace(graph: root, in: ctx.rect)
        GraphRenderer.render(root, into: &buffer, context: ctx)

        let flex = findFlexibleNode(in: root)
        #expect(flex != nil)
        if let flex {
            #expect(flex.rect.height == 8,
                    "flex child must claim remaining 8 rows of VStack(height=10) after two 1-row Texts; got \(flex.rect.height)")
        }
    }
}

// MARK: - .frame(maxWidth: .infinity) layout integration

@Suite(".frame(maxWidth: .infinity) — SwiftUI alias for flexible horizontal")
@MainActor
struct FrameInfinityLayoutTests {

    @Test(".frame(maxWidth: .infinity) inside HStack fills remainder")
    func maxWidthInfinityFills() {
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("abc")
            Text("flex").frame(maxWidth: .infinity)
        })
        let root = graph.root!
        var buffer = CellBuffer(width: 20, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 1))
        Layout.measureAndPlace(graph: root, in: ctx.rect)
        GraphRenderer.render(root, into: &buffer, context: ctx)

        // The .frame(maxWidth: .infinity) must lower to the same flex
        // path as .flexible(.horizontal). The frame-modifier node is
        // the one to inspect.
        let frameNode = findFrameMaxWidthInfinityNode(in: root)
        #expect(frameNode != nil)
        if let frame = frameNode {
            #expect(frame.rect.width == 17,
                    ".frame(maxWidth: .infinity) must fill remainder like .flexible(.horizontal); got \(frame.rect.width)")
        }
    }
}

// MARK: - Helpers

@MainActor
private func findFlexibleNode(in node: AttributeNode) -> AttributeNode? {
    if case .modifier(.flexible) = node.kind { return node }
    for child in node.children {
        if let f = findFlexibleNode(in: child) { return f }
    }
    return nil
}

@MainActor
private func findAllFlexibleNodes(in node: AttributeNode) -> [AttributeNode] {
    var out: [AttributeNode] = []
    if case .modifier(.flexible) = node.kind { out.append(node) }
    for child in node.children {
        out.append(contentsOf: findAllFlexibleNodes(in: child))
    }
    return out
}

@MainActor
private func findFrameMaxWidthInfinityNode(in node: AttributeNode) -> AttributeNode? {
    if case .modifier(.frame(_, _, _, let maxW, _, _)) = node.kind, maxW == .infinity {
        return node
    }
    for child in node.children {
        if let f = findFrameMaxWidthInfinityNode(in: child) { return f }
    }
    return nil
}
