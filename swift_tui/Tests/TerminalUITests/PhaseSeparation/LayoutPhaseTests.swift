import Foundation
import Testing
@testable import TerminalUI

// Phase separation: GeometryReader's child closure depends on
// the parent-supplied size. Today that closure runs from inside
// `GraphRenderer.render`. Phase-separation contract:
//
//   1. Build phase   — `graph.update(from:)` reconciles the tree.
//      GR's child stays as a "deferred" placeholder; the rebuilder
//      closure is captured but not invoked.
//   2. Layout phase  — `Layout.measureAndPlace(graph:in:)` computes
//      every node's rect AND invokes GR rebuilders with the resolved
//      size. After this phase the tree is final for the frame.
//   3. Render phase  — pure draw. Reads rects, writes cells. No
//      graph mutation, no rebuilder invocation.
//
// This suite pins the layout-phase contract: a single
// `Layout.measureAndPlace` call invokes the rebuilder once, with the
// allocated rect's size. Render then sees the resolved tree.

@Suite("Layout phase — measureAndPlace fires GR rebuilders, render then draws")
@MainActor
struct LayoutPhaseTests {

    @Test("Layout.measureAndPlace exists as a public phase-boundary entry point")
    func phaseEntryPointExists() {
        // Compile-only red: pins the public API name. Once Layout.measureAndPlace
        // ships, this test compiles and provides the call site for downstream tests.
        let graph = AttributeGraph()
        graph.update(from: Text("probe"))
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        Layout.measureAndPlace(
            graph: root,
            in: Rect(x: 0, y: 0, width: 30, height: 4)
        )
    }

    @Test("measureAndPlace fires GR rebuilder with the allocated rect's size")
    func rebuilderFiresInLayoutPhase() {
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            Text("\(size.width)x\(size.height)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let gr = findGeometryReaderNode(from: root)!
        let originalRebuild = gr.geometryRebuilder!
        let probe = SizeCapture()
        gr.geometryRebuilder = { size, parent in
            probe.record(size)
            originalRebuild(size, parent)
        }
        Layout.measureAndPlace(
            graph: root,
            in: Rect(x: 0, y: 0, width: 42, height: 7)
        )
        #expect(probe.last == Size(width: 42, height: 7),
                "GR rebuilder must fire during layout with the allocated rect size; got \(String(describing: probe.last))")
    }

    @Test("measureAndPlace fires once per GR per call (idempotent)")
    func rebuilderFiresOncePerLayoutPass() {
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            Text("\(size.width)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        let gr = findGeometryReaderNode(from: root)!
        let originalRebuild = gr.geometryRebuilder!
        let counter = RebuildCounter()
        gr.geometryRebuilder = { size, parent in
            counter.bump()
            originalRebuild(size, parent)
        }
        Layout.measureAndPlace(
            graph: root,
            in: Rect(x: 0, y: 0, width: 30, height: 4)
        )
        #expect(counter.value == 1,
                "measureAndPlace must invoke each GR's rebuilder exactly once; got \(counter.value)")
    }

    @Test("after measureAndPlace, render does NOT need to invoke the rebuilder")
    func renderAfterLayoutDoesNotRebuild() {
        let graph = AttributeGraph()
        graph.update(from: GeometryReader { size in
            Text("\(size.width)")
        })
        guard let root = graph.root else {
            Issue.record("no root after build")
            return
        }
        // Layout first.
        Layout.measureAndPlace(
            graph: root,
            in: Rect(x: 0, y: 0, width: 30, height: 4)
        )
        // Then wrap the rebuilder and render — no fire expected.
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
                "after measureAndPlace, render must not invoke the rebuilder again; got \(counter.value)")
    }
}

@MainActor
private final class SizeCapture {
    private(set) var last: Size?
    func record(_ size: Size) { last = size }
}

@MainActor
private final class RebuildCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

@MainActor
private func findGeometryReaderNode(from node: AttributeNode) -> AttributeNode? {
    if node.geometryRebuilder != nil { return node }
    for child in node.children {
        if let found = findGeometryReaderNode(from: child) { return found }
    }
    return nil
}
