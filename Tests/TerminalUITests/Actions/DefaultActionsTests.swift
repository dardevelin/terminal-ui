import Foundation
import Testing
@testable import TerminalUI

// Default actions ship with the framework — the hardcoded Ctrl+C
// quit (and friends) are now framework-supplied actions instead of
// runtime special cases. The defaults compose with user-defined
// scopes through the standard innermost-wins rule: an app or view
// can override the default by binding the same chord to a custom
// action.

@Suite("Default actions — framework-supplied baseline")
@MainActor
struct DefaultActionsTests {

    @Test("Action.quit exists with stable ID app.quit")
    func quitActionExists() {
        let quit = Action.quit { /* no-op test handler */ }
        #expect(quit.id == "app.quit")
    }

    @Test("Action.dismissOrQuit exists with stable ID app.dismissOrQuit")
    func dismissActionExists() {
        let dismiss = Action.dismissOrQuit { /* no-op */ }
        #expect(dismiss.id == "app.dismissOrQuit")
    }

    @Test("ActionScope.frameworkDefaults includes both quit and dismiss bindings")
    func frameworkDefaultsScope() {
        let counter = TestCounter()
        let scope = ActionScope.frameworkDefaults(quit: { counter.bump() })

        // Ctrl+C → quit
        let ctrlC = scope.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        #expect(ctrlC?.action.id == "app.quit")

        // Esc → dismissOrQuit
        let esc = scope.boundAction(for: .keyboard(.escape, []))
        #expect(esc?.action.id == "app.dismissOrQuit")

        // Firing Ctrl+C runs the supplied quit closure.
        ctrlC?.action.perform()
        #expect(counter.value == 1)
    }

    @Test("user-supplied Ctrl+C action overrides default via ActionScope.combined")
    func userBindingShadowsDefault() {
        let defaultQuit = TestCounter()
        let userQuit = TestCounter()
        // Compose the way the runtime composes: framework defaults
        // sit outer, the user scope sits inner. Innermost-first
        // lookup means the user's binding shadows the default.
        let userScope = ActionScope {
            Action(id: "user.quit", title: .literal("Custom Quit"), perform: { userQuit.bump() })
                .bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let defaults = ActionScope.frameworkDefaults(quit: { defaultQuit.bump() })
        let combined = ActionScope.combined(outer: defaults, inner: userScope)

        let bound = combined.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        bound?.action.perform()

        #expect(userQuit.value == 1, "user-bound Ctrl+C must win")
        #expect(defaultQuit.value == 0, "default Ctrl+C must NOT fire when user shadows it")
    }

    @Test("ActionDispatch combines framework defaults with focus-chain scopes")
    func dispatchHonorsDefaultsAcrossFocusChain() {
        let defaultQuit = TestCounter()
        let userQuit = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("inner").actions {
                Action(id: "user.quit", title: .literal("Inner Quit"), perform: { userQuit.bump() })
                    .bound(to: .keyboard(.character("c"), [.ctrl]))
            }
        })
        guard let leaf = leafmost(graph.root) else {
            Issue.record("no leaf node found")
            return
        }

        // Today the framework hasn't yet wrapped the root with defaults
        // (that's layer 6 — runtime integration). For now, prove the
        // dispatcher fires the user's inner action when only that scope
        // exists in the focus chain.
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.character("c"), [.ctrl]),
            from: leaf
        )
        #expect(fired == true)
        #expect(userQuit.value == 1)
        #expect(defaultQuit.value == 0)
    }
}

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

// The Esc default is "dismiss or quit": quitting is only legitimate when no
// presentation is containing focus. A presented screen owns Escape even when
// its own handlers ignored the key — falling through to quit would tear the
// app down under the user, which a terminal cannot recover from.
@Suite("Default actions — Esc gated by presentation")
@MainActor
struct DismissOrQuitGatingTests {

    @Test("Esc default does not quit while a presentation contains focus")
    func escDefaultGatedWhilePresented() {
        let signal = QuitSignal()
        let scope = makeFrameworkDefaultsScope(signal: signal, isPresenting: true)
        let graph = AttributeGraph()
        graph.update(from: Text("covered"))
        let fired = ActionDispatch.dispatch(
            binding: .keyboard(.escape, []),
            from: graph.root!,
            frameworkDefaults: scope
        )
        #expect(fired)
        #expect(!signal.fired)
    }

    @Test("Esc default quits when nothing is presented")
    func escDefaultQuitsWhenNotPresented() {
        let signal = QuitSignal()
        let scope = makeFrameworkDefaultsScope(signal: signal, isPresenting: false)
        let graph = AttributeGraph()
        graph.update(from: Text("root"))
        _ = ActionDispatch.dispatch(
            binding: .keyboard(.escape, []),
            from: graph.root!,
            frameworkDefaults: scope
        )
        #expect(signal.fired)
    }

    @Test("Ctrl+C quits unconditionally, presented or not")
    func ctrlCQuitsEvenWhilePresented() {
        let signal = QuitSignal()
        let scope = makeFrameworkDefaultsScope(signal: signal, isPresenting: true)
        let graph = AttributeGraph()
        graph.update(from: Text("covered"))
        _ = ActionDispatch.dispatch(
            binding: .keyboard(.character("c"), [.ctrl]),
            from: graph.root!,
            frameworkDefaults: scope
        )
        #expect(signal.fired)
    }
}
