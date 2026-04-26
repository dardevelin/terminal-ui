import Testing
@testable import TerminalUI

// SwiftUI persists per-view environment so @Environment reads remain
// valid between events (e.g. inside .onTapGesture, the env stack from
// the last render is still queryable). Our analog: `node._resolvedEnv`
// captured during the render walk, surviving across mouse and key
// events so handlers can resolve env at the hit-tested node — and so
// future preview tooling (the TUI-Xcode inspector) can answer
// "what does this node see?" without re-running the world.
//
// Underscored access (`_resolvedEnv`) signals framework-internal,
// not yet committed public API — the eventual preview surface will
// design its own public inspection layer.

/// Render the graph once at a known canvas size so resolvedEnv is
/// populated everywhere. Returns root.
@MainActor
private func buildAndRender<V: TerminalView>(_ view: V, width: Int = 20, height: Int = 10) -> AttributeNode {
    let graph = AttributeGraph()
    graph.update(from: view)
    let root = graph.root!
    var canvas = CellBuffer(width: width, height: height)
    GraphRenderer.render(root, into: &canvas, context: RenderContext(style: .plain, rect: Rect(x: 0, y: 0, width: width, height: height)))
    return root
}

/// Walk the rendered tree to find the first viewBody/primitive node
/// whose owning view is of type T. Mirrors what a preview surface
/// would do.
@MainActor
private func findPrimitiveText(_ root: AttributeNode, content: String) -> AttributeNode? {
    if case .primitive(.text(let spans)) = root.kind,
       spans.first?.text == content { return root }
    for child in root.children {
        if let f = findPrimitiveText(child, content: content) { return f }
    }
    return nil
}

@Suite("Persisted resolvedEnv — captured during render walk")
@MainActor
struct PersistedResolvedEnvTests {

    @Test("app-level policy propagates to every node's resolvedEnv")
    func appLevelPropagation() {
        let root = buildAndRender(
            VStack {
                Text("a")
                Text("b")
            }.mouseFocusPolicy(.hoverFollows)
        )
        let a = findPrimitiveText(root, content: "a")
        let b = findPrimitiveText(root, content: "b")
        #expect(a?._resolvedEnv?.mouseFocusPolicy == .hoverFollows)
        #expect(b?._resolvedEnv?.mouseFocusPolicy == .hoverFollows)
    }

    @Test("subtree policy override only affects descendants")
    func subtreeOverride() {
        let root = buildAndRender(
            VStack {
                Text("outer")
                VStack {
                    Text("inner")
                }.mouseFocusPolicy(.disabled)
            }
        )
        let outer = findPrimitiveText(root, content: "outer")
        let inner = findPrimitiveText(root, content: "inner")
        #expect(outer?._resolvedEnv?.mouseFocusPolicy == .clickToLock,
                "outer Text uses default policy")
        #expect(inner?._resolvedEnv?.mouseFocusPolicy == .disabled,
                "inner subtree gets the override")
    }

    @Test("nested overrides — deepest wins")
    func nestedDeepestWins() {
        let root = buildAndRender(
            VStack {
                Text("hover")
                VStack {
                    Text("click")
                }.mouseFocusPolicy(.clickOnly)
            }.mouseFocusPolicy(.hoverFollows)
        )
        let hover = findPrimitiveText(root, content: "hover")
        let click = findPrimitiveText(root, content: "click")
        #expect(hover?._resolvedEnv?.mouseFocusPolicy == .hoverFollows)
        #expect(click?._resolvedEnv?.mouseFocusPolicy == .clickOnly,
                "the deeper override wins for the inner node")
    }

    @Test("default policy when no modifier set")
    func defaultsToClickToLock() {
        let root = buildAndRender(Text("plain"))
        let plain = findPrimitiveText(root, content: "plain")
        #expect(plain?._resolvedEnv?.mouseFocusPolicy == .clickToLock)
    }

    @Test("FocusEngine.resolvedEnv reads from the hit-tested node")
    func focusEngineHitTestedEnv() {
        // Two focusables side-by-side; one has .disabled override.
        // The runtime's policy lookup must use whichever rect contains
        // the cursor, not the app-level env.
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("left").focusable()
            Text("right").focusable().mouseFocusPolicy(.disabled)
        })
        let root = graph.root!
        // Stamp rects directly so hit-test works without a layout pass.
        let leftFocusable = root.children[0]
        let rightFocusableTree = root.children[1] // .mouseFocusPolicy node wrapping .focusable wrapping Text
        leftFocusable.rect = Rect(x: 0, y: 0, width: 5, height: 1)
        rightFocusableTree.rect = Rect(x: 0, y: 1, width: 5, height: 1)
        // Walk down to the actual focusable nodes whose ids the engine indexes.
        // The render pass will populate _resolvedEnv as it descends, so render once first.
        var canvas = CellBuffer(width: 10, height: 5)
        GraphRenderer.render(root, into: &canvas, context: RenderContext(style: .plain, rect: Rect(x: 0, y: 0, width: 10, height: 5)))

        let engine = FocusEngine()
        engine.rebuildIndex(root: root)

        // resolveEnv at left rect → default policy
        let leftEnv = engine.resolveEnv(x: 2, y: 0, root: root)
        #expect(leftEnv.mouseFocusPolicy == .clickToLock,
                "left focusable inherits app-level (default) policy")

        // resolveEnv at right rect → disabled
        let rightEnv = engine.resolveEnv(x: 2, y: 1, root: root)
        #expect(rightEnv.mouseFocusPolicy == .disabled,
                "right focusable's subtree override resolves correctly")
    }

    @Test("markDirty clears stale resolvedEnv")
    func markDirtyClears() {
        // A node that survives a graph update but has its env modifier
        // ancestor removed must not retain the old env value. We model
        // this minimally: render → stamp env → markDirty → assert nil.
        // The render that follows markDirty re-populates correctly.
        let root = buildAndRender(Text("x").mouseFocusPolicy(.disabled))
        let x = findPrimitiveText(root, content: "x")
        #expect(x?._resolvedEnv?.mouseFocusPolicy == .disabled,
                "sanity: env populated after first render")
        x?.markDirty()
        #expect(x?._resolvedEnv == nil,
                "markDirty must clear cached env so a stale value cannot leak")
    }
}
