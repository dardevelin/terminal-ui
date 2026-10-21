import Foundation
import Testing
@testable import TerminalUI

// Modifier rect math and ZStack semantics belong to the layout phase:
// padding, border and frame inset the rect a child is placed in, and a
// ZStack gives every child the parent's rect.
//
// The phase-separation contract says the layout phase owns
// rect computation. This suite pins the per-primitive math at the Layout
// level: after `Layout.measureAndPlace`, a child node's `rect` already
// reflects its modifier/ZStack-derived rect WITHOUT calling render.
//
// Stack distribution (VStack/HStack flex) and ScrollView content sizing
// are not covered here.

@Suite("Layout math — modifier rect transforms + ZStack stamp child rects in layout phase")
@MainActor
struct LayoutMathTests {

    // MARK: - Padding

    @Test("padding: child rect is parent's rect inset by amount, before render")
    func paddingChildRectInsetByAmount() {
        let graph = AttributeGraph()
        graph.update(from: Text("inside").padding(2))
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let allocated = Rect(x: 0, y: 0, width: 30, height: 10)
        Layout.measureAndPlace(graph: root, in: allocated)
        // root is the .padding modifier node; its sole child is the Text.
        guard let textChild = firstDescendantPrimitive(in: root) else {
            Issue.record("no primitive descendant of padded root")
            return
        }
        #expect(textChild.rect == allocated.inset(by: 2),
                "padded child rect must equal allocated.inset(by: 2); got \(textChild.rect)")
    }

    // MARK: - Border

    @Test("border: child rect is parent's rect inset by 1, before render")
    func borderChildRectInsetByOne() {
        let graph = AttributeGraph()
        graph.update(from: Text("inside").border(.rounded))
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let allocated = Rect(x: 0, y: 0, width: 20, height: 6)
        Layout.measureAndPlace(graph: root, in: allocated)
        guard let textChild = firstDescendantPrimitive(in: root) else {
            Issue.record("no primitive descendant of bordered root")
            return
        }
        #expect(textChild.rect == allocated.inset(by: 1),
                "bordered child rect must equal allocated.inset(by: 1); got \(textChild.rect)")
    }

    // MARK: - Frame

    @Test("frame(width:height:): child rect clamped to fixed dimensions, before render")
    func frameClampsToFixedDimensions() {
        let graph = AttributeGraph()
        graph.update(from: Text("x").frame(width: 10, height: 4))
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        // Allocated rect is bigger than the frame caps; frame must clamp DOWN.
        let allocated = Rect(x: 5, y: 7, width: 30, height: 12)
        Layout.measureAndPlace(graph: root, in: allocated)
        guard let textChild = firstDescendantPrimitive(in: root) else {
            Issue.record("no primitive descendant of framed root")
            return
        }
        #expect(textChild.rect.width == 10,
                "frame(width: 10) must clamp child width down to 10; got \(textChild.rect.width)")
        #expect(textChild.rect.height == 4,
                "frame(height: 4) must clamp child height down to 4; got \(textChild.rect.height)")
        // Origin stays the same — frame doesn't translate.
        #expect(textChild.rect.x == allocated.x && textChild.rect.y == allocated.y,
                "frame must not translate the child's origin; got (\(textChild.rect.x), \(textChild.rect.y))")
    }

    // MARK: - ZStack

    @Test("ZStack: every child's rect equals the parent's rect, before render")
    func zstackChildrenInheritParentRect() {
        let graph = AttributeGraph()
        graph.update(from: ZStack {
            Text("back")
            Text("front")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let allocated = Rect(x: 1, y: 2, width: 14, height: 5)
        Layout.measureAndPlace(graph: root, in: allocated)

        let primitives = collectPrimitives(in: root)
        #expect(primitives.count >= 2,
                "ZStack should expose at least 2 primitive descendants; got \(primitives.count)")
        for child in primitives {
            #expect(child.rect == allocated,
                    "every ZStack descendant primitive must inherit allocated rect; got \(child.rect) for kind \(child.kind.debugName)")
        }
    }

    // MARK: - Composed: padding inside border inside ZStack

    @Test("composed modifiers: padding inside border inside ZStack — rects compose left-to-right")
    func composedModifiersStampCorrectly() {
        let graph = AttributeGraph()
        graph.update(from: ZStack {
            Text("inner")
                .padding(1)
                .border(.rounded)
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let allocated = Rect(x: 0, y: 0, width: 20, height: 10)
        Layout.measureAndPlace(graph: root, in: allocated)
        // ZStack child = border modifier node, its child = padding modifier node,
        // its child = Text primitive. Border insets by 1, padding insets by 1.
        guard let primitive = firstDescendantPrimitive(in: root) else {
            Issue.record("no primitive descendant in composed tree")
            return
        }
        let expected = allocated.inset(by: 1).inset(by: 1)
        #expect(primitive.rect == expected,
                "composed border→padding→Text should stamp inset(1).inset(1); got \(primitive.rect)")
    }

    // MARK: - Render purity for modifier+ZStack subtrees

    @Test("after layout, render does NOT mutate child rects in a modifier+ZStack tree")
    func renderDoesNotRestampRectsAfterLayout() {
        let graph = AttributeGraph()
        graph.update(from: ZStack {
            Text("a").padding(2).border(.rounded)
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let allocated = Rect(x: 0, y: 0, width: 16, height: 8)
        Layout.measureAndPlace(graph: root, in: allocated)
        let snapshotBefore = collectRectSnapshot(of: root)
        var buffer = CellBuffer(width: allocated.width, height: allocated.height)
        GraphRenderer.render(root, into: &buffer, context: .init(rect: allocated))
        let snapshotAfter = collectRectSnapshot(of: root)
        #expect(snapshotBefore == snapshotAfter,
                "render must not re-stamp rects in a modifier+ZStack subtree; layout owns that math now")
    }
}

// MARK: - Helpers

@MainActor
private func firstDescendantPrimitive(in node: AttributeNode) -> AttributeNode? {
    if case .primitive = node.kind { return node }
    for child in node.children {
        if let found = firstDescendantPrimitive(in: child) { return found }
    }
    return nil
}

@MainActor
private func collectPrimitives(in node: AttributeNode) -> [AttributeNode] {
    var out: [AttributeNode] = []
    walkPrimitives(node, into: &out)
    return out
}

@MainActor
private func walkPrimitives(_ node: AttributeNode, into out: inout [AttributeNode]) {
    if case .primitive = node.kind { out.append(node) }
    for child in node.children {
        walkPrimitives(child, into: &out)
    }
}

@MainActor
private func collectRectSnapshot(of node: AttributeNode) -> [RectSnapshot] {
    var out: [RectSnapshot] = []
    walkRectSnapshot(node, into: &out)
    return out
}

@MainActor
private func walkRectSnapshot(_ node: AttributeNode, into out: inout [RectSnapshot]) {
    out.append(RectSnapshot(identity: ObjectIdentifier(node), rect: node.rect))
    for child in node.children {
        walkRectSnapshot(child, into: &out)
    }
}

private struct RectSnapshot: Equatable {
    let identity: ObjectIdentifier
    let rect: Rect
}
