import Foundation
import Testing
@testable import TerminalUI

// The live run loop clears every key/click handler at the top of a frame
// (`focusEngine.clearHandlers()`) and relies on the graph update to put them
// back. That works while a view's body is re-evaluated — but a *cached*
// composite subtree (inputs unchanged, nothing dirty) is skipped by
// `evaluateBody`, so its `.onKeyPress` / `.onClick` handlers were never
// re-registered and the control went dead.
//
// It stayed hidden because most apps dirty something every frame. It surfaced
// through `NavigationStack`, whose `NavigationLink`s have stable inputs across
// frames, so they cache and their Enter handler vanished after the first
// clear+update cycle — the control rendered but did nothing.
//
// The fix makes handler registration a function of tree shape, not of body
// evaluation: the handler rides on the node and `rebuildIndex` — which already
// walks every node unconditionally — re-registers it. These tests pin that a
// handler survives a clear + cached update, with no navigation types involved.

/// A box the handler mutates, so the composite view itself holds no closure
/// field — a closure would compare unequal every frame and force a rebuild,
/// which is exactly the caching this test needs to defeat.
final class FireCount: @unchecked Sendable { var value = 0 }
private let fireBox = FireCount()

private struct CachedButton: TerminalView {
    // Only value-typed, equal-across-frames fields, so the composite caches and
    // its body is skipped on update — the condition under which the bug bit.
    let title: String

    var body: some TerminalView {
        Text(title).focusable().onKeyPress { event in
            if event.key == .enter { fireBox.value += 1; return .handled }
            return .ignored
        }
    }
}

@Suite("Handler re-registration across clear + cached update")
@MainActor
struct HandlerReregistrationTests {

    /// The exact live-loop cycle: full frame, then a frame that clears handlers
    /// and updates from an equal view (so the composite caches).
    private func fires(after cycles: Int) -> Int {
        fireBox.value = 0
        let graph = AttributeGraph()
        let engine = FocusEngine()

        func frame(clearFirst: Bool) {
            GraphContext.$currentFocusEngine.withValue(engine) {
                if clearFirst { engine.clearHandlers() }
                graph.update(from: VStack { CachedButton(title: "Go") })
                var buffer = CellBuffer(width: 20, height: 4)
                GraphRenderer.render(
                    graph.root!, into: &buffer,
                    context: RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 4))
                )
                engine.rebuildIndex(root: graph.root!)
            }
        }

        frame(clearFirst: false)
        for _ in 0..<cycles { frame(clearFirst: true) }
        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        return fireBox.value
    }

    @Test("a key handler survives one clear + cached update")
    func survivesOneCycle() {
        #expect(fires(after: 1) == 1)
    }

    @Test("a key handler survives several clear + cached updates")
    func survivesManyCycles() {
        #expect(fires(after: 5) == 1)
    }

    // A click handler rides the same path and must survive too.
    @Test("a click handler survives clear + cached update")
    func clickSurvives() {
        var clicked = 0
        let graph = AttributeGraph()
        let engine = FocusEngine()

        func frame(clearFirst: Bool) {
            GraphContext.$currentFocusEngine.withValue(engine) {
                if clearFirst { engine.clearHandlers() }
                graph.update(from: VStack {
                    Text("x").focusable().onClick { _, _ in clicked += 1 }
                })
                var buffer = CellBuffer(width: 20, height: 4)
                GraphRenderer.render(
                    graph.root!, into: &buffer,
                    context: RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 4))
                )
                engine.rebuildIndex(root: graph.root!)
            }
        }

        frame(clearFirst: false)
        frame(clearFirst: true)
        engine.handleMouseClick(x: 0, y: 0, root: graph.root!)
        #expect(clicked == 1)
    }
}
