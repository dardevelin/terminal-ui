import Testing
@testable import TerminalUI

// Today only Ctrl+C is hardcoded in the runtime. Filing a single
// shortcut requires editing the framework or stuffing onEvent
// switches into app code. The eventual API is a `Shortcut` value
// type plus a registry on `TerminalAppProtocol` so app authors can
// declare keybindings the way they declare timers.
//
// User direction (verbatim 2026-04-17):
// "we need a proper way to attribute globally listened clicks,
// shortcut events"
//
// Disabled until the registry lands. The disabled-reason string IS
// the contract — when the API ships, flip the test to active and
// assert the shortcut handler fires on the chord.

@Suite("Global shortcuts API — register app-level keybindings")
@MainActor
struct GlobalShortcutsTests {

    @Test(
        "Shortcut struct exists and can be registered on the app",
        .disabled(if: true, "Shortcut type + TerminalAppProtocol.shortcuts registry not implemented yet — pin will go active when the API ships")
    )
    func shortcutsRegistryExists() {
        // Compile-only red. Real test: register a shortcut, fire its
        // chord, assert handler ran.
        // let _: Shortcut = Shortcut(.character("p"), modifiers: [.ctrl]) { }
    }
}
