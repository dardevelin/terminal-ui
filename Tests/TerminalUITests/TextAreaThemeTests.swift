import Testing
@testable import TerminalUI

// TextArea drew its cursor, selection, gutter and empty-row markers in literal
// colours no theme reached, so an app that restyled everything else got a
// cyan-and-blue editor in the middle of it. They are theme roles now, and the
// stock theme's values reproduce the old literals.

private struct Marked: Theme {
    var accent: Color = .magenta
    var foregroundEmphasis: Color = .yellow
    var backgroundSelected: Color = .green
    var foregroundMuted: Color = .rgb(1, 2, 3)
    var foregroundFaint: Color = .rgb(4, 5, 6)
}

@MainActor
private func render(_ theme: any Theme, text: String, selection: TextAreaSelection? = nil,
                    lineNumbers: Bool = false, height: Int = 2) -> CellBuffer {
    var document = text
    var state = TextAreaState()
    state.cursor = TextAreaCursor(row: 0, col: 0)
    state.selection = selection
    let view = TextArea(text: Binding(get: { document }, set: { document = $0 }),
                        state: Binding(get: { state }, set: { state = $0 }),
                        lineNumbers: lineNumbers, visibleHeight: height)
        .environment(\.theme, theme)
    let graph = AttributeGraph()
    graph.update(from: view)
    var focused = EnvironmentValues()
    focused.focusedID = focusableID(in: graph.root!)
    var buffer = CellBuffer(width: 16, height: height)
    let rect = Rect(x: 0, y: 0, width: 16, height: height)
    GraphContext.$currentEnvironment.withValue(focused) {
        graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return buffer
}

private func focusableID(in node: AttributeNode) -> NodeID? {
    if node.isFocusable { return node.id }
    return node.children.lazy.compactMap { focusableID(in: $0) }.first
}

@Suite("TextArea draws with the theme")
@MainActor
struct TextAreaThemeTests {

    @Test func theCursorTakesAccentAndEmphasis() {
        let cursor = render(Marked(), text: "ab")[0, 0]
        #expect(cursor.style.background == .magenta)
        #expect(cursor.style.foreground == .yellow)
    }

    @Test func theSelectionTakesBackgroundSelected() {
        let selection = TextAreaSelection(start: TextAreaCursor(row: 0, col: 0),
                                          end: TextAreaCursor(row: 0, col: 2))
        #expect(render(Marked(), text: "abc", selection: selection)[1, 0].style.background == .green)
    }

    @Test func theGutterIsMutedAndEmptyRowsFaint() {
        let buffer = render(Marked(), text: "ab", lineNumbers: true)
        #expect(buffer[2, 0].character == "1")
        #expect(buffer[2, 0].style.foreground == .rgb(1, 2, 3))
        let marker = (0..<16).first { buffer[$0, 1].character == "~" }!
        #expect(buffer[marker, 1].style.foreground == .rgb(4, 5, 6))
    }

    @Test func theStockThemeKeepsTheOldColours() {
        let cursor = render(DefaultTheme(), text: "ab")[0, 0]
        #expect(cursor.style.background == .cyan)
        #expect(cursor.style.foreground == .white)
    }
}
