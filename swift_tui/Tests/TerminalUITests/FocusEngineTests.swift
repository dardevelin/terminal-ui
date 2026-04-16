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

// These tests pin FocusEngine's current (flat Tab-order, axis-aware arrows)
// behavior before HYP-40 introduces focus scopes.
//
// FocusEngine reads `isFocusable` off AttributeNodes that already live in a
// graph, so tests build a graph first, mark specific nodes focusable, then
// rebuild the engine's cached index.

@Suite("FocusEngine — Tab order baseline")
@MainActor
struct FocusEngineTabOrderTests {

    @Test("empty focusable list — focusNext does nothing")
    func focusNextNoFocusables() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: Text("x"))
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        #expect(engine.keyboardFocusID == nil)
    }

    @Test("focusNext moves to first focusable when none focused")
    func focusNextFromNil() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[1].isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[0].id)
    }

    @Test("focusNext cycles in order")
    func focusNextCycles() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b"); Text("c") })
        let root = graph.root!
        for child in root.children { child.isFocusable = true }
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[0].id)
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[1].id)
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[2].id)
    }

    @Test("focusNext wraps around at end")
    func focusNextWraps() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[1].isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[1].id
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[0].id)
    }

    @Test("focusPrevious reverses order")
    func focusPreviousReverses() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b"); Text("c") })
        let root = graph.root!
        for child in root.children { child.isFocusable = true }
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[2].id
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == root.children[1].id)
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == root.children[0].id)
    }

    @Test("focusPrevious wraps at beginning")
    func focusPreviousWraps() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[1].isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = root.children[0].id
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == root.children[1].id)
    }

    @Test("focusPrevious from nil goes to last")
    func focusPreviousFromNil() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        root.children[0].isFocusable = true
        root.children[1].isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == root.children[1].id)
    }
}

@Suite("FocusEngine — key handler routing baseline")
@MainActor
struct FocusEngineRoutingTests {

    @Test("routeKeyEvent with no focus returns false")
    func routeWithNoFocus() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: Text("x"))
        let engine = FocusEngine()
        let handled = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root)
        #expect(handled == false)
    }

    @Test("registered handler on focused node is invoked")
    func handlerInvoked() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a") })
        let root = graph.root!
        let target = root.children[0]
        target.isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = target.id

        var called = false
        engine.registerKeyHandler(for: target.id) { _ in
            called = true
            return .handled
        }

        let handled = engine.routeKeyEvent(KeyEvent(key: .enter), root: root)
        #expect(called == true)
        #expect(handled == true)
    }

    @Test("handler returning .ignored bubbles to ancestor")
    func handlerBubbles() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a") })
        let root = graph.root!
        let child = root.children[0]
        child.isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = child.id

        var childCalled = false
        var parentCalled = false
        engine.registerKeyHandler(for: child.id) { _ in
            childCalled = true
            return .ignored
        }
        engine.registerKeyHandler(for: root.id) { _ in
            parentCalled = true
            return .handled
        }

        let handled = engine.routeKeyEvent(KeyEvent(key: .enter), root: root)
        #expect(childCalled == true)
        #expect(parentCalled == true)
        #expect(handled == true)
    }

    @Test("clearHandlers removes all registrations")
    func clearHandlers() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a") })
        let root = graph.root!
        let target = root.children[0]
        target.isFocusable = true
        let engine = FocusEngine()
        engine.rebuildIndex(root: root)
        engine.keyboardFocusID = target.id
        engine.registerKeyHandler(for: target.id) { _ in .handled }
        engine.clearHandlers()
        let handled = engine.routeKeyEvent(KeyEvent(key: .enter), root: root)
        #expect(handled == false)
    }
}

@Suite("FocusEngine — mouse hover baseline")
@MainActor
struct FocusEngineMouseTests {

    @Test("isKeyboardFocused returns true for matching ID")
    func isKeyboardFocused() {
        let engine = FocusEngine()
        engine.keyboardFocusID = NodeID.root
        #expect(engine.isKeyboardFocused(NodeID.root))
    }

    @Test("isMouseHovered returns true for matching ID")
    func isMouseHovered() {
        let engine = FocusEngine()
        engine.mouseHoverID = NodeID.root
        #expect(engine.isMouseHovered(NodeID.root))
    }
}
