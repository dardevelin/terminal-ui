import Testing
@testable import TerminalUI

// `InputBinding` is the device-side half of the action graph: a way to
// invoke an action. One action graph, many binding tables — keyboard,
// mouse, gesture, voice, accessibility — each fires the same handler.
// Binding values are Hashable so dispatchers can use them as dictionary
// keys without hashing the carrying action.

@Suite("InputBinding — value semantics")
struct InputBindingTests {

    @Test("keyboard binding equality matches by key + modifiers")
    func keyboardEquality() {
        let a: InputBinding = .keyboard(.character("c"), [.ctrl])
        let b: InputBinding = .keyboard(.character("c"), [.ctrl])
        let c: InputBinding = .keyboard(.character("c"), [])
        let d: InputBinding = .keyboard(.character("d"), [.ctrl])
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("mouse binding equality matches by button + modifiers")
    func mouseEquality() {
        let a: InputBinding = .mouse(.left, [])
        let b: InputBinding = .mouse(.left, [])
        let c: InputBinding = .mouse(.right, [])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("different binding kinds compare unequal")
    func crossKindInequality() {
        let kbd: InputBinding = .keyboard(.character("c"), [.ctrl])
        let mouse: InputBinding = .mouse(.left, [])
        let gesture: InputBinding = .gesture(.init("swipeLeft"))
        let voice: InputBinding = .voice("quit")
        let a11y: InputBinding = .accessibility("Quit")
        #expect(kbd != mouse)
        #expect(mouse != gesture)
        #expect(gesture != voice)
        #expect(voice != a11y)
    }

    @Test("InputBinding is Hashable — usable as a dictionary key")
    func hashableKey() {
        var table: [InputBinding: ActionID] = [:]
        table[.keyboard(.character("c"), [.ctrl])] = "app.quit"
        table[.keyboard(.escape, [])] = "app.dismiss"
        #expect(table[.keyboard(.character("c"), [.ctrl])] == "app.quit")
        #expect(table[.keyboard(.character("d"), [.ctrl])] == nil)
        #expect(table.count == 2)
    }
}

@Suite("Action.bound(to:) — pairs an action with a binding")
struct ActionBindingTests {

    @Test("bound returns a BoundAction carrying both pieces")
    func boundReturnsPair() {
        let action = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let bound = action.bound(to: .keyboard(.character("c"), [.ctrl]))
        #expect(bound.action.id == "app.quit")
        #expect(bound.binding == .keyboard(.character("c"), [.ctrl]))
    }

    @Test("an action can be bound to multiple bindings")
    func multipleBindings() {
        let action = Action(id: "app.quit", title: .literal("Quit"), perform: {})
        let bindings: [InputBinding] = [
            .keyboard(.character("c"), [.ctrl]),
            .keyboard(.character("q"), []),
            .accessibility("Quit Application"),
        ]
        let bound = bindings.map { action.bound(to: $0) }
        #expect(bound.count == 3)
        #expect(Set(bound.map(\.binding)).count == 3)
        // All point at the same action ID.
        #expect(Set(bound.map(\.action.id)).count == 1)
    }
}
