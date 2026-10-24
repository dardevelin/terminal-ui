import Testing
@testable import TerminalUI

// A click on a text field focused it and left the caret where it was: to
// fix a word in the middle the reader had to arrow there. A click now puts
// the caret on the character it lands on, as in every editor — mapped
// through what was drawn: the gutter, wrapped rows, a scrolled view, the
// caret's own cell, wide characters and collapsed pastes.

@MainActor
private final class Screen<V: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let view: () -> V
    let width: Int
    let height: Int

    init(width: Int = 30, height: Int = 6, _ view: @escaping () -> V) {
        self.view = view
        self.width = width
        self.height = height
        frame()
    }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        // Focus reaches the views through the environment, as the runtime
        // binds it each frame: a focused field draws its caret.
        var environment = EnvironmentValues()
        environment.focusedID = engine.keyboardFocusID
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentEnvironment.withValue(environment) {
            GraphContext.$currentFocusEngine.withValue(engine) {
                graph.focusMoved(to: engine.keyboardFocusID)
                graph.update(from: view())
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)
        return (0..<height).map { y in (0..<width).map { String(buffer[$0, y].character) }.joined() }
    }

    func click(_ x: Int, _ y: Int) {
        engine.handleMouseClick(x: x, y: y, root: graph.root)
        frame()
    }

    func type(_ character: Character) {
        _ = engine.routeKeyEvent(KeyEvent(key: .character(character)), root: graph.root)
        frame()
    }
}

@MainActor
private final class Model {
    var text: String
    var area = TextAreaState()
    var prompt = PromptInputState()
    init(_ text: String) { self.text = text }
    var textBinding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    var areaBinding: Binding<TextAreaState> { Binding(get: { self.area }, set: { self.area = $0 }) }
    var promptBinding: Binding<PromptInputState> { Binding(get: { self.prompt }, set: { self.prompt = $0 }) }
}

@Suite("A click places the caret in a TextArea")
@MainActor
struct TextAreaCaretClickTests {

    @Test func aClickPutsTheCaretOnTheCharacterUnderIt() {
        let model = Model("first\nsecond line\nthird")
        let screen = Screen { TextArea(text: model.textBinding, state: model.areaBinding) }
        screen.click(3, 1)
        #expect(model.area.cursor == TextAreaCursor(row: 1, col: 3))
        screen.type("X")
        #expect(model.text == "first\nsecXond line\nthird")
    }

    @Test func pastALinesEndIsItsEndAndBelowTheTextIsTheTextsEnd() {
        let model = Model("first\nsecond line\nthird")
        let screen = Screen { TextArea(text: model.textBinding, state: model.areaBinding) }
        screen.click(20, 0)
        #expect(model.area.cursor == TextAreaCursor(row: 0, col: 5))
        screen.click(2, 5)
        #expect(model.area.cursor == TextAreaCursor(row: 2, col: 5))
    }

    @Test func theGutterIsNoText() {
        let model = Model("first\nsecond")
        let screen = Screen { TextArea(text: model.textBinding, state: model.areaBinding, lineNumbers: true) }
        let row = screen.frame()[1]
        let textStart = row.distance(from: row.startIndex, to: row.range(of: "second")!.lowerBound)
        screen.click(textStart + 2, 1)
        #expect(model.area.cursor == TextAreaCursor(row: 1, col: 2))
        screen.click(0, 1)
        #expect(model.area.cursor == TextAreaCursor(row: 1, col: 0))
    }

    @Test func aWrappedLinesSecondRowIsItsContinuation() {
        let model = Model("alpha beta gamma delta")
        let screen = Screen(width: 12) { TextArea(text: model.textBinding, state: model.areaBinding) }
        let rows = screen.frame()
        let y = rows.firstIndex { $0.hasPrefix("gamma") }!
        screen.click(1, y)
        let line = model.text
        let col = line.distance(from: line.startIndex, to: line.range(of: "gamma")!.lowerBound) + 1
        #expect(model.area.cursor == TextAreaCursor(row: 0, col: col))
    }

    @Test func aWrappedLinesContinuationLinesUpUnderTheNumberedRow() {
        let model = Model("alpha beta gamma delta")
        let screen = Screen(width: 18) { TextArea(text: model.textBinding, state: model.areaBinding, lineNumbers: true) }
        let rows = screen.frame()
        let start = rows[0].distance(from: rows[0].startIndex, to: rows[0].range(of: "alpha")!.lowerBound)
        let next = rows[1].firstIndex { $0 != " " }.map { rows[1].distance(from: rows[1].startIndex, to: $0) }
        #expect(next == start, "continuation text starts under the first row's:\n\(rows.joined(separator: "\n"))")
    }

    @Test func aScrolledViewsFirstRowIsTheLineScrolledTo() {
        let model = Model((0..<10).map { "line \($0)" }.joined(separator: "\n"))
        model.area.scrollOffset = 4
        model.area.cursor = TextAreaCursor(row: 5, col: 0)
        let screen = Screen(height: 3) { TextArea(text: model.textBinding, state: model.areaBinding, visibleHeight: 3) }
        let first = screen.frame()[0]
        screen.click(5, 0)
        #expect(model.area.cursor.col == 5)
        #expect(first.hasPrefix("line \(model.area.cursor.row)"))
    }

    @Test func aClickDropsTheSelection() {
        let model = Model("first\nsecond")
        model.area.selection = TextAreaSelection(start: TextAreaCursor(row: 0, col: 0),
                                                 end: TextAreaCursor(row: 1, col: 2))
        let screen = Screen { TextArea(text: model.textBinding, state: model.areaBinding) }
        screen.click(1, 0)
        #expect(model.area.selection == nil)
    }
}

@Suite("A click places the cursor in a TextInput")
@MainActor
struct TextInputCaretClickTests {

    @Test func aClickOnAnUnfocusedFieldPutsTheCursorThere() {
        let model = Model("hello")
        let screen = Screen { TextInput(text: model.textBinding) }
        screen.click(2, 0)
        screen.type("X")
        #expect(model.text == "heXllo")
    }

    @Test func aClickOnAFocusedFieldSkipsTheCaretsCell() {
        let model = Model("hello")
        let screen = Screen { TextInput(text: model.textBinding) }
        screen.click(5, 0)  // focuses, cursor at the end, the caret drawn there
        screen.click(1, 0)
        screen.type("X")
        #expect(model.text == "hXello")
        // The caret now sits after "hX": a click on the "e" past it.
        let row = screen.frame()[0]
        let e = row.distance(from: row.startIndex, to: row.firstIndex(of: "e")!)
        screen.click(e, 0)
        screen.type("Y")
        #expect(model.text == "hXYello")
    }

    @Test func thePromptIsNoValue() {
        let model = Model("hello")
        let screen = Screen { TextInput("Name: ", text: model.textBinding) }
        screen.click(8, 0)
        screen.type("X")
        #expect(model.text == "heXllo")
        screen.click(1, 0)
        screen.type("Y")
        #expect(model.text == "YheXllo")
    }

    @Test func aWideCharacterIsOneCharacterOfTwoCells() {
        let model = Model("日本語")
        let screen = Screen { TextInput(text: model.textBinding) }
        screen.click(3, 0)  // the right half of 本
        screen.type("X")
        #expect(model.text == "日X本語")
    }
}

@Suite("A click places the cursor in a PromptInput")
@MainActor
struct PromptInputCaretClickTests {

    @Test func aClickPutsTheCursorOnTheCharacterUnderIt() {
        let model = Model("first line\nsecond")
        let screen = Screen { PromptInput(text: model.textBinding, state: model.promptBinding) }
        screen.click(2 + 3, 1)
        #expect(model.prompt.cursorRow == 1 && model.prompt.cursorCol == 3)
        screen.click(2 + 25, 0)
        #expect(model.prompt.cursorRow == 0 && model.prompt.cursorCol == 10, "past the end, the end")
    }

    @Test func aClickInsideACollapsedPasteLandsOnItsNearerEdge() {
        let model = Model("")
        let pasted = (1...20).map { "pasted line \($0)" }.joined(separator: "\n")
        PromptInput.handlePaste(pasted, text: model.textBinding, state: model.promptBinding,
                                maxVisibleLines: 8, wrapWidth: 60)
        model.text += " tail"
        let screen = Screen(width: 80) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        let row = screen.frame()[0]
        let marker = row.range(of: "[Pasted text")!
        let start = row.distance(from: row.startIndex, to: marker.lowerBound)
        screen.click(start + 2, 0)
        #expect(model.prompt.cursorRow == 0 && model.prompt.cursorCol == 0, "inside, near its start")
        let tail = row.distance(from: row.startIndex, to: row.range(of: "tail")!.lowerBound)
        screen.click(tail + 1, 0)
        let lines = model.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(model.prompt.cursorRow == lines.count - 1)
        #expect(model.prompt.cursorCol == lines.last!.count - 3, "after the marker, in the expanded text")
    }
}
