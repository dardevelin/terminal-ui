import Testing
@testable import TerminalUI

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// HYP-92 — A ScrollView with no focusable descendants should itself become
// focusable so keyboard users can Tab into plain content and drive the
// viewport with arrows / PageUp / PageDown / Home / End. When a descendant
// IS focusable, ScrollView stays out of Tab order to preserve the existing
// scroll-to-focused behaviour.

@Suite("ScrollView — implicit keyboard scroll affordance")
@MainActor
struct ScrollViewFocusTests {

    @Test("bare ScrollView with plain content becomes focusable")
    func bareScrollIsFocusable() {
        resetGraphContext()
        let engine = FocusEngine()
        GraphContext.currentFocusEngine = engine
        let graph = AttributeGraph()
        graph.update(from: ScrollView(.vertical) {
            VStack {
                ForEachWithID(Array(0..<20), id: \.self) { i in
                    Text("row \(i)")
                }
            }
        })
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        // With no inner focusable, the ScrollView node itself is the only
        // candidate — focus must land on it.
        #expect(engine.keyboardFocusID == graph.root!.id,
                "bare ScrollView should capture initial focus")
    }

    @Test("ScrollView containing a focusable descendant stays out of Tab order")
    func focusableDescendantSkipsScroll() {
        resetGraphContext()
        let engine = FocusEngine()
        GraphContext.currentFocusEngine = engine
        var name = ""
        let binding = Binding(get: { name }, set: { name = $0 })
        let graph = AttributeGraph()
        graph.update(from: ScrollView(.vertical) {
            VStack {
                TextInput(text: binding)
            }
        })
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        // Focus should land on the TextInput, not the ScrollView.
        let focusedID = engine.keyboardFocusID
        #expect(focusedID != graph.root!.id,
                "with an inner focusable the ScrollView should not steal focus")
        #expect(focusedID != nil,
                "the TextInput should be focused")
    }

    @Test("down arrow on focused ScrollView advances scroll offset")
    func arrowScrolls() {
        resetGraphContext()
        let engine = FocusEngine()
        GraphContext.currentFocusEngine = engine
        let graph = AttributeGraph()
        graph.update(from: ScrollView(.vertical) {
            VStack {
                ForEachWithID(Array(0..<20), id: \.self) { i in
                    Text("row \(i)")
                }
            }
        })
        let root = graph.root!
        root.rect = Rect(x: 0, y: 0, width: 10, height: 5)
        engine.rebuildIndex(root: root)
        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .down), root: root)
        #expect(root.scrollOffset == 1,
                "down should bump scrollOffset by one row, got \(root.scrollOffset)")
    }
}
