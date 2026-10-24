import Testing
@testable import TerminalUI

// A click knew only where it landed: not the button, not how many came in a
// row, not the modifiers held, so a view could not tell a double click from
// two clicks or a Ctrl+click from a click. Presses now carry all three, and
// `TapGesture` waits for the one it describes, as SwiftUI's does.

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()

    init(_ view: some TerminalView) {
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view) }
        var buffer = CellBuffer(width: 20, height: 4)
        let rect = Rect(x: 0, y: 0, width: 20, height: 4)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: graph.root!)
    }

    func press(_ x: Int, _ y: Int, button: MouseButton = .left, count: Int = 1,
               modifiers: KeyModifiers = []) {
        engine.handlePress(PointerPress(x: x, y: y, button: button, count: count, modifiers: modifiers),
                           root: graph.root)
    }
}

@MainActor
private final class Log {
    var entries: [String] = []
    func record(_ entry: String) -> () -> Void { { [self] in entries.append(entry) } }
}

@Suite("A tap waits for the click it describes")
@MainActor
struct TapGestureTests {

    @Test func aSingleTapTakesEveryClick() {
        let log = Log()
        let screen = Screen(Text("file").onTapGesture(perform: log.record("tap")))
        screen.press(1, 0)
        screen.press(1, 0, count: 2)
        screen.press(1, 0, count: 3)
        #expect(log.entries == ["tap", "tap", "tap"])
    }

    @Test func aDoubleTapTakesTheSecondClickAndLeavesTheFirstToTheTapAfterIt() {
        let log = Log()
        let screen = Screen(Text("file")
            .onTapGesture(count: 2, perform: log.record("open"))
            .onTapGesture(perform: log.record("select")))
        screen.press(1, 0)
        screen.press(1, 0, count: 2)
        #expect(log.entries == ["select", "open"])
    }

    @Test func aTripleClickIsNoDoubleClick() {
        let log = Log()
        let screen = Screen(Text("file").onTapGesture(count: 2, perform: log.record("open")))
        screen.press(1, 0, count: 3)
        #expect(log.entries.isEmpty)
    }

    @Test func aTapWithModifiersTakesOnlyClicksWithExactlyThose() {
        let log = Log()
        let screen = Screen(Text("file")
            .gesture(TapGesture().modifiers(.ctrl).onEnded(log.record("add")))
            .onTapGesture(perform: log.record("select")))
        screen.press(1, 0, modifiers: .ctrl)
        screen.press(1, 0)
        screen.press(1, 0, modifiers: [.ctrl, .alt])
        #expect(log.entries == ["add", "select", "select"])
    }

    @Test func onClickStillTakesEveryLeftClick() {
        let log = Log()
        let screen = Screen(Text("row").onClick { _, _ in log.entries.append("click") })
        screen.press(1, 0, count: 2, modifiers: .ctrl)
        screen.press(1, 0, button: .right)
        #expect(log.entries == ["click"])
    }

    @Test func anotherButtonReachesNoTap() {
        let log = Log()
        let screen = Screen(Text("file").onTapGesture(perform: log.record("tap")))
        screen.press(1, 0, button: .right)
        screen.press(1, 0, button: .middle)
        #expect(log.entries.isEmpty)
    }

    @Test func aDisabledViewTakesNoTap() {
        let log = Log()
        let screen = Screen(Text("file").onTapGesture(perform: log.record("tap")).disabled())
        screen.press(1, 0)
        #expect(log.entries.isEmpty)
    }

    @Test func aTapOnAFocusableViewFocusesItAndTaps() {
        let log = Log()
        let screen = Screen(VStack {
            Text("other").focusable()
            Text("file").focusable().onTapGesture(perform: log.record("tap"))
        })
        screen.press(1, 1)
        #expect(log.entries == ["tap"])
        #expect(screen.engine.keyboardFocusID != nil)
    }
}

// A handler is stamped on its node so a cached update can put it back, and
// `rebuildIndex` put it back every frame — after the view was disabled too,
// so a control disabled once it had been drawn still took clicks.
@Suite("A view disabled after it was drawn takes nothing")
@MainActor
struct DisabledLaterTests {
    @Test func aViewDisabledLaterTakesNoClickNorTap() {
        let log = Log()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        func view(_ enabled: Bool) -> some TerminalView {
            Text("file")
                .onTapGesture(count: 2, perform: log.record("open"))
                .onClick { _, _ in log.entries.append("click") }
                .disabled(!enabled)
        }
        func frame(_ enabled: Bool) {
            engine.clearHandlers()
            GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view(enabled)) }
            Layout.measureAndPlace(graph: graph.root!, in: Rect(x: 0, y: 0, width: 20, height: 4))
            engine.rebuildIndex(root: graph.root!)
        }
        frame(true)
        engine.handlePress(PointerPress(x: 1, y: 0), root: graph.root)
        engine.handlePress(PointerPress(x: 1, y: 0, count: 2), root: graph.root)
        #expect(log.entries == ["click", "open"])
        frame(false)
        engine.handlePress(PointerPress(x: 1, y: 0), root: graph.root)
        engine.handlePress(PointerPress(x: 1, y: 0, count: 2), root: graph.root)
        #expect(log.entries == ["click", "open"])
    }
}

@Suite("Presses count into clicks")
struct ClickCounterTests {
    let start = ContinuousClock.now

    @Test func aSecondPressSoonOnTheSameCellIsADoubleClick() {
        var counter = ClickCounter()
        #expect(counter.count(.left, x: 3, y: 1, at: start) == 1)
        #expect(counter.count(.left, x: 3, y: 1, at: start + .milliseconds(200)) == 2)
        #expect(counter.count(.left, x: 3, y: 1, at: start + .milliseconds(400)) == 3)
    }

    @Test func aPressAfterTheIntervalStartsAgain() {
        var counter = ClickCounter()
        _ = counter.count(.left, x: 3, y: 1, at: start)
        #expect(counter.count(.left, x: 3, y: 1, at: start + .milliseconds(501)) == 1)
    }

    @Test func anotherCellOrButtonStartsAgain() {
        var counter = ClickCounter()
        _ = counter.count(.left, x: 3, y: 1, at: start)
        #expect(counter.count(.left, x: 4, y: 1, at: start + .milliseconds(100)) == 1)
        #expect(counter.count(.right, x: 4, y: 1, at: start + .milliseconds(200)) == 1)
    }
}
