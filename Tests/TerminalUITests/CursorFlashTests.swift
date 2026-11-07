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

/// Reads the flash, then takes three of its durations to finish: long enough
/// for a timer started before the body to fire while it runs, after the read
/// and before `withObservationTracking` has installed what it observes.
private struct SlowFlashReader: TerminalView {
    let flash: CursorFlash
    let busyFor: Duration

    var body: some TerminalView {
        let lit = flash.isLit
        let until = ContinuousClock.now + busyFor
        while ContinuousClock.now < until {}
        return Text(lit ? "lit" : "dark")
    }
}

@MainActor
private func firstLine(of graph: AttributeGraph) -> String {
    let width = 10
    var buffer = CellBuffer(width: width, height: 1)
    guard let root = graph.root else { return "" }
    let rect = Rect(x: 0, y: 0, width: width, height: 1)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    return (0..<width).map { String(buffer[$0, 0].character) }.joined()
        .trimmingCharacters(in: .whitespaces)
}

// The tests wait on the task that ends a flash, never on the clock: it runs
// on the main actor, which a sanitized run of the whole suite keeps busy for
// seconds at a time.

@Suite("CursorFlash — a wall hit lights the cursor for a moment")
@MainActor
struct CursorFlashTests {

    @Test("Lit at a hit, dark again its duration after the frame that draws it")
    func lightsThenGoesDark() async {
        let flash = CursorFlash(duration: .milliseconds(30))
        #expect(!flash.isLit)
        flash.light()
        #expect(flash.isLit)
        await flash.frameDrawn()?.value
        #expect(!flash.isLit)
    }

    @Test("No frame drawn, no flash seen: it stays lit past its duration")
    func waitsForAFrame() async {
        let duration = Duration.milliseconds(20)
        let flash = CursorFlash(duration: duration)
        flash.light()
        try? await Task.sleep(for: duration * 5)
        #expect(flash.isLit, "a flash that went out before any frame drew it was never seen")
        let drawn = ContinuousClock.now
        await flash.frameDrawn()?.value
        #expect(!flash.isLit)
        #expect(ContinuousClock.now - drawn >= duration, "the moment is timed from the frame")
    }

    @Test("Frames drawn while it is lit do not hold it lit")
    func laterFramesDoNotRestartIt() async {
        let flash = CursorFlash(duration: .milliseconds(30))
        flash.light()
        let ending = flash.frameDrawn()
        #expect(ending != nil)
        #expect(flash.frameDrawn() == nil, "an app that draws every frame must still see the flash end")
        await ending?.value
        #expect(!flash.isLit)
        #expect(flash.frameDrawn() == nil, "a frame drawn dark starts nothing")
    }

    @Test("A hit while lit is timed from the frame that follows it")
    func aLaterHitOutlastsAnEarlierTimer() async {
        let flash = CursorFlash(duration: .milliseconds(20))
        flash.light()
        let first = flash.frameDrawn()
        flash.light()
        await first?.value
        #expect(flash.isLit, "the first hit's timer does not put out the second's")
        await flash.frameDrawn()?.value
        #expect(!flash.isLit)
    }

    @Test("A body that reads it as the flash ends is run again")
    func endingWhileABodyReadsIt() async throws {
        let duration = Duration.milliseconds(20)
        let flash = CursorFlash(duration: duration)
        flash.light()
        let ending = flash.frameDrawn()
        let graph = AttributeGraph()
        graph.update(from: SlowFlashReader(flash: flash, busyFor: duration * 3))
        #expect(firstLine(of: graph) == "lit")
        await ending?.value
        #expect(graph.hasDirtyNodes, "the flash went out while the body ran, and the body was never told")
        graph.drain()
        #expect(firstLine(of: graph) == "dark")
    }

    @Test("A view reading it is told when it lights and when it goes dark")
    func observed() async {
        let flash = CursorFlash(duration: .milliseconds(30))
        let counter = ChangeCounter()
        counter.track(flash)
        flash.light()
        await flash.frameDrawn()?.value
        #expect(counter.changes == 2)
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
