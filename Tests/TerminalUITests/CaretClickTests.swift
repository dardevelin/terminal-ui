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
    private(set) var buffer: CellBuffer

    init(width: Int = 30, height: Int = 6, _ view: @escaping () -> V) {
        self.view = view
        self.width = width
        self.height = height
        self.buffer = CellBuffer(width: width, height: height)
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
        self.buffer = buffer
        return (0..<height).map { y in (0..<width).map { String(buffer[$0, y].character) }.joined() }
    }

    func click(_ x: Int, _ y: Int) {
        engine.handleMouseClick(x: x, y: y, root: graph.root)
        frame()
    }

    func type(_ character: Character) {
        press(.character(character))
    }

    func press(_ key: Key) {
        _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
        frame()
    }

    /// The cell the caret is drawn in: the one on the caret's background, or
    /// the block drawn past the text's end.
    var caret: (x: Int, y: Int)? {
        let accent = DefaultTheme().accent
        let cells = (0..<height).lazy.flatMap { y in (0..<self.width).lazy.map { (x: $0, y: y) } }
        return cells.first { self.buffer[$0.x, $0.y].style.background == accent }
            ?? cells.first { "█▏".contains(self.buffer[$0.x, $0.y].character) }
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

// Word wrapping drops the spaces a line breaks at, and a wide glyph takes two
// columns. Each wrap moved a prompt's caret, its clicks and its paste markers
// one column, and a column over a wide glyph was counted as one character, so
// a click or Up and Down landed characters away from the column aimed at. The
// cell a character is drawn in, the caret, a click and Up and Down now read
// one projection of the text onto the screen.

extension Model {
    /// The character the text area's cursor is before.
    var areaCharacter: Character? {
        Self.character(in: text, row: area.cursor.row, col: area.cursor.col)
    }

    /// The character the prompt's cursor is before.
    var promptCharacter: Character? {
        Self.character(in: text, row: prompt.cursorRow, col: prompt.cursorCol)
    }

    private static func character(in text: String, row: Int, col: Int) -> Character? {
        let line = Array(TextLines.split(text)[row])
        return line.indices.contains(col) ? line[col] : nil
    }
}

/// Clicks every cell of `rows` a character is drawn in, from column
/// `textStart` on, and requires the caret to land on the character drawn
/// there: the cursor before it, and the caret drawn on its cell — the first
/// of a wide glyph's two, whichever half was clicked.
@MainActor
private func expectEveryCellPlacesTheCaret<V>(on screen: Screen<V>, rows: Range<Int>, from textStart: Int,
                                              characterAtCursor: () -> Character?) {
    let drawn = screen.buffer
    for y in rows {
        for x in textStart..<screen.width {
            let cell = drawn[x, y]
            guard cell.character != " " || cell.isContinuation else { continue }
            let glyph = cell.isContinuation ? x - 1 : x
            screen.click(x, y)
            #expect(characterAtCursor() == drawn[glyph, y].character, "a click at (\(x), \(y))")
            #expect(screen.caret.map { [$0.x, $0.y] } == [glyph, y], "the caret after a click at (\(x), \(y))")
        }
    }
}

@Suite("A TextArea's caret lands on the column it is aimed at")
@MainActor
struct TextAreaCaretColumnTests {

    @Test func aClickOnAWrappedRowLandsOnTheCharacterDrawnThere() {
        // The first wrap drops two spaces.
        let model = Model("alpha beta  gamma delta  epsilon")
        let screen = Screen(width: 10) { TextArea(text: model.textBinding, state: model.areaBinding) }
        expectEveryCellPlacesTheCaret(on: screen, rows: 0..<4, from: 0) { model.areaCharacter }
    }

    @Test func aClickOnEitherHalfOfAWideGlyphLandsOnIt() {
        let model = Model("中文 abc 日本語 かなカナ")
        let screen = Screen(width: 10) { TextArea(text: model.textBinding, state: model.areaBinding) }
        expectEveryCellPlacesTheCaret(on: screen, rows: 0..<3, from: 0) { model.areaCharacter }
        let row = screen.frame()[1]
        screen.click(row.distance(from: row.startIndex, to: row.firstIndex(of: "本")!) + 1, 1)
        screen.type("X")
        #expect(model.text == "中文 abc 日X本語 かなカナ")
    }

    @Test func upAndDownKeepTheColumnAcrossWideGlyphs() {
        let model = Model("abcdefgh\n日本語xy\nabcdefgh")
        for arrowMode in [TextAreaArrowMode.logical, .display] {
            model.area = TextAreaState()
            let screen = Screen(width: 20) {
                TextArea(text: model.textBinding, state: model.areaBinding, arrowMode: arrowMode)
            }
            screen.click(3, 0)
            screen.press(.down)
            #expect(model.area.cursor == TextAreaCursor(row: 1, col: 1), "column 3 is the right half of 本")
            #expect(screen.caret.map { [$0.x, $0.y] } == [2, 1])
            screen.press(.down)
            #expect(model.area.cursor == TextAreaCursor(row: 2, col: 3), "the column is kept, not the character")
            screen.press(.up)
            screen.press(.up)
            #expect(model.area.cursor == TextAreaCursor(row: 0, col: 3))
        }
    }

    @Test func upAndDownOnAWrappedLineAimForTheColumnTheCaretIsDrawnIn() {
        // "alpha beta" | "gamma " | "delta"
        let model = Model("alpha beta gamma delta")
        let screen = Screen(width: 10) {
            TextArea(text: model.textBinding, state: model.areaBinding, arrowMode: .display)
        }
        screen.click(2, 1)
        #expect(model.areaCharacter == "m")
        screen.press(.down)
        #expect(model.areaCharacter == "l")
        #expect(screen.caret.map { [$0.x, $0.y] } == [2, 2])
        screen.press(.up)
        screen.press(.up)
        #expect(model.area.cursor.col == 2)
        #expect(screen.caret.map { [$0.x, $0.y] } == [2, 0])
    }
}

@Suite("A PromptInput's caret lands on the column it is aimed at")
@MainActor
struct PromptInputCaretColumnTests {

    /// The column the prompt's text starts in, past `❯ `.
    private let textStart = 2

    @Test func aClickOnAWrappedRowLandsOnTheCharacterDrawnThere() {
        let model = Model("alpha beta gamma delta epsilon")
        let screen = Screen(width: 12) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        expectEveryCellPlacesTheCaret(on: screen, rows: 0..<4, from: textStart) { model.promptCharacter }
    }

    @Test func aClickOnEitherHalfOfAWideGlyphLandsOnIt() {
        let model = Model("中文 abc 日本語 かなカナ")
        let screen = Screen(width: 12) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        expectEveryCellPlacesTheCaret(on: screen, rows: 0..<3, from: textStart) { model.promptCharacter }
        let row = screen.frame()[1]
        screen.click(row.distance(from: row.startIndex, to: row.firstIndex(of: "本")!) + 1, 1)
        screen.type("X")
        #expect(model.text == "中文 abc 日X本語 かなカナ")
    }

    @Test(arguments: ["alpha beta gamma delta epsilon", "中文 abc 日本語 かなカナ"])
    func theCaretIsDrawnOnTheCharacterTheCursorIsBefore(text: String) {
        let model = Model(text)
        let screen = Screen(width: 12) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        screen.click(textStart, 0)
        for (index, character) in text.enumerated() where character != " " {
            model.prompt.cursorCol = index
            screen.frame()
            let caret = screen.caret
            #expect(caret.map { screen.buffer[$0.x, $0.y].character } == character, "the cursor before \(index)")
        }
    }

    @Test func upAndDownWalkTheRowsAsDrawn() {
        // "alpha beta" | "gamma " | "delta"
        let model = Model("alpha beta gamma delta")
        let screen = Screen(width: 12) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        screen.click(textStart + 2, 2)
        #expect(model.promptCharacter == "l")
        screen.press(.up)
        #expect(model.promptCharacter == "m")
        #expect(screen.caret.map { [$0.x, $0.y] } == [textStart + 2, 1])
        screen.press(.up)
        #expect(model.prompt.cursorCol == 2)
        screen.press(.down)
        screen.press(.down)
        #expect(model.promptCharacter == "l")
    }

    @Test func upAndDownKeepTheColumnAcrossWideGlyphs() {
        let model = Model("abcdefgh\n日本語xy\nabcdefgh")
        for arrowMode in [PromptArrowMode.logical, .display] {
            model.prompt = PromptInputState()
            let screen = Screen(width: 20) {
                PromptInput(text: model.textBinding, state: model.promptBinding, arrowMode: arrowMode)
            }
            screen.click(textStart + 3, 0)
            screen.press(.down)
            #expect(model.prompt.cursorRow == 1 && model.prompt.cursorCol == 1, "column 3 is the right half of 本")
            #expect(screen.caret.map { [$0.x, $0.y] } == [textStart + 2, 1])
            screen.press(.down)
            #expect(model.prompt.cursorRow == 2 && model.prompt.cursorCol == 3, "the column is kept")
            screen.press(.up)
            screen.press(.up)
            #expect(model.prompt.cursorRow == 0 && model.prompt.cursorCol == 3)
        }
    }

    @Test func aCollapsedPasteAfterAWrapIsStyledWhereItIsDrawn() {
        // The first row is full, so the wrap drops the space after it.
        let model = Model("1234567890 123456789 ")
        model.prompt.cursorCol = model.text.count
        PromptInput.handlePaste("line one\nline two", text: model.textBinding, state: model.promptBinding,
                                maxVisibleLines: 8, wrapWidth: 20)
        model.text += " tail"
        let screen = Screen(width: 22) { PromptInput(text: model.textBinding, state: model.promptBinding) }
        let rows = screen.frame()
        let markerRow = rows.firstIndex { $0.contains("[Pasted") }!
        let row = rows[markerRow]
        let opening = row.distance(from: row.startIndex, to: row.firstIndex(of: "[")!)
        #expect(screen.buffer[opening, markerRow].style.italic, "the marker's first cell:\n\(rows.joined(separator: "\n"))")
        let tailRow = rows.firstIndex { $0.contains("tail") }!
        let tail = rows[tailRow]
        let closing = tail.distance(from: tail.startIndex, to: tail.firstIndex(of: "]")!)
        #expect(screen.buffer[closing, tailRow].style.italic, "the marker's last cell")
        #expect(!screen.buffer[closing + 1, tailRow].style.italic, "the cell after the marker")
    }
}
