import Foundation
import Testing
@testable import TerminalUI

// `ActionScope` is the tree of actions a view defines. The framework
// walks the focus chain to root and aggregates the visible scope at
// any point — matching GTK's accelerator model + SwiftUI's Commands.
//
// At the value-type layer (this suite) the scope is a list of
// BoundActions plus optional nested scopes. Construction is via the
// `@ActionBuilder` result builder so `.actions { ... }` reads
// declaratively.

@Suite("ActionScope — value semantics + builder")
struct ActionScopeTests {

    @Test("empty scope has no actions and no children")
    func emptyScope() {
        let scope = ActionScope()
        #expect(scope.boundActions.isEmpty)
        #expect(scope.children.isEmpty)
    }

    @Test("ActionBuilder collects single bound action")
    func builderSingleBound() {
        let action = Action(id: "test.x", title: .literal("X"), perform: {})
        let scope = ActionScope {
            action.bound(to: .keyboard(.character("x"), []))
        }
        #expect(scope.boundActions.count == 1)
        #expect(scope.boundActions[0].action.id == "test.x")
        #expect(scope.boundActions[0].binding == .keyboard(.character("x"), []))
    }

    @Test("ActionBuilder collects bare Action (auto-bind via Action.boundActions)")
    func builderBareAction() {
        // A bare Action (no .bound()) IS valid in the builder when it
        // has no input binding — it surfaces in readouts (help/menu)
        // but isn't dispatchable from any device. ID-addressable from
        // MCP/scripting still works.
        let action = Action(id: "test.headless", title: .literal("Headless"), perform: {})
        let scope = ActionScope { action }
        #expect(scope.boundActions.isEmpty)
        #expect(scope.unboundActions.count == 1)
        #expect(scope.unboundActions[0].id == "test.headless")
    }

    @Test("ActionBuilder collects multiple actions and bound actions")
    func builderMultiple() {
        let quit = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let dismiss = Action(id: "app.dismiss", title: .literal("Dismiss"), perform: {})
        let scope = ActionScope {
            quit.bound(to: .keyboard(.character("c"), [.ctrl]))
            dismiss.bound(to: .keyboard(.escape, []))
            quit.bound(to: .keyboard(.character("q"), []))   // second binding for quit
        }
        #expect(scope.boundActions.count == 3)
        let actionIDs = Set(scope.boundActions.map(\.action.id))
        #expect(actionIDs == ["app.quit", "app.dismiss"])
    }

    @Test("scope binding lookup returns the matching BoundAction")
    func bindingLookup() {
        let quit = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let dismiss = Action(id: "app.dismiss", title: .literal("Dismiss"), perform: {})
        let scope = ActionScope {
            quit.bound(to: .keyboard(.character("c"), [.ctrl]))
            dismiss.bound(to: .keyboard(.escape, []))
        }
        let hit = scope.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        #expect(hit?.action.id == "app.quit")
        let miss = scope.boundAction(for: .keyboard(.character("z"), []))
        #expect(miss == nil)
    }

    @Test("scope action(by:) returns by ID — for MCP / scripting / debugger")
    func lookupByID() {
        let quit = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let scope = ActionScope {
            quit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let hit = scope.action(by: "app.quit")
        #expect(hit?.title == .literal("Quit"))
        let miss = scope.action(by: "app.nonexistent")
        #expect(miss == nil)
    }

    @Test("nested scope: child overrides parent for same binding")
    func childOverridesParent() {
        let parentQuit = Action(id: "app.quit", title: .literal("Parent Quit"), perform: {})
        let childQuit = Action(id: "editor.quit", title: .literal("Editor Quit"), perform: {})
        let parent = ActionScope {
            parentQuit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let child = ActionScope {
            childQuit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        // Combined scope walks innermost-first.
        let combined = ActionScope.combined(outer: parent, inner: child)
        let hit = combined.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        #expect(hit?.action.id == "editor.quit",
                "innermost scope must win when multiple scopes bind the same chord")
    }

    @Test("nested scope: parent binding survives when child doesn't shadow it")
    func parentSurvivesIfNotShadowed() {
        let parentQuit = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let childSave = Action(id: "editor.save", title: .literal("Save"), perform: {})
        let parent = ActionScope {
            parentQuit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let child = ActionScope {
            childSave.bound(to: .keyboard(.character("s"), [.ctrl]))
        }
        let combined = ActionScope.combined(outer: parent, inner: child)
        let quitHit = combined.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        let saveHit = combined.boundAction(for: .keyboard(.character("s"), [.ctrl]))
        #expect(quitHit?.action.id == "app.quit")
        #expect(saveHit?.action.id == "editor.save")
    }

    @Test("disabled action does not match binding lookup")
    func disabledActionNotDispatchable() {
        let quit = Action(
            id: "app.quit",
            title: .literal("Quit"),
            isEnabled: false,
            perform: {}
        )
        let scope = ActionScope {
            quit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let hit = scope.boundAction(for: .keyboard(.character("c"), [.ctrl]))
        #expect(hit == nil,
                "disabled actions must not dispatch from binding lookup; they still appear in readouts (help/menu) but greyed")
    }

    @Test("disabled action still appears in allActions for readouts")
    func disabledActionVisibleInReadouts() {
        let quit = Action(
            id: "app.quit",
            title: .literal("Quit"),
            isEnabled: false,
            perform: {}
        )
        let scope = ActionScope {
            quit.bound(to: .keyboard(.character("c"), [.ctrl]))
        }
        let all = scope.allActions
        #expect(all.contains(where: { $0.id == "app.quit" }))
    }
}
