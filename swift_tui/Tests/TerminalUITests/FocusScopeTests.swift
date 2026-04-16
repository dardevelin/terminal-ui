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

// HYP-40: .focusScope(id) groups focusable descendants so arrow keys stay
// within the scope. Tab still crosses scopes (SwiftUI convention).

@Suite("FocusScope — graph construction")
@MainActor
struct FocusScopeConstructionTests {

    @Test("focusScope stamps scopeID on focusable descendants")
    func stampsScopeID() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("a").focusable()
            Text("b").focusable()
        }.focusScope("row"))

        let focusables = collectFocusables(graph.root!)
        #expect(focusables.count == 2)
        #expect(focusables.allSatisfy { $0.scopeID == "row" })
    }

    @Test("no scope → nil scopeID on focusables")
    func noScope() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: HStack {
            Text("a").focusable()
            Text("b").focusable()
        })
        let focusables = collectFocusables(graph.root!)
        #expect(focusables.allSatisfy { $0.scopeID == nil })
    }

    @Test("different scopes produce different scopeIDs")
    func distinctScopes() {
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: VStack {
            HStack {
                Text("a").focusable()
                Text("b").focusable()
            }.focusScope("row1")
            HStack {
                Text("c").focusable()
                Text("d").focusable()
            }.focusScope("row2")
        })
        let focusables = collectFocusables(graph.root!)
        #expect(focusables.count == 4)
        #expect(focusables.filter { $0.scopeID == "row1" }.count == 2)
        #expect(focusables.filter { $0.scopeID == "row2" }.count == 2)
    }
}

@Suite("FocusScope — arrow navigation clamped to scope")
@MainActor
struct FocusScopeNavigationTests {

    /// Build: VStack { HStack{A B}.focusScope("top") ; HStack{C D}.focusScope("bot") }
    /// Returns graph + engine with keyboardFocus set to A.
    private func makeScopedLayout() -> (AttributeGraph, FocusEngine, [AttributeNode]) {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            HStack {
                Text("a").focusable()
                Text("b").focusable()
            }.focusScope("top")
            HStack {
                Text("c").focusable()
                Text("d").focusable()
            }.focusScope("bot")
        })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let focusables = collectFocusables(graph.root!)
        engine.keyboardFocusID = focusables[0].id
        return (graph, engine, focusables)
    }

    @Test("right arrow moves within scope")
    func rightWithinScope() {
        resetGraphContext()
        let (graph, engine, focusables) = makeScopedLayout()
        engine.focusInDirection(.right, root: graph.root)
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("right arrow at end of scope does NOT cross into next scope")
    func rightStopsAtScopeEdge() {
        resetGraphContext()
        let (graph, engine, focusables) = makeScopedLayout()
        engine.keyboardFocusID = focusables[1].id  // B, last in "top"
        engine.focusInDirection(.right, root: graph.root)
        // Stays on B — does not jump to C or D in "bot"
        #expect(engine.keyboardFocusID == focusables[1].id)
    }

    @Test("left arrow at scope start stays put")
    func leftStopsAtScopeStart() {
        resetGraphContext()
        let (graph, engine, focusables) = makeScopedLayout()
        // Already on A (first in "top")
        engine.focusInDirection(.left, root: graph.root)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }

    @Test("wrong-axis arrow in a scope does NOT fall back to Tab order")
    func wrongAxisDoesNotLeakOutOfScope() {
        resetGraphContext()
        let (graph, engine, focusables) = makeScopedLayout()
        // In HStack, 'down' is wrong axis. Pre-HYP-40 would focusNext → leak to C.
        // With scopes, it should be a no-op.
        engine.focusInDirection(.down, root: graph.root)
        #expect(engine.keyboardFocusID == focusables[0].id)
    }

    @Test("Tab still crosses scopes")
    func tabCrossesScopes() {
        resetGraphContext()
        let (_, engine, focusables) = makeScopedLayout()
        engine.keyboardFocusID = focusables[1].id  // B, end of top scope
        engine.focusNext()
        #expect(engine.keyboardFocusID == focusables[2].id)  // C, start of bot scope
    }
}

// MARK: - Test helpers

@MainActor
private func collectFocusables(_ root: AttributeNode) -> [AttributeNode] {
    var result: [AttributeNode] = []
    walk(root, into: &result)
    return result
}

@MainActor
private func walk(_ node: AttributeNode, into result: inout [AttributeNode]) {
    if node.isFocusable { result.append(node) }
    for child in node.children { walk(child, into: &result) }
}
