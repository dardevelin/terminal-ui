import Testing
@testable import TerminalUI

// A handler runs on the main actor though its type does not say so, and an
// app whose model is `@MainActor` reaches it through
// `MainActor.assumeIsolated`, whose result must be Sendable.

@Suite("A key handler's result")
struct KeyEventResultTests {
    @MainActor @Test func aHandlerWorksItsResultOutOnTheMainActor() {
        let decide: (KeyEvent) -> KeyEventResult = { event in
            MainActor.assumeIsolated { event.key == .enter ? .handled : .ignored }
        }
        #expect(decide(KeyEvent(key: .enter)) == .handled)
        #expect(decide(KeyEvent(key: .tab)) == .ignored)
    }
}
