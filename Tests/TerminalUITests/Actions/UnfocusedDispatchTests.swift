import Foundation
import Testing
@testable import TerminalUI

// With nothing focused, a key is addressed to the window. Dispatch used to
// start from the graph root and walk up from there, which meets no scope at
// all — every `.actions` an app declares sits below the root — so the
// framework's Escape and Ctrl+C could not be overridden by an app with no
// focusable view, and Escape quit an agent chat whose prompt was not yet a
// control.

private struct AppRoot: TerminalView {
    let app: TestCounter
    let sidebar: TestCounter

    var body: some TerminalView {
        HStack {
            Text("transcript")
            Text("sidebar").actions {
                Action(id: "sidebar.cancel", title: .literal("Sidebar"), perform: { sidebar.bump() })
                    .bound(to: .keyboard(.escape, []))
            }
        }
        .background(.black)
        .actions {
            Action(id: "app.cancel", title: .literal("Cancel"), perform: { app.bump() })
                .bound(to: .keyboard(.escape, []))
        }
    }
}

@Suite("Unfocused keys reach the scopes around the whole app")
@MainActor
struct UnfocusedDispatchTests {

    private func dispatchEscape(focus: (AttributeNode) -> NodeID?) -> (app: Int, sidebar: Int, quit: Int) {
        let app = TestCounter(), sidebar = TestCounter(), quit = TestCounter()
        let graph = AttributeGraph()
        graph.update(from: AppRoot(app: app, sidebar: sidebar))
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        engine.keyboardFocusID = focus(graph.root!)
        let origin = engine.focusedNode(in: graph.root)!
        _ = ActionDispatch.dispatch(
            binding: .keyboard(.escape, []),
            from: origin,
            frameworkDefaults: .frameworkDefaults(quit: { quit.bump() }, dismissOrQuit: { quit.bump() })
        )
        return (app.value, sidebar.value, quit.value)
    }

    @Test func anAppScopeShadowsTheDefaultWithNothingFocused() {
        let fired = dispatchEscape { _ in nil }
        #expect(fired.app == 1, "the scope around the whole app answers")
        #expect(fired.quit == 0, "the framework default is shadowed")
        #expect(fired.sidebar == 0, "a scope on one part of the window does not")
    }

    @Test func aDetachedFocusFallsBackToTheWindowToo() {
        let fired = dispatchEscape { $0.id.appending(.index(99)) }
        #expect(fired.app == 1)
        #expect(fired.quit == 0)
    }

    @Test func theWindowIsTheFirstNodeThatSplits() {
        let graph = AttributeGraph()
        graph.update(from: AppRoot(app: TestCounter(), sidebar: TestCounter()))
        let window = FocusEngine.windowContent(in: graph.root!)
        guard case .layout = window.kind else {
            Issue.record("expected the HStack, got \(window.kind)")
            return
        }
        #expect(window.children.count == 2)
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
