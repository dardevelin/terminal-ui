import Observation
import Testing
@testable import TerminalUI

// A list counted one line per row when it chose its window, so a row taller
// than a line overflowed the height the list measured — and a size-driven
// list's GeometryReader. It measures the rows it will draw instead, at the
// width it is laid out at, so a row may be any number of lines tall.

private struct Row: Identifiable {
    let id: Int
    var label: String { "row \(id)\nsecond \(id)\nthird \(id)" }
}

@Observable
private final class Selecting {
    var selected: Int? = 0
}

private final class Appearances {
    var ids: [Int] = []
}

@MainActor
private final class Harness<Content: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let width: Int
    let height: Int
    let content: () -> Content
    private(set) var droppedWrites = 0

    init(width: Int = 30, height: Int = 20, @TerminalViewBuilder _ content: @escaping () -> Content) {
        self.width = width
        self.height = height
        self.content = content
    }

    var root: AttributeNode { graph.root! }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: content()) }
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: root)
        droppedWrites = buffer.clipRejectedWrites
        return buffer.rowTexts
    }

    func line(containing text: String, in screen: [String]) -> Int? {
        screen.firstIndex { $0.contains(text) }
    }
}

private let rows = (0..<10).map(Row.init)

@Suite("A list measures its rows at the width it is laid out at")
@MainActor
struct ListRowHeightTests {

    @Test func aDeclaredListOfTallRowsDrawsNoMoreLinesThanItWasGiven() {
        let harness = Harness {
            VStack {
                List(rows, visibleCount: 6) { row in Text(row.label) }
                Text("below")
            }
        }
        let screen = harness.frame()
        // A second row would take seven: one row and ▼ are what fits whole.
        #expect(harness.line(containing: "below", in: screen) == 4, "\(screen)")
        #expect(screen[0].contains("row 0") && screen[2].contains("third 0"), "\(screen)")
        #expect(screen[3].contains("▼ 9 more"), "\(screen)")
        #expect(harness.droppedWrites == 0)
    }

    @Test func wrappedTextIsMeasuredAtTheListsWidth() {
        let words = (0..<6).map { Row(id: $0) }
        let harness = Harness(width: 16) {
            VStack {
                List(words, visibleCount: 5) { row in Text("item \(row.id) wraps onto two") }
                Text("below")
            }
        }
        let screen = harness.frame()
        #expect(harness.line(containing: "below", in: screen) == 5, "\(screen)")
        #expect(screen[4].contains("▼ 4 more"), "two rows of two lines, then ▼: \(screen)")
    }

    @Test func aSizeDrivenListStaysInsideItsFrame() {
        let harness = Harness {
            VStack {
                List(rows) { row in Text(row.label) }
                    .frame(height: 7)
                Text("below")
            }
        }
        let screen = harness.frame()
        #expect(harness.line(containing: "below", in: screen) == 7, "\(screen)")
        #expect(screen[6].contains("▼ 8 more"), "two rows and ▼ fill seven lines: \(screen)")
        #expect(harness.droppedWrites == 0, "the list wrote past its frame")
    }

    /// Laid out first at its stack's size and then at its own slot, a list
    /// that wrote its offset as each pass ran followed the selection for the
    /// height it was not drawn at, and the selected row went out of view.
    @Test func aSizeDrivenListUnderItsSiblingsKeepsTheSelectionInView() {
        let selecting = Selecting()
        let harness = Harness(height: 8) {
            VStack {
                Text("head")
                Text("head")
                List((0..<20).map(Row.init),
                     selection: Binding(get: { selecting.selected }, set: { selecting.selected = $0 })) { row in
                    Text("item \(row.id)")
                }
            }
        }
        harness.frame()
        for selected in 1...8 {
            selecting.selected = selected
            let screen = harness.frame()
            #expect(screen.contains { $0.hasSuffix("▸ item \(selected)") }, "\(selected): \(screen)")
            #expect(harness.frame() == screen, "the next frame should draw the same: \(screen)")
        }
    }

    /// The row past the window is measured every frame. Built for that and
    /// dropped again, it would appear every frame.
    @Test func noRowAppearsAgainWhileTheWindowStaysPut() {
        let appeared = Appearances()
        let harness = Harness {
            VStack {
                List(rows, visibleCount: 8) { row in
                    Text(row.label).onAppear { appeared.ids.append(row.id) }
                }
            }
        }
        harness.frame()
        #expect(appeared.ids.sorted() == [0, 1, 2], "two drawn rows and the one past them: \(appeared.ids)")
        for _ in 0..<3 { harness.frame() }
        #expect(appeared.ids.sorted() == [0, 1, 2], "a row appeared again: \(appeared.ids)")
    }

    @Test func aDeclaredListInAnHStackKeepsItsContentWidth() {
        let short = (0..<3).map { Row(id: $0) }
        let harness = Harness {
            HStack {
                List(short, visibleCount: 3) { row in Text("ab\(row.id)") }
                Text("|")
            }
        }
        let screen = harness.frame()
        #expect(screen[0].hasPrefix("  ab0|"), "the list should be as wide as its rows: \(screen)")
    }

    @Test func aRowThatWouldOverflowIsKeptButNotDrawn() {
        let harness = Harness {
            VStack {
                List(rows, visibleCount: 8) { row in
                    VStack {
                        Text(row.label)
                        Button("open \(row.id)") {}
                    }
                }
                Text("below")
            }
        }
        let screen = harness.frame()
        #expect(harness.line(containing: "below", in: screen) == 5, "one four-line row and ▼: \(screen)")
        #expect(!screen.joined().contains("open 1"), "\(screen)")
        #expect(harness.droppedWrites == 0, "the row past the window wrote outside it")
        var stops = Set<NodeID>()
        for _ in 0..<6 {
            harness.engine.focusNext()
            if let focused = harness.engine.keyboardFocusID { stops.insert(focused) }
        }
        #expect(stops.count == 2, "the list and the drawn row's button, not the button past the window: \(stops)")
    }
}
