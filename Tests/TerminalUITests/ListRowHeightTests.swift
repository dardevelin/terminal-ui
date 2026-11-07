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
    var disappeared: [Int] = []

    /// How many times each row has appeared, less the times it disappeared:
    /// 1 for a row in the tree, 0 for one that left it.
    var present: [Int: Int] {
        var count: [Int: Int] = [:]
        for id in ids { count[id, default: 0] += 1 }
        for id in disappeared { count[id, default: 0] -= 1 }
        return count
    }
}

@Observable
private final class Scrolling {
    var offset = 0
}

/// A list's rows, changed between frames.
private final class Rows {
    var ids: [Int]
    init(ids: [Int]) { self.ids = ids }
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

@MainActor
private func listNode(in node: AttributeNode) -> AttributeNode? {
    if node.rowWindowRebuilder != nil || node.geometryRebuilder != nil { return node }
    for child in node.children {
        if let found = listNode(in: child) { return found }
    }
    return nil
}

/// The ids of the rows a list's window holds, drawn or held back.
@MainActor
private func heldIDs(in root: AttributeNode) -> Set<Int> {
    guard let list = listNode(in: root) else { return [] }
    return Set(AttributeGraph.rowNodes(in: list).compactMap { row in
        guard case .explicit(let key)? = row.id.path.last else { return nil }
        return key.base as? Int
    })
}

/// The rows a screen draws, by the `item N` they show.
private func shownIDs(in screen: [String]) -> Set<Int> {
    Set(screen.compactMap { line in
        line.range(of: "item ").flatMap { Int(line[$0.upperBound...]) }
    })
}

/// A list's row nodes, by the id of the row each holds.
@MainActor
private func rowNodesByID(in root: AttributeNode) -> [Int: AttributeNode] {
    guard let list = listNode(in: root) else { return [:] }
    var found: [Int: AttributeNode] = [:]
    for row in AttributeGraph.rowNodes(in: list) {
        if case .explicit(let key)? = row.id.path.last, let id = key.base as? Int { found[id] = row }
    }
    return found
}

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

@Suite("A list's selection, wheel, indicators and paging follow its row heights")
@MainActor
struct ListTallRowNavigationTests {

    private func tallList(_ selecting: Selecting) -> Harness<some TerminalView> {
        Harness {
            List(rows, selection: Binding(get: { selecting.selected }, set: { selecting.selected = $0 }),
                 visibleCount: 8) { row in Text(row.label) }
        }
    }

    @Test func selectingTheLastTallRowDrawsItWhole() {
        let selecting = Selecting()
        let harness = tallList(selecting)
        harness.frame()
        selecting.selected = 9
        let screen = harness.frame()
        #expect(screen[0].contains("▲ 8 more"), "rows 8 and 9 under ▲: \(screen)")
        #expect(screen.contains { $0.hasSuffix("▸ row 9") }, "\(screen)")
        #expect(screen.contains { $0.hasSuffix("third 9") }, "the last row whole: \(screen)")
        #expect(!screen.joined().contains("▼"), "\(screen)")
    }

    @Test func theIndicatorsCountTheRowsOutOfView() {
        let selecting = Selecting()
        let harness = tallList(selecting)
        let top = harness.frame()
        #expect(top[6].contains("▼ 8 more"), "two rows of three lines, then ▼: \(top)")
        selecting.selected = 4
        let screen = harness.frame()
        #expect(screen[0].contains("▲ 3 more"), "\(screen)")
        #expect(screen.contains { $0.hasSuffix("▸ row 4") }, "the selection at the window's foot: \(screen)")
        #expect(screen[7].contains("▼ 5 more"), "\(screen)")
    }

    @Test func pageDownMovesByTheRowsShown() {
        let selecting = Selecting()
        let harness = tallList(selecting)
        harness.frame()
        harness.engine.focusNext()
        #expect(harness.engine.routeKeyEvent(KeyEvent(key: .pageDown), root: harness.root))
        #expect(selecting.selected == 2, "two rows were shown, so a page is two rows")
        harness.frame()
        #expect(harness.engine.routeKeyEvent(KeyEvent(key: .pageUp), root: harness.root))
        #expect(selecting.selected == 0)
    }
}

// A row scrolled out of a list's window left the graph without its
// `onDisappear` running and with its `.task` still going. It leaves as a
// row a ForEach drops does now; the row past the window's edge, kept to be
// measured but not drawn, is still in the tree and fires nothing.
@Suite("A list row scrolled out of view disappears")
@MainActor
struct ListRowLifecycleTests {

    private func scrolledList(
        _ count: Int, _ scrolling: Scrolling, _ seen: Appearances
    ) -> Harness<some TerminalView> {
        Harness {
            List((0..<count).map(Row.init),
                 scroll: Binding(get: { scrolling.offset }, set: { scrolling.offset = $0 }),
                 visibleCount: 5) { row in
                Text("item \(row.id)")
                    .onAppear { seen.ids.append(row.id) }
                    .onDisappear { seen.disappeared.append(row.id) }
            }
        }
    }

    @Test func scrollingOneRowDisappearsTheRowThatLeft() {
        let scrolling = Scrolling()
        let seen = Appearances()
        let harness = scrolledList(20, scrolling, seen)
        harness.frame()
        #expect(seen.disappeared.isEmpty)

        scrolling.offset = 1
        let screen = harness.frame()

        #expect(seen.disappeared == [0], "\(screen)")
    }

    @Test func aHeldRowFiresNothingWhileHeld() {
        let scrolling = Scrolling()
        let seen = Appearances()
        let harness = scrolledList(20, scrolling, seen)
        let screen = harness.frame()
        let held = heldIDs(in: harness.root).filter { id in !screen.contains { $0.hasSuffix("item \(id)") } }
        #expect(held.count == 1, "one row kept past the window: \(held) \(screen)")
        for _ in 0..<3 { harness.frame() }
        for offset in 1...2 {
            scrolling.offset = offset
            harness.frame()
            harness.frame()
        }
        for id in held {
            #expect(seen.ids.filter { $0 == id }.count == 1, "row \(id) appeared again: \(seen.ids)")
            #expect(!seen.disappeared.contains(id), "row \(id) disappeared while held: \(seen.disappeared)")
        }
    }

    @Test func aFarJumpLeavesExactlyTheHeldRowsPresent() {
        let scrolling = Scrolling()
        let seen = Appearances()
        let harness = scrolledList(100, scrolling, seen)
        harness.frame()

        scrolling.offset = 50
        harness.frame()

        let present = seen.present
        #expect(present.values.allSatisfy { $0 == 0 || $0 == 1 }, "\(present)")
        let shown = Set(present.filter { $0.value == 1 }.keys)
        #expect(shown == heldIDs(in: harness.root), "\(present)")
        #expect(shown.contains(50))
    }

    @Test func aDeclaredListDisappearsNothingWhileItStaysPut() {
        let scrolling = Scrolling()
        let seen = Appearances()
        let harness = scrolledList(20, scrolling, seen)
        harness.frame()
        scrolling.offset = 4
        harness.frame()
        let after = seen.disappeared
        for _ in 0..<4 { harness.frame() }
        #expect(seen.disappeared == after, "a steady frame dropped a row: \(seen.disappeared)")
    }

    @Test func aSizeDrivenListAmongSiblingsDisappearsNothingWhileItStaysPut() {
        let seen = Appearances()
        let harness = Harness(height: 8) {
            VStack {
                Text("head")
                List((0..<20).map(Row.init)) { row in
                    Text("item \(row.id)")
                        .onAppear { seen.ids.append(row.id) }
                        .onDisappear { seen.disappeared.append(row.id) }
                }
                Text("foot")
            }
        }
        harness.frame()
        let appeared = seen.ids
        let disappeared = seen.disappeared
        for _ in 0..<4 { harness.frame() }
        #expect(seen.disappeared == disappeared, "a steady frame dropped a row: \(seen.disappeared)")
        #expect(seen.ids == appeared, "a steady frame built a row again: \(seen.ids)")
        #expect(Set(seen.present.filter { $0.value == 1 }.keys) == heldIDs(in: harness.root))
    }

    /// The rows a list held were found again where they had been, so rows
    /// put in above the window gave the places the list held to other
    /// rows: the ones they held left and, still in view, were built again.
    @Test(arguments: [true, false])
    func rowsInsertedAboveTheWindowLeaveTheRowsInViewAsTheyWere(followed: Bool) {
        let scrolling = Scrolling()
        let seen = Appearances()
        let feed = Rows(ids: Array(0..<20))
        let harness = Harness {
            List(feed.ids.map(Row.init),
                 scroll: Binding(get: { scrolling.offset }, set: { scrolling.offset = $0 }),
                 visibleCount: 5) { row in
                Text("item \(row.id)")
                    .onAppear { seen.ids.append(row.id) }
                    .onDisappear { seen.disappeared.append(row.id) }
            }
        }
        harness.frame()
        scrolling.offset = 5
        let before = harness.frame()
        let shownBefore = shownIDs(in: before)
        let nodesBefore = rowNodesByID(in: harness.root)
        seen.disappeared.removeAll()

        feed.ids = [-2, -1] + feed.ids
        if followed { scrolling.offset += 2 }
        let after = harness.frame()

        let stayed = shownBefore.intersection(shownIDs(in: after))
        #expect(!stayed.isEmpty, "\(before) \(after)")
        #expect(seen.disappeared.allSatisfy { !stayed.contains($0) }, "\(seen.disappeared)")
        let nodesAfter = rowNodesByID(in: harness.root)
        for id in stayed {
            #expect(nodesAfter[id] === nodesBefore[id], "row \(id) was built again")
        }
        if followed {
            #expect(stayed == shownBefore, "the list kept its rows in view: \(after)")
        }
    }
}
