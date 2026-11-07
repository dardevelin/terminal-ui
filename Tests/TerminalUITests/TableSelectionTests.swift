import Observation
import Testing
@testable import TerminalUI

// A display-only table is one Text: a header, a `─` rule and a line per row,
// each cell padded or cut to its column. These tests pin that output down
// exactly, so a table that takes a selection is built beside it without
// moving a cell of it. A table given a selection draws its rows through a
// List, under a header that stays put, lined up after the list's cursor.

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

/// Enough rows to scroll a window of a few.
private let many = (0..<10).map { Process(id: $0 + 10, name: "proc\($0)", state: "run", cpu: "\($0)") }

@Observable
private final class Selecting {
    var selected: Int?
    init(_ selected: Int? = nil) { self.selected = selected }
    var binding: Binding<Int?> { Binding(get: { self.selected }, set: { self.selected = $0 }) }
}

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

    func press(_ key: Key) {
        _ = engine.routeKeyEvent(KeyEvent(key: key), root: root)
    }

    func click(_ x: Int, _ y: Int) {
        engine.handleMouseClick(x: x, y: y, root: root)
    }

    func wheel(_ key: Key, _ x: Int, _ y: Int) {
        _ = engine.routeWheel(KeyEvent(key: key), root: root, x: x, y: y, policy: .clickToLock)
    }
}

@Suite("A table lists rows in aligned columns, and can take a selection")
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

    // MARK: - Selection

    @Test func aTableWithASelectionIsOneTabStop() {
        let selecting = Selecting(1)
        let screen = Screen(Table(processes, selection: selecting.binding, visibleCount: 4, columns: columns))
        screen.frame()
        #expect(screen.tabStops == 1)
    }

    @Test func theBoundRowWearsTheCursorUnderAHeaderLinedUpWithTheCells() {
        let selecting = Selecting(2)
        let screen = Screen(Table(processes, selection: selecting.binding, visibleCount: 4, columns: columns))
        let drawn = screen.frame()
        #expect(Array(drawn.prefix(6)) == [
            "  " + header,
            "  " + rule,
            "  " + rows[0],
            "▸ " + rows[1],
            "  " + rows[2],
            "",
        ], "\(drawn)")
    }

    @Test func theArrowsAndPagingKeysMoveTheSelection() {
        let selecting = Selecting(10)
        let screen = Screen(Table(many, selection: selecting.binding, visibleCount: 4, columns: columns))
        screen.frame()
        screen.press(.down)
        #expect(selecting.selected == 11)
        screen.frame()
        screen.press(.up)
        #expect(selecting.selected == 10)
        screen.frame()
        // A page is the rows drawn: three under the header, above `▼`.
        screen.press(.pageDown)
        #expect(selecting.selected == 13)
        screen.frame()
        screen.press(.end)
        #expect(selecting.selected == 19)
    }

    @Test func scrolledTheHeaderStaysOnTopWithTheIndicatorUnderIt() {
        let selecting = Selecting(10)
        let table = Table(many, selection: selecting.binding, visibleCount: 4, columns: columns)
        let screen = Screen(table)
        screen.frame()
        screen.press(.end)
        let drawn = screen.frame()
        #expect(Array(drawn.prefix(6)) == [
            "  " + header,
            "  " + rule,
            "  ▲ 7 more",
            "  " + table.rowLine(many[7]),
            "  " + table.rowLine(many[8]),
            "▸ " + table.rowLine(many[9]),
        ], "\(drawn)")
    }

    @Test func withoutAVisibleCountTheRowsFillTheRoomUnderTheHeader() {
        let selecting = Selecting(10)
        let table = Table(many, selection: selecting.binding, columns: columns)
        let screen = Screen(height: 8, table)
        let drawn = screen.frame()
        #expect(drawn == [
            "  " + header,
            "  " + rule,
            "▸ " + table.rowLine(many[0]),
            "  " + table.rowLine(many[1]),
            "  " + table.rowLine(many[2]),
            "  " + table.rowLine(many[3]),
            "  " + table.rowLine(many[4]),
            "  ▼ 5 more",
        ], "\(drawn)")
    }

    @Test func anEmptyTableWithASelectionIsStillATabStop() {
        let selecting = Selecting()
        let screen = Screen(Table([Process](), selection: selecting.binding, visibleCount: 3, columns: columns))
        let drawn = screen.frame()
        #expect(screen.tabStops == 1)
        #expect(drawn.first == "  " + header, "\(drawn)")
    }

    @Test func narrowerThanItsColumnsEachLineIsCutNotWrapped() {
        let selecting = Selecting(1)
        let screen = Screen(width: 12, Table(processes, selection: selecting.binding, visibleCount: 3,
                                             columns: columns))
        let drawn = screen.frame()
        #expect(Array(drawn.prefix(6)) == [
            "  Name     S",
            "  ──────── ─",
            "▸ kernel_…",
            "  zsh      s",
            "  launchd",
            "",
        ], "\(drawn)")
    }

    // MARK: - Pointer

    @Test func aClickOnARowSelectsIt() {
        let selecting = Selecting(1)
        let screen = Screen(Table(processes, selection: selecting.binding, visibleCount: 4, columns: columns))
        screen.frame()
        screen.click(4, 4)
        #expect(selecting.selected == 3)
        screen.frame()
        screen.click(4, 2)
        #expect(selecting.selected == 1)
    }

    @Test func aClickOnTheHeaderOrTheRuleChangesNothing() {
        let selecting = Selecting(2)
        let screen = Screen(Table(processes, selection: selecting.binding, visibleCount: 4, columns: columns))
        let before = screen.frame()
        screen.click(4, 0)
        screen.click(4, 1)
        #expect(selecting.selected == 2)
        #expect(screen.frame() == before)
    }

    @Test func aClickAfterTheWheelScrolledSelectsTheRowDrawnThere() {
        let selecting = Selecting(10)
        let table = Table(many, selection: selecting.binding, visibleCount: 4, columns: columns)
        let screen = Screen(table)
        screen.frame()
        screen.wheel(.down, 4, 3)
        let drawn = screen.frame()
        #expect(Array(drawn.prefix(6)) == [
            "  " + header,
            "  " + rule,
            "  ▲ 1 more",
            "  " + table.rowLine(many[1]),
            "  " + table.rowLine(many[2]),
            "  ▼ 7 more",
        ], "the wheel scrolls the rows and leaves the selection: \(drawn)")
        screen.click(4, 2)
        #expect(selecting.selected == 10, "the indicator line is no row")
        screen.click(4, 4)
        #expect(selecting.selected == 12)
    }
}
