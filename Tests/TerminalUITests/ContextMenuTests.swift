import Testing
@testable import TerminalUI

// A press of the secondary button reached nothing: the runtime routed only
// the left one. `.contextMenu` opens a menu where a view is right-clicked,
// as SwiftUI's does, and closes it the ways a platform's menu closes.

@MainActor
private final class Screen<V: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let view: () -> V
    let width: Int
    let height: Int

    init(width: Int = 30, height: Int = 8, _ view: @escaping () -> V) {
        self.view = view
        self.width = width
        self.height = height
        frame()
    }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: view()) }
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: graph.root!)
        return (0..<height).map { y in (0..<width).map { String(buffer[$0, y].character) }.joined() }
    }

    func press(_ x: Int, _ y: Int, button: MouseButton = .left) {
        engine.handlePress(PointerPress(x: x, y: y, button: button), root: graph.root)
        frame()
    }

    func key(_ key: Key) {
        _ = engine.routeKeyEvent(KeyEvent(key: key), root: graph.root)
        frame()
    }

    var text: String { frame().joined(separator: "\n") }
}

@MainActor
private final class Log {
    var entries: [String] = []
}

@Suite("A right click opens a context menu")
@MainActor
struct ContextMenuTests {

    private func file(_ log: Log) -> some TerminalView {
        VStack(spacing: 0) {
            Text("notes.md")
                .onTapGesture { log.entries.append("tap") }
                .contextMenu {
                    Button("Open") { log.entries.append("open") }
                    Button("Delete") { log.entries.append("delete") }
                }
            Text("other")
        }
    }

    @Test func aRightClickOpensTheMenuWhereItWasClicked() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(2, 0, button: .right)
        let rows = screen.frame()
        #expect(rows[0].dropFirst(2).hasPrefix("╭"), "the menu's corner is on the cell clicked:\n\(rows.joined(separator: "\n"))")
        #expect(screen.text.contains("[ Open ]"))
        #expect(log.entries.isEmpty)
    }

    @Test func aLeftClickOpensNothing() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(2, 0)
        #expect(!screen.text.contains("[ Open ]"))
        #expect(log.entries == ["tap"])
    }

    @Test func clickingAnItemRunsItAndClosesTheMenu() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(0, 0, button: .right)
        let rows = screen.frame()
        let y = rows.firstIndex { $0.contains("[ Delete ]") }!
        screen.press(rows[y].distance(from: rows[y].startIndex, to: rows[y].range(of: "Delete")!.lowerBound), y)
        #expect(log.entries == ["delete"])
        #expect(!screen.text.contains("[ Delete ]"))
    }

    @Test func enterOnTheFocusedItemRunsItAndClosesTheMenu() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(0, 0, button: .right)
        screen.key(.enter)
        #expect(log.entries == ["open"])
        #expect(!screen.text.contains("[ Open ]"))
    }

    @Test func escapeClosesTheMenuAndRunsNothing() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(0, 0, button: .right)
        screen.key(.escape)
        #expect(!screen.text.contains("[ Open ]"))
        #expect(log.entries.isEmpty)
    }

    @Test func aPressOutsideClosesTheMenuAndReachesNothingUnderIt() {
        let log = Log()
        let screen = Screen { self.file(log) }
        screen.press(0, 0, button: .right)
        screen.press(25, 7)
        #expect(!screen.text.contains("[ Open ]"))
        screen.press(1, 0)
        #expect(log.entries == ["tap"], "closed, the content takes clicks again")
    }

    @Test func aMenuOpenedByTheEdgeStaysOnTheScreen() {
        let log = Log()
        let screen = Screen(width: 30, height: 4) {
            VStack(spacing: 0) {
                Text(" ")
                Text(" ")
                Text(" ")
                HStack {
                    Spacer()
                    Text("edge").contextMenu { Button("Open") { log.entries.append("open") } }
                }
            }
        }
        screen.press(28, 3, button: .right)
        let rows = screen.frame()
        #expect(rows.contains { $0.hasSuffix("╮") }, "the menu ends at the right edge:\n\(rows.joined(separator: "\n"))")
        #expect(rows[3].contains("╯"), "and its foot on the bottom row")
    }
}
