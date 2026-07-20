import Testing
@testable import TerminalUI

@Suite("AttributeGraph — reconciliation & identity")
@MainActor
struct AttributeGraphTests {

    @Test("first update builds a root")
    func firstUpdateBuildsRoot() {
        let graph = AttributeGraph()
        #expect(graph.root == nil)
        graph.update(from: Text("hi"))
        #expect(graph.root != nil)
    }

    @Test("Text builds a primitive text node")
    func textPrimitive() {
        let graph = AttributeGraph()
        graph.update(from: Text("hello"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        guard case .primitive(.text(let spans)) = root.kind else {
            Issue.record("expected .primitive(.text), got \(root.kind)")
            return
        }
        #expect(spans.contains { $0.text.contains("hello") })
    }

    @Test("VStack builds a layout node with children")
    func vstackLayoutNode() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        #expect(root.kind.isLayout(.vstack))
        #expect(root.children.count == 2)
    }

    @Test("HStack builds a layout node with children")
    func hstackLayoutNode() {
        let graph = AttributeGraph()
        graph.update(from: HStack { Text("x"); Text("y"); Text("z") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        #expect(root.kind.isLayout(.hstack))
        #expect(root.children.count == 3)
    }

    @Test("second update with identical view preserves node identity")
    func identityPreservedOnReconcile() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let firstRoot = graph.root
        let firstChild0 = graph.root?.children[0]
        graph.update(from: VStack { Text("a"); Text("b") })
        #expect(graph.root === firstRoot)
        #expect(graph.root?.children[0] === firstChild0)
    }

    @Test("second update with identical view reports no change")
    func reconcileReportsNoChange() {
        let graph = AttributeGraph()
        graph.update(from: Text("hello"))
        let changed = graph.update(from: Text("hello"))
        #expect(changed == false)
    }

    @Test("second update with different text reports change")
    func reconcileDetectsTextChange() {
        let graph = AttributeGraph()
        graph.update(from: Text("hello"))
        let changed = graph.update(from: Text("world"))
        #expect(changed == true)
    }
}

@Suite("GraphRenderer — rendering into CellBuffer")
@MainActor
struct GraphRendererTests {

    @Test("Text renders characters into buffer")
    func textRenders() {
        let graph = AttributeGraph()
        graph.update(from: Text("hi"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        var buffer = CellBuffer(width: 10, height: 3)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 3))
        GraphRenderer.render(root, into: &buffer, context: ctx)
        #expect(buffer[0, 0].character == "h")
        #expect(buffer[1, 0].character == "i")
    }

    @Test("VStack stacks children vertically")
    func vstackStacksVertically() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("ab"); Text("cd") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        var buffer = CellBuffer(width: 10, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 5))
        GraphRenderer.render(root, into: &buffer, context: ctx)
        #expect(buffer[0, 0].character == "a")
        #expect(buffer[1, 0].character == "b")
        #expect(buffer[0, 1].character == "c")
        #expect(buffer[1, 1].character == "d")
    }

    @Test("HStack lays children out horizontally")
    func hstackHorizontal() {
        let graph = AttributeGraph()
        graph.update(from: HStack { Text("ab"); Text("cd") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        var buffer = CellBuffer(width: 10, height: 2)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 10, height: 2))
        GraphRenderer.render(root, into: &buffer, context: ctx)
        #expect(buffer[0, 0].character == "a")
        #expect(buffer[1, 0].character == "b")
        // "cd" comes after "ab" on the same row
        #expect(buffer[2, 0].character == "c" || buffer[3, 0].character == "c")
    }

    @Test("render records rect on root node")
    func renderRecordsRect() {
        let graph = AttributeGraph()
        graph.update(from: Text("x"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        var buffer = CellBuffer(width: 5, height: 2)
        let ctx = RenderContext(rect: Rect(x: 1, y: 0, width: 4, height: 2))
        GraphRenderer.render(root, into: &buffer, context: ctx)
        #expect(root.rect.x == 1)
        #expect(root.rect.width == 4)
    }
}

@Suite("GraphMeasurer — intrinsic sizes")
@MainActor
struct GraphMeasurerTests {

    @Test("Text width is its character count")
    func textWidth() {
        let graph = AttributeGraph()
        graph.update(from: Text("hello"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        #expect(GraphMeasurer.measureWidth(root) == 5)
    }

    @Test("HStack width is sum of child widths")
    func hstackWidth() {
        let graph = AttributeGraph()
        graph.update(from: HStack { Text("ab"); Text("cde") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        #expect(GraphMeasurer.measureWidth(root) == 5)
    }

    @Test("VStack width is max of child widths")
    func vstackWidth() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("wider") })
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        #expect(GraphMeasurer.measureWidth(root) == 5)
    }

    @Test("measureWidth caches result")
    func measureCaches() {
        let graph = AttributeGraph()
        graph.update(from: Text("x"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        _ = GraphMeasurer.measureWidth(root)
        #expect(root.cachedWidth == 1)
    }

    @Test("markDirty invalidates cached measurements")
    func markDirtyInvalidates() {
        let graph = AttributeGraph()
        graph.update(from: Text("x"))
        guard let root = graph.root else {
            Issue.record("no root")
            return
        }
        _ = GraphMeasurer.measureWidth(root)
        #expect(root.cachedWidth != nil)
        root.markDirty()
        #expect(root.cachedWidth == nil)
    }
}
