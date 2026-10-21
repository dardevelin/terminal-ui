import Foundation
import Testing
@testable import TerminalUI

// ActionContext stack value type + scoped key bindings.
// i3-faithful "modes" reimagined as a sparse predicate on each binding,
// not a global mode state machine. Stack-based so nested modes work.

@Suite("ActionContext — stack value-type semantics")
struct ActionContextTests {

    @Test("push then pop restores empty state")
    func pushPopRestoresEmpty() {
        var ctx = ActionContext()
        ctx.push("resize")
        #expect(ctx.current == "resize")
        ctx.pop()
        #expect(ctx.current == nil)
        #expect(ctx.stack.isEmpty)
    }

    @Test("current returns the top of the stack")
    func currentReturnsTopOfStack() {
        var ctx = ActionContext()
        ctx.push("a")
        ctx.push("b")
        #expect(ctx.current == "b", "current should reflect the top, not the bottom")
    }

    @Test("contains matches any level of the stack")
    func containsMatchesAnyLevel() {
        var ctx = ActionContext()
        ctx.push("a")
        ctx.push("b")
        #expect(ctx.contains("a"), "deeper level should still be reachable via contains")
        #expect(ctx.contains("b"))
        #expect(!ctx.contains("c"))
    }

    @Test("clear empties the stack")
    func clearEmptiesStack() {
        var ctx = ActionContext()
        ctx.push("a")
        ctx.push("b")
        ctx.clear()
        #expect(ctx.stack.isEmpty)
        #expect(ctx.current == nil)
    }

    @Test("Equatable compares by stack value")
    func equatableComparesByValue() {
        var a = ActionContext()
        a.push("resize")
        var b = ActionContext()
        b.push("resize")
        #expect(a == b)
        a.push("extra")
        #expect(a != b)
    }

    @Test("pop on empty stack is a no-op")
    func popOnEmptyIsNoOp() {
        var ctx = ActionContext()
        ctx.pop()  // must not crash
        #expect(ctx.current == nil)
    }
}

@Suite("Scoped key-bindings — whenContext + whenContextContains")
@MainActor
struct ScopedBindingTests {

    /// Reference-typed fire counter so test closures can mutate without
    /// fighting strict-concurrency capture semantics. The Action's
    /// `perform` closure is `@Sendable`; sending an integer-by-reference
    /// via a `@MainActor final class` keeps the increment main-thread
    /// isolated (which is where tests run anyway).
    @MainActor
    final class Counter {
        var value: Int = 0
    }

    private func makeAction(id: String, counter: Counter) -> Action {
        Action(
            id: ActionID(id),
            title: .literal(id),
            perform: { @Sendable [counter] in
                MainActor.assumeIsolated { counter.value += 1 }
            }
        )
    }

    @Test("binding without whenContext fires regardless of active context")
    func bindingWithoutContextAlwaysFires() {
        let counter = Counter()
        let action = makeAction(id: "always", counter: counter)
        let bound = action.bound(to: .keyboard(.character("a"), []))

        let scope = ActionScope(boundActions: [bound])

        // Empty context: fires.
        var emptyCtx = ActionContext()
        let hit1 = scope.boundAction(for: .keyboard(.character("a"), []), context: emptyCtx)
        #expect(hit1 != nil)
        hit1?.action.perform()

        // Non-empty context: still fires (no whenContext gate on this binding).
        emptyCtx.push("resize")
        let hit2 = scope.boundAction(for: .keyboard(.character("a"), []), context: emptyCtx)
        #expect(hit2 != nil)
        hit2?.action.perform()

        #expect(counter.value == 2)
    }

    @Test("binding scoped by whenContext only fires when that context is current")
    func bindingScopedByContextOnlyFiresWhenActive() {
        let counter = Counter()
        let action = makeAction(id: "resize.right", counter: counter)
        let bound = action.bound(to: .keyboard(.character("l"), []), whenContext: "resize")

        let scope = ActionScope(boundActions: [bound])

        // No context: does NOT fire.
        let outside = ActionContext()
        #expect(scope.boundAction(for: .keyboard(.character("l"), []), context: outside) == nil,
                "binding requires resize context — must not match in default context")

        // Different context: does NOT fire.
        var other = ActionContext()
        other.push("move")
        #expect(scope.boundAction(for: .keyboard(.character("l"), []), context: other) == nil)

        // Matching context: fires.
        var resize = ActionContext()
        resize.push("resize")
        let hit = scope.boundAction(for: .keyboard(.character("l"), []), context: resize)
        #expect(hit != nil)
        hit?.action.perform()
        #expect(counter.value == 1)
    }

    @Test("whenContextContains matches when context appears anywhere on the stack")
    func bindingScopedByContainsAnyFiresWhenContextDeep() {
        let counter = Counter()
        let action = makeAction(id: "deep", counter: counter)
        let bound = action.bound(to: .keyboard(.character("x"), []), whenContextContains: "resize")

        let scope = ActionScope(boundActions: [bound])

        var deep = ActionContext()
        deep.push("resize")
        deep.push("super")  // resize is no longer current, but still on the stack

        let hit = scope.boundAction(for: .keyboard(.character("x"), []), context: deep)
        #expect(hit != nil, "whenContextContains should match deeper levels of the stack")
        hit?.action.perform()
        #expect(counter.value == 1)
    }

    @Test("multiple bindings to same key dispatch by current context")
    func multipleBindingsSameKeyDispatchByContext() {
        let defaultCounter = Counter()
        let resizeCounter = Counter()
        let defaultAction = makeAction(id: "default.l", counter: defaultCounter)
        let resizeAction = makeAction(id: "resize.l", counter: resizeCounter)

        let scope = ActionScope(boundActions: [
            // Resize-scoped binding listed FIRST so it wins when context matches.
            // ActionScope.boundAction(for:context:) returns the first hit.
            resizeAction.bound(to: .keyboard(.character("l"), []), whenContext: "resize"),
            defaultAction.bound(to: .keyboard(.character("l"), []))
        ])

        // No context: only the default fires.
        let outside = ActionContext()
        scope.boundAction(for: .keyboard(.character("l"), []), context: outside)?.action.perform()
        #expect(defaultCounter.value == 1)
        #expect(resizeCounter.value == 0)

        // Resize context: the resize-scoped binding fires.
        var resize = ActionContext()
        resize.push("resize")
        scope.boundAction(for: .keyboard(.character("l"), []), context: resize)?.action.perform()
        #expect(defaultCounter.value == 1, "default must NOT fire when resize-scoped binding matched")
        #expect(resizeCounter.value == 1)
    }

    @Test("default whenContext nil parameter preserves existing API behaviour")
    func backwardsCompatibleAPI() {
        // Existing callers write `.bound(to: .keyboard(.character("a"), []))`
        // without a whenContext: parameter. That must continue to compile +
        // fire unconditionally.
        let counter = Counter()
        let action = makeAction(id: "legacy", counter: counter)
        let bound = action.bound(to: .keyboard(.character("a"), []))

        // The bound action carries no context predicate.
        #expect(bound.contextRequirement == nil,
                "no whenContext: parameter → contextRequirement is nil")
    }

    @Test("ActionDispatch reads context from focused node's env and filters")
    func dispatchReadsContextFromNodeEnv() {
        // End-to-end: build a tiny graph with an action scope on a node,
        // set the node's env's actionContext, dispatch and verify the
        // scoped binding only fires when the env says so.
        let counter = Counter()
        let resizeAction = makeAction(id: "resize.right", counter: counter)
        let scope = ActionScope(boundActions: [
            resizeAction.bound(to: .keyboard(.character("l"), []), whenContext: "resize")
        ])

        let node = AttributeNode(id: NodeID.root, kind: .primitive(.text([])))
        node._actionScope = scope

        // Default env: no context. Dispatch must NOT fire.
        node._resolvedEnv = EnvironmentValues()
        let firedDefault = ActionDispatch.dispatch(
            binding: .keyboard(.character("l"), []),
            from: node
        )
        #expect(!firedDefault, "default context should not match resize-scoped binding")
        #expect(counter.value == 0)

        // Env with resize context: dispatch must fire.
        var env = EnvironmentValues()
        env.actionContext.push("resize")
        node._resolvedEnv = env
        let firedResize = ActionDispatch.dispatch(
            binding: .keyboard(.character("l"), []),
            from: node
        )
        #expect(firedResize, "resize context should let the scoped binding match")
        #expect(counter.value == 1)
    }
}
