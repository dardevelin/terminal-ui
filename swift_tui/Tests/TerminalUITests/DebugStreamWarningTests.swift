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
    defer {
        DebugStream.shared.removeAllSinks()
        DebugStream.shared.unsuppressAllWarnings()
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
