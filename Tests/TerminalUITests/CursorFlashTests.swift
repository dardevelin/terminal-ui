import Observation
import Synchronization
import Testing
@testable import TerminalUI

// `.bounce` is the default boundary feedback, and it drew nothing: the hook it
// called was empty unless an app filled it. A wall hit now lights the focused
// cursor in the theme's warning colour for a moment, as a refusal — quiet,
// and the same over SSH as at a desk.

/// Counts the changes `withObservationTracking` reports for `flash.isLit`.
private final class ChangeCounter: Sendable {
    private let count = Mutex(0)
    var changes: Int { count.withLock { $0 } }

    func track(_ flash: CursorFlash) {
        withObservationTracking {
            _ = flash.isLit
        } onChange: { [self] in
            count.withLock { $0 += 1 }
            track(flash)
        }
    }
}

@Suite("CursorFlash — a wall hit lights the cursor for a moment")
struct CursorFlashTests {

    @Test("Lit at a hit, dark again after its duration")
    func lightsThenGoesDark() async {
        let flash = CursorFlash(duration: .milliseconds(30))
        #expect(!flash.isLit)
        flash.light()
        #expect(flash.isLit)
        let dark = await finishes(within: .seconds(2)) {
            while flash.isLit { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(dark)
    }

    @Test("A view reading it is told when it lights and when it goes dark")
    func observed() async {
        let flash = CursorFlash(duration: .milliseconds(30))
        let counter = ChangeCounter()
        counter.track(flash)
        flash.light()
        let both = await finishes(within: .seconds(2)) {
            while counter.changes < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(both)
    }

    @Test("Hits in a row keep it lit until the last one's moment is over")
    func hitsInARow() {
        let flash = CursorFlash(duration: .seconds(60))
        flash.light()
        flash.light()
        flash.putOut(after: 1)
        #expect(flash.isLit, "the first hit's timer does not put out the second's")
        flash.putOut(after: 2)
        #expect(!flash.isLit)
    }

    @Test("A hit while lit tells no one: nothing they draw changes")
    func hitWhileLitIsQuiet() async {
        let flash = CursorFlash(duration: .seconds(60))
        let counter = ChangeCounter()
        counter.track(flash)
        flash.light()
        flash.light()
        flash.light()
        #expect(counter.changes == 1)
    }
}

@Suite("Boundary feedback — .bounce flashes the cursor")
struct BounceFeedbackTests {

    @Test(".bounce lights the environment's cursor flash, and still calls an app's bounce hook")
    func bounceLightsTheCursor() {
        let flash = CursorFlash(duration: .seconds(10))
        let hooked = Mutex(0)
        let action = BoundaryHitAction(mode: .bounce, callback: nil, bell: BellAction {},
                                       bounce: { _ in hooked.withLock { $0 += 1 } }, flash: flash)
        action(.leftEdge)
        #expect(flash.isLit)
        #expect(hooked.withLock { $0 } == 1)
    }

    @Test("Other modes leave the cursor alone")
    func otherModesDoNotFlash() {
        let flash = CursorFlash(duration: .seconds(10))
        for mode in [BoundaryFeedback.bell, .modal, .none] {
            BoundaryHitAction(mode: mode, callback: nil, bell: BellAction {}, flash: flash)(.leftEdge)
        }
        #expect(!flash.isLit)
    }

    @Test("A lit cursor takes the theme's warning colour, in every input")
    func litCursorColour() {
        let theme = DefaultTheme()
        let field = TextInputRow.visibleSpans([TextSpan("ab"), TextSpan("│")], caret: 1, isFocused: true,
                                              litColor: theme.cursorColor(lit: true))
        #expect(field[1].foreground == theme.warning)

        let editor = TextArea.buildDisplaySpans(lines: ["ab"], cursor: TextAreaCursor(row: 0, col: 1),
                                                selection: nil, scrollOffset: 0, visibleHeight: 1,
                                                lineNumbers: false, showsCursor: true, cursorLit: true,
                                                chrome: theme)
        #expect(editor.contains { $0.background == theme.warning })
    }
}
