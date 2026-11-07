import Testing
@testable import TerminalUI

// A display-only table is one Text: a header, a `─` rule and a line per row,
// each cell padded or cut to its column. These tests pin that output down
// exactly, so a table that takes a selection is built beside it without
// moving a cell of it.

private struct Process: Identifiable {
    let id: Int
    let name: String
    let state: String
    let cpu: String
}

private let processes = [
    Process(id: 1, name: "kernel_task", state: "run", cpu: "12.5"),
    Process(id: 2, name: "zsh", state: "sleep", cpu: "0.1"),
    Process(id: 3, name: "launchd", state: "run", cpu: "100.0"),
]

private var columns: [TableColumn<Process>] {
    [
        TableColumn("Name", width: 8) { $0.name },
        TableColumn("State", width: 6, alignment: .center) { $0.state },
        TableColumn("CPU", width: 5, alignment: .right) { $0.cpu },
    ]
}

/// The lines a display-only table over `processes` draws, trailing padding
/// included.
private let header = "Name     State    CPU"
private let rule = "──────── ────── ─────"
private let rows = [
    "kernel_…  run    12.5",
    "zsh      sleep    0.1",
    "launchd   run   100.0",
]

/// A view drawn frame by frame, as the runtime draws it: rebuilt, laid out,
/// rendered, and its focus index rebuilt, with the first control focused at
/// launch.
@MainActor
private final class Screen<Content: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let width: Int
    let height: Int
    let view: Content

    init(width: Int = 30, height: Int = 8, _ view: Content) {
        self.width = width
        self.height = height
        self.view = view
    }

    var root: AttributeNode { graph.root! }

    @discardableResult
    func frame() -> [String] {
        var environment = EnvironmentValues()
        environment.terminalSize = TerminalSize(cols: width, rows: height)
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(environment) {
                GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
                    graph.update(from: view)
                    Layout.measureAndPlace(graph: root, in: rect)
                    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
                }
            }
        }
        engine.rebuildIndex(root: root)
        if engine.keyboardFocusID == nil { engine.focusNext() }
        return buffer.rowTexts
    }

    var tabStops: Int { engine.collectFocusables(root).count }
}

@Suite("A table lists rows in aligned columns")
@MainActor
struct TableSelectionTests {

    // MARK: - Display only

    @Test func theTextIsAHeaderARuleAndALinePerRow() {
        let table = Table(processes, columns: columns)
        #expect(table.renderTable() == ([header, rule] + rows).joined(separator: "\n"))
    }

    @Test func eachCellIsPaddedToItsColumnAndALongOneIsCut() {
        let screen = Screen(Table(processes, columns: columns))
        let drawn = screen.frame()
        #expect(Array(drawn.prefix(5)) == [header, rule] + rows, "\(drawn)")
        #expect(drawn[5].isEmpty)
    }

    @Test func theSeparatorStandsBetweenColumns() {
        let table = Table(processes, columns: columns, separator: " | ")
        let lines = table.renderTable().split(separator: "\n").map(String.init)
        #expect(lines[0] == "Name     | State  |   CPU")
        #expect(lines[1] == "──────── | ────── | ─────")
        #expect(lines[3] == "zsh      | sleep  |   0.1")
    }

    @Test func withoutAHeaderOnlyTheRowsAreDrawn() {
        let screen = Screen(Table(processes, columns: columns, showHeader: false))
        #expect(Array(screen.frame().prefix(4)) == rows + [""])
    }

    @Test func anEmptyTableSaysItHasNoRows() {
        let screen = Screen(Table([Process](), columns: columns))
        #expect(screen.frame().first == "— no rows —")
    }

    // MARK: - Header and row lines

    @Test func aRowLineIsThatRowsLineOfTheText() {
        let table = Table(processes, columns: columns)
        #expect(processes.map(table.rowLine) == rows)
    }

    @Test func theHeaderLinesAreTheHeaderAndTheRuleIndentedAsAsked() {
        let table = Table(processes, columns: columns)
        #expect(table.headerLines(indent: 0) == [header, rule])
        #expect(table.headerLines(indent: 2) == ["  " + header, "  " + rule])
    }

    @Test func aTableWithoutAHeaderHasNoHeaderLines() {
        let table = Table(processes, columns: columns, showHeader: false)
        #expect(table.headerLines(indent: 2).isEmpty)
    }

    @Test func aDisplayOnlyTableIsNoTabStop() {
        let screen = Screen(Table(processes, columns: columns))
        screen.frame()
        #expect(screen.tabStops == 0)
        #expect(screen.engine.keyHandlers.isEmpty)
        #expect(screen.engine.clickHandlers.isEmpty)
    }
}
