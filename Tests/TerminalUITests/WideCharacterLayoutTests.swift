import Testing
@testable import TerminalUI

// Views that measured text with `String.count` — one column per Character —
// laid double-width glyphs out in half the columns they take: the caret of a
// field typing CJK slid off its right edge, table columns and status-bar
// sections shifted right, bars started at different columns. Each pins its
// layout in cells.

@MainActor
private func draw(_ view: some TerminalView, width: Int, height: Int = 1) -> CellBuffer {
    renderedBuffer(view, width: width, height: height)
}

/// The column of the first cell holding `glyph` on row `y`.
private func column(of glyph: Character, row y: Int = 0, in buffer: CellBuffer) -> Int? {
    (0..<buffer.width).first { buffer[$0, y].character == glyph }
}

/// `input` drawn focused, as its caret is drawn only with focus.
@MainActor
private func drawFocused(_ input: TextInput, width: Int) -> CellBuffer {
    let graph = AttributeGraph()
    graph.update(from: input)
    var focused = EnvironmentValues()
    focused.focusedID = firstFocusable(in: graph.root!)
    var buffer = CellBuffer(width: width, height: 1)
    let context = RenderContext(rect: Rect(x: 0, y: 0, width: width, height: 1))
    GraphContext.$currentEnvironment.withValue(focused) {
        graph.update(from: input)
        GraphRenderer.render(graph.root!, into: &buffer, context: context)
    }
    return buffer
}

private func firstFocusable(in node: AttributeNode) -> NodeID? {
    if node.isFocusable { return node.id }
    return node.children.lazy.compactMap { firstFocusable(in: $0) }.first
}

private struct Row: Identifiable {
    let id: Int
}

@Suite("Wide characters are laid out in cells")
@MainActor
struct WideCharacterLayoutTests {

    @Test("a field's horizontal window holds as many cells as it has room for")
    func textInputWindowInCells() {
        let value = String(repeating: "中", count: 12)
        let tail = TextInput.windowedSlice(value: value, cursor: 12, room: 10)
        #expect(tail.visible == String(repeating: "中", count: 5))
        #expect(tail.cursorOffset == 5)

        let middle = TextInput.windowedSlice(value: value, cursor: 7, room: 10, windowStart: 0)
        #expect(middle.windowStart == 3, "the glyph under the cursor ends at the right edge")
        #expect(middle.visible.displayWidth == 10)
        #expect(middle.cursorOffset == 4)
    }

    @Test("the caret of a field typing CJK stays inside the field")
    func textInputCaretVisible() {
        var text = "中文中文中文中文"
        let input = TextInput("", text: Binding(get: { text }, set: { text = $0 }))
        // Seven cells of room hold three glyphs; the caret takes the next.
        let buffer = drawFocused(input, width: 8)
        #expect(buffer.text(row: 0) == "文 中 文 │", "\(buffer.rowTexts)")
    }

    @Test("a wide prompt reserves the cells it takes")
    func textInputWidePrompt() {
        var text = "abcdefghij"
        let input = TextInput("名前> ", text: Binding(get: { text }, set: { text = $0 }))
        let buffer = drawFocused(input, width: 10)
        #expect(column(of: "│", in: buffer) == 9, "\(buffer.rowTexts)")
    }

    @Test("a text area wraps a line by the cells it takes")
    func textAreaWrapsInCells() {
        let chunks = TextArea.displayChunks(of: "中文中文中文中文中文", wrapWidth: 15)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.displayWidth <= 15 })
    }

    @Test("a table cell truncates and pads to its column's cells")
    func tableCellInCells() {
        let table = Table([Row(id: 0)], columns: [TableColumn("Name") { "\($0.id)" }])
        for text in ["中文字符串", "ab", "中a"] {
            #expect(table.alignText(text, width: 6, alignment: .left).displayWidth == 6, "\(text)")
            #expect(table.alignText(text, width: 6, alignment: .right).displayWidth == 6, "\(text)")
        }
        #expect(table.alignText("中文字符串", width: 6, alignment: .left) == "中文… ")
    }

    @Test("a status bar's right section ends at its right edge after a wide left one")
    func statusBarInCells() {
        let bar = StatusBar {
            StatusBar.Section(.left) { TextSpan("中文中文") }
            StatusBar.Section(.right) { TextSpan("END") }
        }
        let row = draw(bar, width: 20).text(row: 0)
        #expect(row.hasSuffix("END"), "\(row)")
        #expect(row.count == 20, "\(row)")
    }

    @Test("bars start in one column whatever their labels' widths")
    func barChartLabelsInCells() {
        let chart = BarChart(items: [BarChart.Item(label: "日本", value: 5),
                                     BarChart.Item(label: "Go", value: 5)], barWidth: 4)
        let buffer = draw(chart, width: 20, height: 2)
        #expect(column(of: "█", row: 0, in: buffer) == column(of: "█", row: 1, in: buffer),
                "\(buffer.rowTexts)")
    }

    @Test("a progress bar with a wide label keeps its percentage on screen")
    func progressBarWideLabel() {
        let row = draw(ProgressBar(value: 0.5, label: "進捗"), width: 20).text(row: 0)
        #expect(row.hasSuffix("50%"), "\(row)")
        #expect(row.count == 20, "\(row)")
    }

    @Test("a plain Text pads to its rect in cells, writing nothing past it")
    func plainTextPadInCells() {
        let buffer = draw(HStack(spacing: 0) { Text("中文"); Text("x") }, width: 10)
        #expect(buffer.text(row: 0) == "中 文 x")
        #expect(buffer.clipRejectedWrites == 0)
    }

    @Test("form labels of any width share one control column")
    func formLabelsInCells() {
        var on = false
        let toggle = Binding(get: { on }, set: { on = $0 })
        let buffer = draw(Form {
            Toggle("名前", isOn: toggle)
            Toggle("Age", isOn: toggle)
        }, width: 30, height: 4)
        let rows = (0..<buffer.height).filter { column(of: "[", row: $0, in: buffer) != nil }
        #expect(rows.count == 2, "\(buffer.rowTexts)")
        #expect(Set(rows.map { column(of: "[", row: $0, in: buffer) }).count == 1, "\(buffer.rowTexts)")
    }

    @Test("a segmented picker measures its titles in cells")
    func segmentedPickerInCells() {
        #expect(PickerBody.segmentedWidth(of: ["中文"], label: "言語") == 4 + 1 + 4 + 3 - 1)
    }
}
