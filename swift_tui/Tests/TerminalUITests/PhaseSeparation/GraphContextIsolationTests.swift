import Foundation
import Testing
@testable import TerminalUI

// External review R3 — `GraphContext` was five `nonisolated(unsafe)`
// global statics: writes from one body evaluation leaked into every
// other concurrent reader. The fix is `@TaskLocal` scoping —
// `withValue` binds for the duration of a closure, restores on exit,
// and is per-task isolated.
//
// These tests pin the post-migration contract:
//
//   1. Reading outside a `withValue` scope returns the default (nil).
//   2. A binding is visible only to its closure, not after it returns.
//   3. A binding on one task is not visible on a sibling/detached task.
//
// On the pre-migration code (plain `var` statics), test 3 fails:
// setting `currentNode` on task A leaks into a `Task.detached` because
// they share the same backing storage.

@Suite("GraphContext isolation — TaskLocal scoping")
struct GraphContextIsolationTests {

    @Test("currentNode default is nil outside any withValue scope")
    func defaultIsNil() {
        // @TaskLocal default is nil; each `@Test` runs in its own
        // task so no prior `withValue` binding can leak in.
        #expect(GraphContext.currentNode == nil)
    }

    @Test("withValue binds for closure duration and restores on exit")
    func withValueScopes() async {
        let node = AttributeNode(id: NodeID.root, kind: .primitive(.empty))
        // Pre-condition: outside the scope, no node bound.
        #expect(GraphContext.currentNode == nil)

        await GraphContext.$currentNode.withValue(node) {
            #expect(GraphContext.currentNode === node,
                    "currentNode must be the bound node inside withValue")
        }

        // Post-condition: scope ended, value restored to default.
        #expect(GraphContext.currentNode == nil,
                "currentNode must restore to nil after withValue exits")
    }

    @Test("binding does not leak across detached tasks")
    func doesNotLeakToDetachedTask() async {
        let node = AttributeNode(id: NodeID.root, kind: .primitive(.empty))
        await GraphContext.$currentNode.withValue(node) {
            // Inside the binding's closure, a detached task starts a
            // fresh task tree — TaskLocal does NOT propagate across
            // detachment. The detached body must observe the default,
            // not the parent's binding.
            let leaked: Bool = await Task.detached {
                return GraphContext.currentNode != nil
            }.value
            #expect(!leaked,
                    "Task.detached must not see parent's currentNode binding")
        }
    }

    @Test("binding propagates to structured child tasks")
    func propagatesToChildTask() async {
        let node = AttributeNode(id: NodeID.root, kind: .primitive(.empty))
        await GraphContext.$currentNode.withValue(node) {
            // Structured child tasks DO inherit task-local values —
            // this is the half of the model that lets renderer +
            // measurer read the same node when the runtime drives
            // them from a single MainActor task.
            let seenSame: Bool = await Task {
                return GraphContext.currentNode === node
            }.value
            #expect(seenSame,
                    "Structured Task { ... } must inherit currentNode binding")
        }
    }

    @Test("nested withValue stacks and unwinds correctly")
    func nestedScopes() async {
        let outer = AttributeNode(id: NodeID.root, kind: .primitive(.empty))
        let inner = AttributeNode(id: NodeID.root.appending(.index(0)), kind: .primitive(.empty))

        await GraphContext.$currentNode.withValue(outer) {
            #expect(GraphContext.currentNode === outer)
            await GraphContext.$currentNode.withValue(inner) {
                #expect(GraphContext.currentNode === inner,
                        "Inner scope shadows outer binding")
            }
            #expect(GraphContext.currentNode === outer,
                    "Inner scope exited — outer must be visible again")
        }
        #expect(GraphContext.currentNode == nil,
                "All scopes exited — value must be the default")
    }
}
