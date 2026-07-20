import Testing
@testable import TerminalUI

// `.disabled(_)` is the SwiftUI-shaped modifier that turns a subtree
// off — handlers don't fire, focus skips it. Implementation rides
// `EnvironmentValues.isEnabled` (default true), so any descendant's
// `@TerminalEnvironment(\.isEnabled)` reads the propagated value.
//
// SwiftUI semantics ("most-restrictive wins"): once a parent disables
// a subtree, descendants cannot re-enable themselves. `.disabled(false)`
// nested under `.disabled(true)` stays disabled. The implementation gets
// this for free if the modifier writes `min(parentIsEnabled, !disabled)`
// into the env — i.e., AND with the inherited value.

@Suite("EnvironmentValues.isEnabled — default + propagation")
@MainActor
struct EnvironmentIsEnabledTests {

    @Test("EnvironmentValues.isEnabled defaults to true")
    func defaultsTrue() {
        let env = EnvironmentValues()
        #expect(env.isEnabled == true)
    }

    @Test(".disabled() with no argument disables the subtree")
    func disabledDefaultArg() {
        var env = EnvironmentValues()
        env.isEnabled = true
        let modifier = DisabledModifier(disabled: true)
        modifier.apply(to: &env)
        #expect(env.isEnabled == false)
    }

    @Test(".disabled(false) re-enables when ancestor is enabled")
    func disabledFalseWhenAncestorEnabled() {
        var env = EnvironmentValues()
        env.isEnabled = true
        DisabledModifier(disabled: false).apply(to: &env)
        #expect(env.isEnabled == true)
    }

    @Test("nested .disabled(false) does NOT re-enable a disabled ancestor (most-restrictive wins)")
    func mostRestrictiveWins() {
        var env = EnvironmentValues()
        env.isEnabled = true
        DisabledModifier(disabled: true).apply(to: &env)
        #expect(env.isEnabled == false, "outer disable must hold")
        DisabledModifier(disabled: false).apply(to: &env)
        #expect(env.isEnabled == false,
                "inner .disabled(false) must NOT undo an ancestor's .disabled(true) — SwiftUI parity")
    }
}

@Suite(".disabled() handler gating — onKeyPress/onClick must not fire under disabled subtree")
@MainActor
struct DisabledHandlerGatingTests {

    @Test("onKeyPress handler is NOT registered when env.isEnabled == false")
    func onKeyPressGatedOut() {
        let engine = FocusEngine()
        let nodeID = NodeID(path: [.index(42)])
        var env = EnvironmentValues()
        env.isEnabled = false
        let modifier = OnKeyPressModifier(handler: { _ in .handled })
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(env) {
                FocusGraphIntegration.registerIfNeeded(modifier: modifier, nodeID: nodeID)
            }
        }
        #expect(engine.keyHandlers[nodeID] == nil,
                "disabled subtree must not register key handler — found one in keyHandlers map")
    }

    @Test("onClick handler is NOT registered when env.isEnabled == false")
    func onClickGatedOut() {
        let engine = FocusEngine()
        let nodeID = NodeID(path: [.index(42)])
        var env = EnvironmentValues()
        env.isEnabled = false
        let modifier = OnClickModifier(handler: { _, _ in })
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(env) {
                FocusGraphIntegration.registerIfNeeded(modifier: modifier, nodeID: nodeID)
            }
        }
        #expect(engine.clickHandlers[nodeID] == nil,
                "disabled subtree must not register click handler — found one in clickHandlers map")
    }

    @Test("handlers DO register when env.isEnabled == true (control case)")
    func enabledStillRegisters() {
        let engine = FocusEngine()
        let nodeID = NodeID(path: [.index(42)])
        var env = EnvironmentValues()
        env.isEnabled = true
        let modifier = OnKeyPressModifier(handler: { _ in .handled })
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(env) {
                FocusGraphIntegration.registerIfNeeded(modifier: modifier, nodeID: nodeID)
            }
        }
        #expect(engine.keyHandlers[nodeID] != nil,
                "enabled control case should register — registration regression?")
    }
}

@Suite(".disabled() focus skip — disabled focusables drop out of Tab order")
@MainActor
struct DisabledFocusSkipTests {

    @Test("focusable in disabled subtree is excluded from focusableList")
    func focusableSkippedWhenDisabled() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b") })
        let root = graph.root!
        // Mark both focusable. The FIRST is in a disabled subtree (env.isEnabled
        // false on the node itself); the SECOND is not.
        root.children[0].isFocusable = true
        root.children[0]._resolvedEnv = {
            var env = EnvironmentValues()
            env.isEnabled = false
            return env
        }()
        root.children[1].isFocusable = true
        root.children[1]._resolvedEnv = EnvironmentValues()  // default isEnabled=true

        let engine = FocusEngine()
        engine.rebuildIndex(root: root)

        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[1].id,
                "Tab must skip disabled focusable; got \(String(describing: engine.keyboardFocusID))")
    }

    @Test("Tab cycles only through enabled focusables")
    func tabCyclesEnabledOnly() {
        let graph = AttributeGraph()
        graph.update(from: VStack { Text("a"); Text("b"); Text("c") })
        let root = graph.root!
        for child in root.children { child.isFocusable = true }
        // Disable the middle one.
        root.children[1]._resolvedEnv = {
            var env = EnvironmentValues()
            env.isEnabled = false
            return env
        }()
        root.children[0]._resolvedEnv = EnvironmentValues()
        root.children[2]._resolvedEnv = EnvironmentValues()

        let engine = FocusEngine()
        engine.rebuildIndex(root: root)

        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[0].id)
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[2].id,
                "must skip disabled middle node — got \(String(describing: engine.keyboardFocusID))")
        engine.focusNext()
        #expect(engine.keyboardFocusID == root.children[0].id, "wrap back to first enabled")
    }
}

@Suite(".disabled() public API — extension method exists and constructs the modifier")
@MainActor
struct DisabledPublicAPITests {

    @Test(".disabled() with no args defaults to disabled=true")
    func defaultArgIsTrue() {
        let view = Text("x").disabled()
        #expect(view.modifier.disabled == true)
    }

    @Test(".disabled(false) constructs disabled=false (re-enable opportunity)")
    func explicitFalse() {
        let view = Text("x").disabled(false)
        #expect(view.modifier.disabled == false)
    }

    @Test(".disabled(true) constructs disabled=true")
    func explicitTrue() {
        let view = Text("x").disabled(true)
        #expect(view.modifier.disabled == true)
    }
}
