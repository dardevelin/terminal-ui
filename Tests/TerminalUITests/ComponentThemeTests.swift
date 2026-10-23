import Testing
@testable import TerminalUI

// TabView, TreeView, HunkDiffView, StatusBar, TextInput's prompt and
// placeholder, Form's section headers and the empty placeholder drew gray,
// white, cyan, magenta and a 256-colour band of their own, whatever theme
// the app set: a themed app had the terminal's palette in the middle of its
// own. They ask the theme now, and the stock theme's roles are, nearly
// everywhere, the colours they drew.

/// Every role a value no literal in the codebase produces, so a cell wearing
/// one can only have come from the theme.
private struct LoudTheme: Theme {
    var accent: Color = .rgb(1, 2, 3)
    var foregroundEmphasis: Color = .rgb(4, 5, 6)
    var foreground: Color = .rgb(7, 8, 9)
    var foregroundMuted: Color = .rgb(10, 11, 12)
    var foregroundFaint: Color = .rgb(31, 32, 33)
    var separator: Color = .rgb(13, 14, 15)
    var backgroundRaised: Color = .rgb(16, 17, 18)
    var background: Color = .rgb(34, 35, 36)
    var backgroundSelected: Color = .rgb(37, 38, 39)
    var success: Color = .rgb(19, 20, 21)
    var error: Color = .rgb(22, 23, 24)
    var info: Color = .rgb(25, 26, 27)
    var attention: Color = .rgb(28, 29, 30)
}

@MainActor
private func render(_ view: some TerminalView, width: Int = 40, height: Int = 12,
                    theme: (any Theme)? = LoudTheme()) -> CellBuffer {
    let graph = AttributeGraph()
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    var environment = EnvironmentValues()
    if let theme { environment.theme = theme }
    GraphContext.$currentEnvironment.withValue(environment) {
        graph.update(from: view)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
    }
    return buffer
}

/// The cell where `text` first starts on screen.
private func cell(at text: String, in buffer: CellBuffer) -> Cell? {
    for y in 0..<buffer.height {
        let row = String((0..<buffer.width).map { buffer[$0, y].character })
        if let range = row.range(of: text) {
            return buffer[row.distance(from: row.startIndex, to: range.lowerBound), y]
        }
    }
    return nil
}

private func foreground(of text: String, in buffer: CellBuffer) -> Color? {
    cell(at: text, in: buffer)?.style.foreground
}

private struct Node: Identifiable {
    let id: String
    let children: [Node]?
}

private let tree = [Node(id: "root", children: [Node(id: "leaf", children: nil)])]

private let hunks = [HunkDiff.Hunk(oldStart: 1, newStart: 1, lines: [
    .init(type: .context, content: "kept", oldLineNo: 1, newLineNo: 1),
    .init(type: .remove, content: "gone", oldLineNo: 2),
    .init(type: .add, content: "fresh", newLineNo: 2),
    .init(type: .context, content: "tail", oldLineNo: 3, newLineNo: 3),
])]

@Suite("Components draw in the app's theme")
@MainActor
struct ComponentThemeTests {

    // MARK: - TabView

    @Test func tabsTakeEmphasisMutedAndSeparatorRoles() {
        let buffer = render(TabView {
            Tab("One") { Text("first") }
            Tab("Two") { Text("second") }
        })
        let theme = LoudTheme()
        #expect(foreground(of: "One", in: buffer) == theme.foregroundEmphasis)
        #expect(foreground(of: "Two", in: buffer) == theme.foregroundMuted)
        #expect(foreground(of: "|", in: buffer) == theme.separator)
    }

    @Test func overflowMarkersTakeTheMutedRole() {
        let buffer = render(TabView {
            Tab("First section") { Text("first") }
            Tab("Second section") { Text("second") }
            Tab("Third section") { Text("third") }
        }, width: 30)
        #expect(foreground(of: " >", in: buffer) == LoudTheme().foregroundMuted)
    }

    // MARK: - TreeView

    @Test func treeRowsTakeAccentEmphasisMutedAndSeparatorRoles() {
        let buffer = render(TreeView(tree, children: \.children) { Text($0.id) })
        let theme = LoudTheme()
        #expect(foreground(of: "root", in: buffer) == theme.foregroundEmphasis)
        #expect(foreground(of: "▾", in: buffer) == theme.accent)
        #expect(foreground(of: "└", in: buffer) == theme.separator)
    }

    /// A row paints no ground of its own unless the style gives the selected
    /// one a fill: on a themed panel, the panel shows through every row.
    @Test func treeRowsLetTheirPanelShowThrough() {
        let panel = Color.rgb(40, 41, 42)
        let buffer = render(VStack {
            TreeView(tree, children: \.children) { Text($0.id) }
        }.background(panel))
        #expect(cell(at: "root", in: buffer)?.style.background == panel)
        #expect(cell(at: "leaf", in: buffer)?.style.background == panel)
    }

    @Test func aSelectedFillTheStyleStatesIsPainted() {
        var style = TreeViewStyle()
        style.selectedBackground = .blue
        let buffer = render(VStack {
            TreeView(tree, children: \.children, style: style) { Text($0.id) }
        }.background(.rgb(40, 41, 42)))
        #expect(cell(at: "root", in: buffer)?.style.background == .blue)
        #expect(cell(at: "leaf", in: buffer)?.style.background == .rgb(40, 41, 42))
    }

    /// The segmented picker's unselected segments painted the theme's window
    /// ground, so on a raised panel each one was a hole down to the window.
    @Test func unselectedSegmentsLetTheirPanelShowThrough() {
        let panel = Color.rgb(40, 41, 42)
        let buffer = render(VStack {
            Picker("Theme", selection: Binding(get: { "dark" }, set: { _ in })) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
            .pickerStyle(.segmented)
        }.background(panel))
        #expect(cell(at: "Light", in: buffer)?.style.background == panel)
        #expect(cell(at: "Dark", in: buffer)?.style.background == LoudTheme().backgroundSelected)
    }

    @Test func aColourTheStyleStatesWinsOverTheTheme() {
        var style = TreeViewStyle()
        style.connectorColor = .magenta
        style.selectedForeground = .yellow
        let buffer = render(TreeView(tree, children: \.children, style: style) { Text($0.id) })
        #expect(foreground(of: "└", in: buffer) == .magenta)
        #expect(foreground(of: "root", in: buffer) == .yellow)
    }

    /// Code that read a style's colours before they followed the theme
    /// still reads the colours the stock theme draws.
    @Test func anUnsetStyleColourReadsAsTheStockOne() {
        let style = TreeViewStyle()
        #expect(style.arrowColor == .gray)
        #expect(style.selectedArrowColor == .cyan)
        #expect(style.connectorColor == .gray)
        #expect(style.selectedForeground == .white)
    }

    // MARK: - HunkDiffView

    @Test func hunksTakeStatusInfoAndMutedRoles() {
        let buffer = render(HunkDiffView(hunks: hunks, fileName: "main.swift"))
        let theme = LoudTheme()
        #expect(foreground(of: "main.swift", in: buffer) == theme.foregroundEmphasis)
        #expect(foreground(of: "@@", in: buffer) == theme.info)
        #expect(foreground(of: "+fresh", in: buffer) == theme.success)
        #expect(foreground(of: "-gone", in: buffer) == theme.error)
        #expect(foreground(of: " tail", in: buffer) == theme.foreground)
        #expect(foreground(of: "  1 ", in: buffer) == theme.foregroundMuted)
        #expect(foreground(of: "▸", in: buffer) == theme.accent)
    }

    @Test func aLockedRangeTakesTheAttentionRole() {
        let buffer = render(HunkDiffView(hunks: hunks, fileName: "main.swift", lockedRange: (1, 1)))
        #expect(foreground(of: "┃", in: buffer) == LoudTheme().attention)
    }

    // MARK: - StatusBar

    @Test func theBarTakesTheRaisedGroundAndBodyText() {
        let buffer = render(StatusBar { StatusBar.Section(.left) { "READY" } })
        let ready = cell(at: "READY", in: buffer)
        #expect(ready?.style.foreground == LoudTheme().foreground)
        #expect(ready?.style.background == LoudTheme().backgroundRaised)
        #expect(buffer[39, 0].style.background == LoudTheme().backgroundRaised)
    }

    @Test func keyHintsSetTheKeysInEmphasis() {
        let buffer = render(StatusBar.keyHints([("^C", "Quit")]))
        #expect(foreground(of: "^C", in: buffer) == LoudTheme().foregroundEmphasis)
        #expect(foreground(of: "Quit", in: buffer) == LoudTheme().foreground)
    }

    @Test func colourTheBarStatesWinsOverTheTheme() {
        let buffer = render(StatusBar(background: .blue, foreground: .yellow) {
            StatusBar.Section(.left) { "READY" }
        })
        #expect(cell(at: "READY", in: buffer)?.style.background == .blue)
        #expect(foreground(of: "READY", in: buffer) == .yellow)
    }

    // MARK: - Inputs and forms

    @Test func aFieldsPromptIsMutedAndItsPlaceholderFaint() {
        let buffer = render(TextInput("Name: ", text: Binding(get: { "" }, set: { _ in }),
                                      placeholder: "your name"))
        #expect(foreground(of: "Name:", in: buffer) == LoudTheme().foregroundMuted)
        #expect(foreground(of: "your name", in: buffer) == LoudTheme().foregroundFaint)
    }

    @Test func aSectionHeaderAndAnEmptyPlaceholderAreMuted() {
        let buffer = render(VStack {
            Form { Section("Appearance") { Text("row") } }
            _EmptyPlaceholder()
        })
        #expect(foreground(of: "APPEARANCE", in: buffer) == LoudTheme().foregroundMuted)
        #expect(foreground(of: "— empty —", in: buffer) == LoudTheme().foregroundMuted)
    }

    // MARK: - The stock theme

    @Test func theStockThemeKeepsTheColoursTheyDrew() {
        let tabs = render(TabView {
            Tab("One") { Text("first") }
            Tab("Two") { Text("second") }
        }, theme: nil)
        #expect(foreground(of: "One", in: tabs) == .white)
        #expect(foreground(of: "Two", in: tabs) == .gray)

        let rows = render(TreeView(tree, children: \.children) { Text($0.id) }, theme: nil)
        #expect(foreground(of: "▾", in: rows) == .cyan)
        #expect(foreground(of: "└", in: rows) == .gray)
        #expect(foreground(of: "root", in: rows) == .white)

        let diff = render(HunkDiffView(hunks: hunks, fileName: "main.swift"), theme: nil)
        #expect(foreground(of: "+fresh", in: diff) == .green)
        #expect(foreground(of: "-gone", in: diff) == .red)
        #expect(foreground(of: "▸", in: diff) == .cyan)
    }
}
