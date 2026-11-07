import Observation
import Testing
@testable import TerminalUI

// A tree's rows were known by their place among the rows shown, so a node
// that opened or closed gave every row below it a new identity: each was
// built again, lost its state, ran onDisappear and onAppear, and had its
// task cancelled and started over. A row is known by its item's path from
// the root now, as a row of SwiftUI's OutlineGroup is.

private struct Item: Identifiable {
    let id: Int
    var children: [Item]? = nil
}

/// Root 0 over 1, 2 and 3, with 1 over 10 and 11. Only the root starts open.
private let fixture = [
    Item(id: 0, children: [
        Item(id: 1, children: [Item(id: 10), Item(id: 11)]),
        Item(id: 2),
        Item(id: 3),
    ]),
]

/// The work a row starts: it sleeps until cancelled, so a task that is never
/// cancelled costs nothing while the suite runs.
@MainActor
private func waitForCancellation() async {
    try? await Task.sleep(for: .seconds(3600))
}

/// What the rows did, and the state each holds, found by the node that holds
/// it: an item the tree shows twice is two rows with one id.
private final class Probe {
    var log: [String] = []
    var counters: [ObjectIdentifier: (count: Int, binding: Binding<Int>)] = [:]

    /// The count held by the row view under `row`, among the nodes still
    /// in the tree.
    func counter(under row: AttributeNode) -> (count: Int, binding: Binding<Int>)? {
        if let found = counters[ObjectIdentifier(row)] { return found }
        for child in row.children {
            if let found = counter(under: child) { return found }
        }
        return nil
    }
}

private struct ProbedRow: TerminalView {
    let id: Int
    let probe: Probe
    @TerminalState var count = 0
    var body: some TerminalView {
        if let node = GraphContext.currentNode {
            probe.counters[ObjectIdentifier(node)] = (count, $count)
        }
        return Text("item \(id) count \(count)")
            .onAppear { probe.log.append("appear \(id)") }
            .onDisappear { probe.log.append("disappear \(id)") }
            .task { await waitForCancellation() }
    }
}

@Observable
private final class Selecting {
    var selected: Int? = nil
}

@MainActor
private final class Screen<Content: TerminalView> {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    var root: AttributeNode { graph.root! }

    @discardableResult
    func frame() -> [String] {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { graph.update(from: content) }
        var buffer = CellBuffer(width: 30, height: 20)
        let rect = Rect(x: 0, y: 0, width: 30, height: 20)
        Layout.measureAndPlace(graph: root, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: root)
        return buffer.rowTexts
    }

    /// Focuses the tree, as a first Tab does.
    func focus() {
        frame()
        engine.focusNext()
    }

    @discardableResult
    func press(_ key: Key) -> [String] {
        #expect(engine.routeKeyEvent(KeyEvent(key: key), root: root), "\(key) was not handled")
        return frame()
    }

    /// The row nodes the tree's window holds, in order.
    var rows: [AttributeNode] {
        treeWindow(in: root).map(AttributeGraph.rowNodes(in:)) ?? []
    }
}

@MainActor
private func taskNodes(in node: AttributeNode) -> [AttributeNode] {
    var found: [AttributeNode] = []
    if case .modifier(.task) = node.kind { found.append(node) }
    for child in node.children { found += taskNodes(in: child) }
    return found
}

@MainActor
private func treeWindow(in node: AttributeNode) -> AttributeNode? {
    if node.rowWindowRebuilder != nil || node.geometryRebuilder != nil { return node }
    for child in node.children {
        if let found = treeWindow(in: child) { return found }
    }
    return nil
}

@MainActor
private func probedTree(_ data: [Item], _ probe: Probe, visibleCount: Int = 10,
                        selection: Binding<Int?>? = nil) -> some TerminalView {
    TreeView(data, children: \.children, selection: selection, visibleCount: visibleCount) { item in
        ProbedRow(id: item.id, probe: probe)
    }
}

@Suite("A tree row is its item's path, not its place among the rows")
@MainActor
struct TreeViewIdentityTests {

    @Test func collapsingANodeDisappearsOnlyTheRowsItHid() {
        let probe = Probe()
        let screen = Screen(probedTree(fixture, probe))
        screen.focus()
        screen.press(.down)
        let open = screen.press(.right)
        #expect(open.contains { $0.contains("item 11") }, "\(open)")
        probe.log.removeAll()

        let closed = screen.press(.left)

        #expect(!closed.contains { $0.contains("item 10") }, "\(closed)")
        #expect(probe.log.sorted() == ["disappear 10", "disappear 11"], "\(probe.log)")
    }

    @Test func theRowsBelowANodeKeepTheirIDsWhenItOpens() {
        func ids(expanded: Set<Int>) -> [Int: AnyHashable] {
            let rows = TreeViewHelpers.flattenedRows(data: fixture, childrenKeyPath: \.children,
                                                     expandedIDs: Set(expanded.map(AnyHashableID.init)))
            var found: [Int: AnyHashable] = [:]
            for index in rows.indices where [2, 3].contains(rows[index].item.id) {
                found[rows[index].item.id] = AnyHashable(TreeViewHelpers.rowID(at: index, in: rows))
            }
            return found
        }
        let closed = ids(expanded: [0])
        let open = ids(expanded: [0, 1])
        #expect(closed.count == 2)
        #expect(closed == open)
    }

    @Test func anItemUnderTwoParentsIsTwoRows() {
        let shared = Item(id: 5)
        let data = [Item(id: 1, children: [shared]), Item(id: 2, children: [shared])]
        let probe = Probe()
        let screen = Screen(probedTree(data, probe))
        let drawn = screen.frame()
        let before = screen.rows
        #expect(before.count == 4, "\(drawn)")
        guard before.count == 4 else { return }
        #expect(before[1] !== before[3], "one item under two parents is two rows")
        screen.focus()
        let underB = before[3]
        probe.counter(under: underB)?.binding.wrappedValue = 7
        screen.frame()
        #expect(probe.counter(under: underB)?.count == 7)
        probe.log.removeAll()

        screen.press(.left)

        #expect(probe.log == ["disappear 5"], "\(probe.log)")
        let after = screen.rows
        #expect(after.count == 3)
        #expect(after.last === underB, "the row under B stays as it was")
        #expect(probe.counter(under: underB)?.count == 7)
    }

    @Test func leftFromAChildOfADuplicatedParentSelectsItsOwnParent() {
        let parent = Item(id: 7, children: [Item(id: 8)])
        let data = [Item(id: 1, children: [parent]), Item(id: 2, children: [parent])]
        let selecting = Selecting()
        let probe = Probe()
        let screen = Screen(probedTree(data, probe, selection: Binding(get: { selecting.selected },
                                                                         set: { selecting.selected = $0 })))
        screen.focus()
        screen.press(.down)
        let open = screen.press(.right)
        #expect(open.filter { $0.contains("item 8") }.count == 2,
                "opening 7 opens it under both parents: \(open)")
        screen.press(.end)
        #expect(selecting.selected == 8)

        screen.press(.left)
        #expect(selecting.selected == 7)
        screen.press(.up)

        #expect(selecting.selected == 2, "Left went to the other parent's 7")
    }

    @Test func aRowBelowAnExpandingNodeKeepsItsNodeStateAndTask() {
        let probe = Probe()
        let screen = Screen(probedTree(fixture, probe))
        screen.focus()
        let before = screen.rows
        #expect(before.count == 4)
        guard before.count == 4 else { return }
        let two = before[2]
        probe.counter(under: two)?.binding.wrappedValue = 7
        screen.frame()
        #expect(probe.counter(under: two)?.count == 7)
        let task = taskNodes(in: two).first?.lifecycleTask
        #expect(task != nil, "row 2 starts its task")
        probe.log.removeAll()

        screen.press(.down)
        let open = screen.press(.right)

        #expect(open.contains { $0.contains("item 11") }, "\(open)")
        let after = screen.rows
        #expect(after.count == 6)
        #expect(after.count == 6 && after[4] === two, "row 2 is the node it was")
        #expect(probe.counter(under: two)?.count == 7, "row 2 kept its state")
        #expect(probe.log.sorted() == ["appear 10", "appear 11"], "\(probe.log)")
        let still = taskNodes(in: two).first?.lifecycleTask
        #expect(still != nil && still == task, "row 2's task is the one it started")
        #expect(task?.isCancelled == false)
    }

    @Test func expandingANodeNearTheWindowEdgeDisappearsOnlyRowsPushedOut() {
        let probe = Probe()
        let screen = Screen(probedTree(fixture, probe, visibleCount: 5))
        screen.focus()
        let before = screen.rows
        #expect(before.count == 4)
        probe.log.removeAll()

        screen.press(.down)
        let open = screen.press(.right)

        #expect(open.contains { $0.contains("item 11") }, "\(open)")
        #expect(!open.contains { $0.contains("item 2 ") }, "row 2 is pushed out of view: \(open)")
        let after = screen.rows
        #expect(after.count >= 4)
        guard after.count >= 4, before.count == 4 else { return }
        #expect(after[0] === before[0] && after[1] === before[1], "the rows still on screen stay")
        #expect(probe.log.filter { $0.hasPrefix("appear") }.sorted() == ["appear 10", "appear 11"],
                "only the rows that came into view appear: \(probe.log)")
        let gone = probe.log.filter { $0.hasPrefix("disappear") }
        #expect(gone.allSatisfy { $0 == "disappear 2" || $0 == "disappear 3" }, "\(probe.log)")
    }
}
