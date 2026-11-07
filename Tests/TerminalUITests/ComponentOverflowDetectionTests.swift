import Foundation
import Synchronization
import Testing
@testable import TerminalUI

// Component boundary enforcement.
//
// The framework silently clips writes that would land outside a
// node's assigned rect — `CellBuffer.clipRect` drops out-of-bounds
// cells without a peep. That's the right shipped behaviour; what
// was missing is the warning so the bug is loud instead of silent.
//
// The user's complaint (verbatim, 2026-04-17):
// > "the framework should prevent this from happening, its a bug
// >  in component boundaries / when doing this in components we
// >  should be able to generate warning in components unless the
// >  user has marked the area of code to allow it, these are almost
// >  always going to be bugs"
//
// Contract pinned by these tests:
//   1. CellBuffer counts how many writes its clipRect rejects.
//   2. The render pipeline emits one `.componentOverflow` framework
//      warning per offending node per frame (NOT per dropped cell).
//   3. `.overflowOK()` modifier suppresses the warning on its subtree
//      — author opt-in for shadows, popovers, and other intentional
//      escapes.

#if DEBUG

@Suite("Overflow detection — counter on CellBuffer")
@MainActor
struct CellBufferOverflowCounterTests {

    @Test("clipRejectedWrites increments when subscript setter drops a cell")
    func subscriptDropsIncrement() {
        var buf = CellBuffer(width: 5, height: 5)
        buf.withClip(Rect(x: 0, y: 0, width: 2, height: 2)) { inner in
            // (3, 3) is inside the buffer but outside the 2x2 clip.
            inner[3, 3] = Cell(character: "x", style: .plain)
        }
        #expect(buf.clipRejectedWrites >= 1,
                "clip-dropped subscript write must increment counter; got \(buf.clipRejectedWrites)")
    }

    @Test("counter does NOT increment for in-bounds writes")
    func inBoundsNoIncrement() {
        var buf = CellBuffer(width: 5, height: 5)
        buf.withClip(Rect(x: 0, y: 0, width: 5, height: 5)) { inner in
            inner[1, 1] = Cell(character: "y", style: .plain)
        }
        #expect(buf.clipRejectedWrites == 0,
                "in-bounds write must not increment overflow counter; got \(buf.clipRejectedWrites)")
    }

    @Test("withClip records rejection delta for its scope")
    func withClipDeltaScope() {
        // The convenience that `withClip` exposes a delta lets the
        // renderer attribute overflow to the specific child without
        // tracking counters by hand.
        var buf = CellBuffer(width: 5, height: 5)
        let droppedInScope = buf.withClipMeasured(Rect(x: 0, y: 0, width: 2, height: 2)) { inner in
            inner[3, 3] = Cell(character: "x", style: .plain)
            inner[4, 4] = Cell(character: "y", style: .plain)
            return ()
        }
        #expect(droppedInScope >= 2,
                "withClipMeasured must report total drops in scope; got \(droppedInScope)")
    }
}

@Suite("Overflow detection — componentOverflow warning code")
@MainActor
struct ComponentOverflowWarningCodeTests {

    @Test(".componentOverflow case exists on FrameworkWarningCode")
    func caseExists() {
        let code = FrameworkWarningCode.componentOverflow
        #expect(code.rawValue == "componentOverflow")
    }

    @Test("componentOverflow can be suppressed independently of other warnings")
    func suppressionScope() {
        DebugStream.shared.unsuppressAllWarnings()
        DebugStream.shared.suppressWarning(.componentOverflow)
        #expect(DebugStream.shared.isWarningSuppressed(.componentOverflow))
        #expect(!DebugStream.shared.isWarningSuppressed(.onHoverWithHoverFollows),
                "suppression must be per-code, not global")
        DebugStream.shared.unsuppressAllWarnings()
    }
}

@Suite("Overflow detection — .overflowOK() modifier suppresses per-subtree")
@MainActor
struct OverflowOKModifierTests {

    @Test(".overflowOK() exists on TerminalView")
    func modifierExists() {
        // Pure compile-test — exercises the API surface.
        let view = Text("x").overflowOK()
        _ = view
    }

    @Test("env value `.overflowAllowed` is read by render")
    func envFlagDefault() {
        // Default is false (warn on overflow). Subtrees opt in via
        // `.overflowOK()` which sets the env to true; the renderer
        // reads it before deciding whether to emit the warning.
        let env = EnvironmentValues()
        let actual = env.overflowAllowed
        #expect(actual == false,
                "default env must NOT allow overflow (warning posture); got \(String(describing: actual))")
    }
}

/// Keeps every `componentOverflow` message, so a test can tell which node
/// reported and how many cells it counted.
private final class OverflowProbe: DebugSink, Sendable {
    let messages = Mutex<[String]>([])

    func receive(_ event: DebugEvent) {
        guard case .frameworkWarning(let info) = event, info.code == .componentOverflow else { return }
        messages.withLock { $0.append(info.message) }
    }
}

/// A report read back out of its message: the node's debug name and the
/// cells it said it dropped.
private struct OverflowReport: Equatable {
    let node: String
    let cells: Int

    init?(_ message: String) {
        let words = message.split(separator: " ")
        guard words.count > 3, words[0] == "node", words[2] == "wrote", let cells = Int(words[3]) else {
            return nil
        }
        node = String(words[1])
        self.cells = cells
    }
}

/// Lays out and draws `view` in a rect `rows` lines tall over a buffer
/// taller than it: a write past the buffer's own edge returns before the
/// clip is consulted and is never counted, so the room below the rect is
/// where a clipped write must land to be seen.
@MainActor
private func renderReporting(rows: Int, @TerminalViewBuilder _ view: () -> some TerminalView)
    -> (reports: [OverflowReport], counted: Int) {
    let probe = OverflowProbe()
    DebugStream.shared.addSink(probe)
    DebugStream.shared.unsuppressAllWarnings()
    DebugStream.shared.resetWarningDedup()
    defer {
        DebugStream.shared.removeAllSinks()
        DebugStream.shared.unsuppressAllWarnings()
        DebugStream.shared.resetWarningDedup()
    }
    let engine = FocusEngine()
    let graph = AttributeGraph()
    GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view()) }
    var buffer = CellBuffer(width: 20, height: 6)
    let rect = Rect(x: 0, y: 0, width: 20, height: rows)
    Layout.measureAndPlace(graph: graph.root!, in: rect)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    let reports = probe.messages.withLock { $0 }.compactMap(OverflowReport.init)
    return (reports, buffer.clipRejectedWrites)
}

/// Three lines, so in a one-line rect two of them are clipped.
@MainActor
private var tall: some TerminalView {
    VStack {
        Text("1")
        Text("2")
        Text("3")
    }
}

// A cell clipped while drawing a node counts for an enclosing node only when
// no node between them allows overflow. Each node took in the drops of its
// whole subtree, so a marked view's escape was reported by every view
// around it, the marker's own modifier node first.
@Suite("Overflow detection — .overflowOK() covers its subtree for every ancestor", .serialized)
@MainActor
struct OverflowOKAncestorTests {

    @Test func aMarkedViewEscapingItsParentWarnsNowhere() {
        let result = renderReporting(rows: 1) {
            HStack { tall.overflowOK() }
        }
        #expect(result.reports.isEmpty, "\(result.reports)")
        #expect(result.counted == 0, "the excused cells still counted on the buffer")
    }

    @Test func aMarkedViewEscapingAnEnclosingRectWarnsNowhere() {
        let result = renderReporting(rows: 2) {
            VStack {
                Text("top")
                tall.overflowOK()
            }
        }
        #expect(result.reports.isEmpty, "\(result.reports)")
        #expect(result.counted == 0)
    }

    @Test func anUnmarkedSiblingStillReportsItsOwnCells() {
        let result = renderReporting(rows: 1) {
            HStack {
                tall.overflowOK()
                tall
            }
        }
        let stacks = result.reports.filter { $0.node == "VStack" }
        #expect(stacks.count == 1, "only the unmarked stack overflowed: \(result.reports)")
        #expect(!result.reports.contains { $0.node == "environment" }, "\(result.reports)")
        let row = result.reports.filter { $0.node == "HStack" }
        #expect(row.count == 1 && row.first?.cells == stacks.first?.cells,
                "the HStack counts its unmarked child's cells and no more: \(result.reports)")
    }

    @Test func overflowReEnabledInsideAMarkedViewWarnsOnlyBelowTheMarker() {
        let result = renderReporting(rows: 1) {
            HStack {
                VStack {
                    tall.environment(\.overflowAllowed, false)
                }
                .overflowOK()
            }
        }
        #expect(result.reports.filter { $0.node == "VStack" }.count == 1,
                "the re-enabled stack reports, the marked one around it does not: \(result.reports)")
        #expect(!result.reports.contains { $0.node == "environment" || $0.node == "HStack" },
                "\(result.reports)")
        #expect(result.counted == 0, "the marker excuses what its re-enabled part reported")
    }
}

#endif
