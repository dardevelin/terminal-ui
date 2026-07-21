import Foundation
import Testing
@testable import TerminalUI

#if DEBUG

// SwiftUI ships runtime warnings for "knowable bug" composition (e.g.
// .searchable outside NavigationSplitView) — surfaced via os_log,
// reachable from Console.app even when no inspector is attached.
//
// Our equivalent is a structured DebugEvent.frameworkWarning routed
// through DebugStream so the F2 panel, remote socket, and file sinks
// all see it. Each warning carries a stable FrameworkWarningCode so
// users can suppress per-app or grep CI logs deterministically.
//
// Per /swift-dev SW-PROTOCOL-DESIGN: business rules belong in runtime
// checks, not phantom types. .onHover composes orthogonally with all
// MouseFocusPolicy cases; the only suspicious pairing is .hoverFollows
// — framework already moves keyboard focus on hover, so a duplicate
// .onHover almost always means the user wants .disabled instead.

/// Counts FrameworkWarning events received, indexed by code. Stand-in
/// for a test inspection sink — receives nothing else. Lock matches
/// MemoryDebugSink's pattern: sinks aren't @MainActor since DebugStream
/// itself is `@unchecked Sendable`.
private final class WarningProbe: DebugSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _counts: [FrameworkWarningCode: Int] = [:]

    func receive(_ event: DebugEvent) {
        guard case .frameworkWarning(let info) = event else { return }
        lock.lock()
        _counts[info.code, default: 0] += 1
        lock.unlock()
    }

    func count(of code: FrameworkWarningCode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _counts[code, default: 0]
    }
}

@MainActor
private func withProbe(_ body: (WarningProbe) -> Void) {
    let probe = WarningProbe()
    DebugStream.shared.addSink(probe)
    DebugStream.shared.unsuppressAllWarnings()  // reset filter state
    DebugStream.shared.resetWarningDedup()       // clear per-session dedupe so prior tests don't suppress new emits
    defer {
        DebugStream.shared.removeAllSinks()
        DebugStream.shared.unsuppressAllWarnings()
        DebugStream.shared.resetWarningDedup()
    }
    body(probe)
}

@Suite("DebugStream — framework warnings")
@MainActor
struct DebugStreamWarningTests {

    @Test(".onHover alone (no policy modifier) emits no warning")
    func noWarningForBareOnHover() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x").onHover { _ in })
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 0)
        }
    }

    @Test(".onHover under .clickToLock (default) emits no warning")
    func noWarningUnderClickToLock() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x")
                    .onHover { _ in }
                    .mouseFocusPolicy(.clickToLock))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 0)
        }
    }

    @Test(".onHover under .clickOnly emits no warning")
    func noWarningUnderClickOnly() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x")
                    .onHover { _ in }
                    .mouseFocusPolicy(.clickOnly))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 0)
        }
    }

    @Test(".onHover under .disabled (the legitimate combo) emits no warning")
    func noWarningUnderDisabled() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x")
                    .onHover { _ in }
                    .mouseFocusPolicy(.disabled))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 0,
                    ".disabled + .onHover is the SwiftUI escape hatch — must NEVER warn")
        }
    }

    @Test(".onHover under .hoverFollows emits exactly one warning")
    func oneWarningUnderHoverFollows() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x")
                    .onHover { _ in }
                    .mouseFocusPolicy(.hoverFollows))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 1)
        }
    }

    @Test("two .onHover-under-.hoverFollows nodes warn per node")
    func warnsPerNode() {
        withProbe { probe in
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: VStack {
                    Text("a").onHover { _ in }
                    Text("b").onHover { _ in }
                }.mouseFocusPolicy(.hoverFollows))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 2)
        }
    }

    @Test("suppressed warning code emits nothing")
    func suppressionSilencesWarning() {
        withProbe { probe in
            DebugStream.shared.suppressWarning(.onHoverWithHoverFollows)
            let engine = FocusEngine()
            let graph = AttributeGraph()
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.update(from: Text("x")
                    .onHover { _ in }
                    .mouseFocusPolicy(.hoverFollows))
            }
            #expect(probe.count(of: .onHoverWithHoverFollows) == 0)
        }
    }
}

#endif

// An Option/Alt-modified binding is unreachable on a terminal that composes
// Option into a character — stock Apple Terminal turns Option+R into "®" and
// the binding simply never fires. No escape query reports that setting, so the
// framework warns rather than guessing, and says how to fix it.

@Suite("Option-as-Meta binding warning", .serialized)
@MainActor
struct OptionAsMetaWarningTests {

    private struct Row: Identifiable { let id: Int }

    private func altScope() -> ActionScope {
        ActionScope(boundActions: [
            Action(id: "test.action", title: .literal("Test")) {}
                .bound(to: .keyboard(.character("r"), [.alt]))
        ])
    }

    @Test("an unconfirmed terminal warns about an Option binding")
    func unknownStateWarns() {
        #expect(ActionsModifier.optionMetaWarning(for: altScope(), state: .unknown) != nil)
    }

    @Test("a confirmed terminal says nothing")
    func confirmedStateIsSilent() {
        // The gate, not just the chord search — kitty and Linux deliver Option
        // as Meta, so there is nothing to tell the developer.
        #expect(ActionsModifier.optionMetaWarning(for: altScope(), state: .confirmed) == nil)
    }

    @Test("a binding without Option is never flagged")
    func nonOptionBindingIsIgnored() {
        // Ctrl chords reach every terminal without configuration, which is why
        // the Storybook demo uses one.
        let scope = ActionScope(boundActions: [
            Action(id: "c", title: .literal("C")) {}
                .bound(to: .keyboard(.character("r"), [.ctrl]))
        ])
        #expect(ActionsModifier.optionMetaWarning(for: scope, state: .unknown) == nil)
    }

    @Test("the message names the chord and how to fix it")
    func messageIsActionable() {
        let message = ActionsModifier.optionMetaWarning(for: altScope(), state: .unknown)
        #expect(message?.contains("Terminal.app") == true)
        #expect(message?.contains("suppressWarning") == true)
    }

    @Test("a graph that keeps adding Option bindings still warns once")
    func churningGraphWarnsOnce() {
        // The hook runs on every update and the dedupe key includes the node
        // path, so keying the warning to a node emitted a fresh copy for every
        // row a growing ForEach introduced — 20 updates produced 20 warnings.
        // This is a property of the terminal, not of any node.
        withProbe { probe in
            let graph = AttributeGraph()
            for count in 1...20 {
                graph.update(from: VStack {
                    ForEach((0..<count).map(Row.init)) { row in
                        Text("row \(row.id)").actions {
                            Action(id: ActionID("a\(row.id)"), title: .literal("A")) {}
                                .bound(to: .keyboard(.character("r"), [.alt]))
                        }
                    }
                })
            }
            // Silent on a terminal that confirmed the capability; otherwise
            // exactly one regardless of how the tree churned.
            let expected = Runtime.capabilities.optionAsMetaConfigured == .confirmed ? 0 : 1
            #expect(probe.count(of: .optionAsMetaUnconfirmed) == expected)
        }
    }

    @Test("the warning can be suppressed through the general mechanism")
    func warningIsSuppressible() {
        withProbe { probe in
            DebugStream.shared.suppressWarning(.optionAsMetaUnconfirmed)
            let graph = AttributeGraph()
            graph.update(from: Text("x").actions {
                Action(id: "s", title: .literal("S")) {}
                    .bound(to: .keyboard(.character("r"), [.alt]))
            })
            #expect(probe.count(of: .optionAsMetaUnconfirmed) == 0)
        }
    }
}
