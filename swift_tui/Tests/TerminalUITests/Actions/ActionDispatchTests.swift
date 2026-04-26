import Foundation
import Testing
@testable import TerminalUI

// `ActionDispatch` walks the focused node up to root, accumulating the
// `_actionScope` from each modifier ancestor it encounters. The
// resulting aggregate scope is queried for a binding match; first hit
// fires the bound action. This suite pins:
//
//   - leaf-attached actions fire when their chord matches
//   - ancestor scopes are reachable from a focused leaf
//   - innermost (nearest-to-leaf) scope wins on conflicting bindings
//   - non-matching chords return false (caller falls through to default)
//   - disabled actions do not dispatch (binding lookup skips them)
//
// Tests construct a graph manually via AttributeGraph + manually
// pointing the focus engine; this is the unit-level seam — real
// runtime integration ships in layer 6.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

@Suite("ActionDispatch — focus-chain walker matches bindings")
@MainActor
struct ActionDispatchTests {

    @Test("leaf-attached action fires on chord match")
    func leafActionFires() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            Action(id: "leaf.fire", title: .literal("Fire"), perform: { counter.bump() })
                .bound(to: .keyboard(.character("f"), [.ctrl]))
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("f"), [.ctrl]),
            from: leaf
        )
        #expect(fired == true)
        #expect(counter.value == 1)
    }

    @Test("non-matching chord returns false — caller falls through")
    func nonMatchingChordFallsThrough() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            Action(id: "leaf.fire", title: .literal("Fire"), perform: { counter.bump() })
                .bound(to: .keyboard(.character("f"), [.ctrl]))
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("z"), []),
            from: leaf
        )
        #expect(fired == false)
        #expect(counter.value == 0)
    }

    @Test("ancestor scope reachable from focused leaf")
    func ancestorScopeReached() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        // Outer scope on a VStack; inner Text is the focused leaf.
        graph.update(from: VStack {
            Text("inside")
        }.actions {
            Action(id: "outer.quit", title: .literal("Quit"), perform: { counter.bump() })
                .bound(to: .keyboard(.character("c"), [.ctrl]))
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("c"), [.ctrl]),
            from: leaf
        )
        #expect(fired == true)
        #expect(counter.value == 1)
    }

    @Test("innermost scope wins on conflicting bindings")
    func innermostWins() {
        resetGraphContext()
        let outerCounter = TestCounter()
        let innerCounter = TestCounter()
        let graph = AttributeGraph()
        // Both outer and inner scope bind Ctrl+X. Inner must win.
        graph.update(from: VStack {
            Text("inner")
                .actions {
                    Action(id: "inner.action", title: .literal("Inner"), perform: { innerCounter.bump() })
                        .bound(to: .keyboard(.character("x"), [.ctrl]))
                }
        }.actions {
            Action(id: "outer.action", title: .literal("Outer"), perform: { outerCounter.bump() })
                .bound(to: .keyboard(.character("x"), [.ctrl]))
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("x"), [.ctrl]),
            from: leaf
        )
        #expect(fired == true)
        #expect(innerCounter.value == 1, "innermost scope must fire")
        #expect(outerCounter.value == 0, "outer scope must NOT fire when shadowed")
    }

    @Test("disabled action does not dispatch")
    func disabledActionSkipped() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            Action(
                id: "leaf.disabled",
                title: .literal("Disabled"),
                isEnabled: false,
                perform: { counter.bump() }
            )
            .bound(to: .keyboard(.character("d"), []))
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("d"), []),
            from: leaf
        )
        #expect(fired == false, "disabled action must not dispatch")
        #expect(counter.value == 0)
    }

    @Test("invoke(_:from:) fires by ID — for MCP / scripting / debugger")
    func invokeByID() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            // No binding — only reachable by ID.
            Action(id: "scriptable.run", title: .literal("Run"), perform: { counter.bump() })
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.invoke(id: "scriptable.run", from: leaf)
        #expect(fired == true)
        #expect(counter.value == 1)
    }

    @Test("invoke skips disabled actions")
    func invokeRespectsDisabled() {
        resetGraphContext()
        let counter = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: Text("hello").actions {
            Action(
                id: "scriptable.run",
                title: .literal("Run"),
                isEnabled: false,
                perform: { counter.bump() }
            )
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }
        let fired = ActionDispatch.invoke(id: "scriptable.run", from: leaf)
        #expect(fired == false, "invoke() must skip disabled actions")
        #expect(counter.value == 0)
    }
}

// Walks down node.children[0] until we hit a leaf — used to simulate
// "focus is on the deepest content node" without spinning up the focus
// engine. Real runtime uses focusEngine.focusedNode; the dispatch
// surface is identical.
@MainActor
private func leafmost(_ node: AttributeNode?) -> AttributeNode? {
    var current = node
    while let n = current, !n.children.isEmpty {
        current = n.children[0]
    }
    return current
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
