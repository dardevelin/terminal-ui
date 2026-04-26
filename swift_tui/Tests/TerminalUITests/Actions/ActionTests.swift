import Foundation
import Testing
@testable import TerminalUI

// `Action` is the unit of behavior — addressable, named, decoupled from
// any input device. `ActionID` is a stable string-shaped identifier so
// actions stay reachable across tests, MCP scripting, and serialization
// without depending on closure identity. `LocalizedString` carries the
// human-readable label; tests use the `.literal(_:)` constructor that
// bypasses any locale negotiation.

@Suite("Action — value semantics")
struct ActionTests {

    @Test("identifier is value-equal across construction sites")
    func identifierEquality() {
        let a = ActionID("app.quit")
        let b = ActionID("app.quit")
        let c = ActionID("app.dismiss")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Action can be constructed with id, title, and perform closure")
    func basicConstruction() {
        let counter = FireCounter()
        let action = Action(
            id: "test.fire",
            title: .literal("Fire"),
            perform: { counter.bump() }
        )
        #expect(action.id == ActionID("test.fire"))
        #expect(action.title == .literal("Fire"))
        #expect(action.description == nil)
        #expect(action.isEnabled == true)
        action.perform()
        #expect(counter.value == 1)
    }

    @Test("description and isEnabled are optional with sensible defaults")
    func optionalsHaveDefaults() {
        let action = Action(
            id: "test.x",
            title: .literal("X"),
            description: .literal("Detail"),
            isEnabled: false,
            perform: {}
        )
        #expect(action.description == .literal("Detail"))
        #expect(action.isEnabled == false)
    }

    @Test("LocalizedString.literal carries its raw value verbatim")
    func localizedStringLiteral() {
        let s = LocalizedString.literal("Quit")
        #expect(s.resolved() == "Quit")
    }

    @Test("LocalizedString equality is value-based")
    func localizedStringEquality() {
        #expect(LocalizedString.literal("Quit") == LocalizedString.literal("Quit"))
        #expect(LocalizedString.literal("Quit") != LocalizedString.literal("Save"))
    }
}

/// Test-only Sendable counter used by @Sendable perform closures.
/// Reference type so the closure captures by reference; lock-protected
/// because @Sendable means the closure may execute off the test's
/// isolation context.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
