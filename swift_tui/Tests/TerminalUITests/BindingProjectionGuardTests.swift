import Foundation
import Testing
@testable import TerminalUI

#if DEBUG

// Bindings-in-GeometryReader-closure anti-pattern guardrail.
//
// Every composite view in `Sources/TerminalUI/Views/` was audited
// 2026-04-26; only TreeView ever had this bug and it was fixed by
// projecting bindings outside the GR closure (commit 54f5723). The
// audit verdict left no production view to fix, but we still want a
// permanent guardrail so the framework loudly warns the next time
// someone projects `$foo` inside a deferred closure where
// `GraphContext.currentNode` is nil.
//
// The warning routes through `DebugStream.frameworkWarning` with
// stable code `.bindingProjectedWithoutNode`. Inspectors, the F2
// panel, and the remote-control socket all see it; users can
// suppress with `DebugStream.shared.suppressWarning(...)` if a
// false-positive case ever shows up.

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

private final class GuardProbe: DebugSink, @unchecked Sendable {
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
private func withProbe(_ body: (GuardProbe) -> Void) {
    let probe = GuardProbe()
    DebugStream.shared.addSink(probe)
    DebugStream.shared.unsuppressAllWarnings()
    defer {
        DebugStream.shared.removeAllSinks()
        DebugStream.shared.unsuppressAllWarnings()
    }
    body(probe)
}

@Suite("State — bindingProjectedWithoutNode guardrail")
@MainActor
struct BindingProjectionGuardTests {

    @Test("projecting $state with no current node emits the warning")
    func emitsWhenCurrentNodeIsNil() {
        resetGraphContext()
        withProbe { probe in
            // Simulate the bug: a `@TerminalState` whose projectedValue
            // is read while `GraphContext.currentNode` is nil. The
            // returned binding silently swallows writes; the warning
            // is what tells the user that.
            let state = _GuardrailHarness()
            _ = state.$value  // triggers projectedValue read
            #expect(
                probe.count(of: .bindingProjectedWithoutNode) >= 1,
                "expected .bindingProjectedWithoutNode warning when projection happens with no current node"
            )
        }
    }

    @Test("projecting $state with a current node emits no warning")
    func noWarningWhenCurrentNodeSet() {
        resetGraphContext()
        let node = AttributeNode(id: .root, kind: .layout(LayoutInfo(kind: .vstack)))
        GraphContext.currentNode = node
        defer { GraphContext.currentNode = nil }
        withProbe { probe in
            let state = _GuardrailHarness()
            _ = state.$value
            #expect(
                probe.count(of: .bindingProjectedWithoutNode) == 0,
                "expected no warning when GraphContext.currentNode is set during projection"
            )
        }
    }
}

// Minimal struct that owns a @TerminalState — projecting `$value`
// triggers the projectedValue logic under test. Underscored to
// signal test-only fixture.
private struct _GuardrailHarness {
    @TerminalState var value: Int = 0
}

#endif
