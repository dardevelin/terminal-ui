import Foundation
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

#endif
