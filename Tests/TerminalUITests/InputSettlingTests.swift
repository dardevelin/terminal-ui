import Observation
import Testing
@testable import TerminalUI

// The events between two frames are handled together, and the graph is
// updated when the frame is drawn. A key that closed a presentation left
// focus in it until then, so the key typed straight after was lost; the
// runtime now brings the graph up to date between two such keys. It did so
// before every key, from the root, and a burst of 108 characters into a
// wrapped prompt never finished under Thread Sanitizer. These count the
// updates: none for typing, one for a change that can move focus.

@Observable
private final class Model {
    var text = ""
    var showsHelp = false
}

/// A field that takes characters, in a body of its own that reads what it
/// shows: typing into it changes state a body read, as a real field does.
private struct Field: TerminalView {
    let model: Model
    var body: some TerminalView {
        Text("field: \(model.text)").focusable().onKeyPress { event in
            guard case .character(let character) = event.key else { return .ignored }
            model.text.append(character)
            return .handled
        }
    }
}

/// A modal whose `[ Close ]` closes it on Enter.
private struct Help: TerminalView {
    let model: Model
    var body: some TerminalView {
        Text("[ Close ]").focusable().onKeyPress { event in
            guard event.key == .enter else { return .ignored }
            model.showsHelp = false
            return .handled
        }
    }
}

/// The field and a modal, decided in a body.
private struct Screen: TerminalView {
    let model: Model
    var body: some TerminalView {
        VStack(spacing: 0) {
            Field(model: model)
            Text("beside").focusable()
        }
        .modal(isPresented: model.showsHelp) { Help(model: model) }
    }
}

/// A runtime's frames and keys without a terminal: each frame updates the
/// graph and re-reads focus, and each key is settled for, then routed.
@MainActor
private final class Keys<Content: TerminalView> {
    let graph = AttributeGraph()
    let engine = FocusEngine()
    let settling = InputSettling()
    let content: () -> Content

    init(_ content: @escaping () -> Content) {
        self.content = content
        frame()
    }

    func frame() {
        GraphContext.$currentFocusEngine.withValue(engine) {
            engine.clearHandlers()
            graph.update(from: settling.build(content))
            var buffer = CellBuffer(width: 30, height: 6)
            let rect = Rect(x: 0, y: 0, width: 30, height: 6)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            engine.reindex(graph.root!)
        }
    }

    /// Delivers `keys` as one batch, between two frames.
    func batch(_ keys: [Key]) {
        GraphContext.$currentFocusEngine.withValue(engine) {
            for key in keys {
                settling.settle(graph, for: engine, content: content)
                _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
            }
        }
    }

    /// Graph updates since the counters were last reset: root walks and
    /// drains that ran a body.
    var updates: Int { graph.rootWalkCount + graph.dirtyDrainCount }
}

@Suite("Keys between two frames")
@MainActor
struct InputSettlingTests {

    @Test func aBurstOfTypingCostsNoUpdate() {
        let model = Model()
        let keys = Keys { Screen(model: model) }
        keys.graph.resetFrameStats()
        let typed = String(repeating: "lorem ipsum ", count: 9)
        keys.batch(typed.map { Key.character($0) })
        #expect(model.text == typed)
        #expect(keys.updates == 0, "typing moves no focus, so it waits for the frame")
    }

    @Test func aKeyAfterAModalClosesReachesTheViewFocusReturnsTo() {
        let model = Model()
        let keys = Keys { Screen(model: model) }
        model.showsHelp = true
        keys.frame()
        keys.graph.resetFrameStats()
        keys.batch([.enter, .character("x"), .character("y")])
        #expect(!model.showsHelp)
        #expect(model.text == "xy", "the keys after Enter reach the field focus went back to")
        #expect(keys.graph.rootWalkCount == 0)
        #expect(keys.graph.dirtyDrainCount == 1, "one drain, for the close; none for the typing after it")
    }

    @Test func aModalTheRootDecidesIsSettledFromTheRootOncePerChange() {
        let model = Model()
        let keys = Keys {
            VStack(spacing: 0) {
                Field(model: model)
                Text("beside").focusable()
            }
            .modal(isPresented: model.showsHelp) { Help(model: model) }
        }
        model.showsHelp = true
        keys.frame()
        keys.graph.resetFrameStats()
        keys.batch([.enter, .character("x"), .character("y")])
        #expect(model.text == "xy")
        #expect(keys.graph.rootWalkCount == 1, "one root update, for the close")
    }
}
