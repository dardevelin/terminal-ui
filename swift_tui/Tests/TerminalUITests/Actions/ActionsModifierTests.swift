import Foundation
import Testing
@testable import TerminalUI

// `.actions { ... }` modifier: attaches an ActionScope to the modifier
// node in the graph. The runtime's focus-walker reads these scopes to
// dispatch input bindings. This suite pins the modifier compiles, the
// scope ends up on the node, and the scope round-trips through
// reconciliation.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite(".actions { ... } modifier — graph integration")
@MainActor
struct ActionsModifierTests {

    @Test("modifier compiles on any TerminalView")
    func modifierCompiles() {
        let action = Action(id: "test.x", title: .literal("X"), perform: {})
        let _ = Text("probe").actions {
            action.bound(to: .keyboard(.character("x"), []))
        }
        let _ = VStack { Text("a") }.actions {
            Action(id: "test.y", title: .literal("Y"), perform: {})
        }
    }

    @Test("scope is attached to the modifier node after graph build")
    func scopeAttachedToNode() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            Action(id: "demo.fire", title: .literal("Fire"), perform: { counter.bump() })
                .bound(to: .keyboard(.character("f"), [.ctrl]))
        })
        guard let root = graph.root else {
            Issue.record("no root node")
            return
        }
        // The modifier node carries the action scope.
        let scope = root._actionScope
        #expect(scope != nil, "modifier node must carry an ActionScope after build")
        #expect(scope?.boundActions.count == 1)
        #expect(scope?.boundActions.first?.action.id == "demo.fire")

        // Firing the bound action runs the perform closure.
        scope?.boundActions.first?.action.perform()
        #expect(counter.value == 1)
    }

    @Test("scope round-trips through reconciliation update")
    func scopeRoundTripsAcrossUpdates() {
        resetGraphContext()
        let graph = AttributeGraph()
        let action = Action(id: "demo.toggle", title: .literal("Toggle"), perform: {})

        // First update.
        graph.update(from: Text("v1").actions {
            action.bound(to: .keyboard(.character("t"), []))
        })
        let firstScope = graph.root?._actionScope
        #expect(firstScope?.boundActions.first?.action.id == "demo.toggle")

        // Second update with a different action — scope must reflect new state.
        let action2 = Action(id: "demo.toggle2", title: .literal("Toggle 2"), perform: {})
        graph.update(from: Text("v2").actions {
            action2.bound(to: .keyboard(.character("u"), []))
        })
        let secondScope = graph.root?._actionScope
        #expect(secondScope?.boundActions.first?.action.id == "demo.toggle2")
        #expect(secondScope?.boundActions.first?.binding == .keyboard(.character("u"), []))
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
