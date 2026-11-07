import Observation
import Testing
@testable import TerminalUI

// A ForEach whose data lost an element dropped that row's node without
// tearing it down, the one removal in the graph that did: `onDisappear` ran
// for nothing in the row, and a `.task` started in it was never cancelled,
// so it ran, and woke the render loop, for as long as the app did. A row a
// ForEach drops now leaves as an `if` branch that switches away does.

private final class Log {
    var entries: [String] = []
}

private struct Item: Identifiable {
    let id: Int
}

/// The work a row starts: it sleeps until cancelled, so a task that is never
/// cancelled costs nothing while the suite runs.
@MainActor
private func waitForCancellation() async {
    try? await Task.sleep(for: .seconds(3600))
}

@MainActor
private func forEachNode(in node: AttributeNode) -> AttributeNode? {
    if GraphRenderer.isStructuralLayout(node) { return node }
    for child in node.children {
        if let found = forEachNode(in: child) { return found }
    }
    return nil
}

@MainActor
private func taskNodes(in node: AttributeNode) -> [AttributeNode] {
    var found: [AttributeNode] = []
    if case .modifier(.task) = node.kind { found.append(node) }
    for child in node.children { found += taskNodes(in: child) }
    return found
}

@MainActor
private func rows(of graph: AttributeGraph) -> [AttributeNode] {
    graph.root.flatMap(forEachNode(in:))?.children ?? []
}

private struct Logged: TerminalView {
    let ids: [Int]
    let log: Log
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Item.init)) { item in
                Text("row \(item.id)")
                    .onAppear { log.entries.append("appear \(item.id)") }
                    .onDisappear { log.entries.append("disappear \(item.id)") }
            }
        }
    }
}

private struct Nested: TerminalView {
    let ids: [Int]
    let log: Log
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Item.init)) { item in
                HStack {
                    Text("a").onDisappear { log.entries.append("a \(item.id)") }
                    Text("b").onDisappear { log.entries.append("b \(item.id)") }
                }
                .onDisappear { log.entries.append("row \(item.id)") }
            }
        }
    }
}

private struct Working: TerminalView {
    let ids: [Int]
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Item.init)) { item in
                VStack {
                    Text("inner \(item.id)").task { await waitForCancellation() }
                }
                .task { await waitForCancellation() }
            }
        }
    }
}

private struct KeyedLogged: TerminalView {
    let ids: [Int]
    let log: Log
    var body: some TerminalView {
        VStack {
            ForEachWithID(ids, id: \.self) { id in
                Text("row \(id)")
                    .onAppear { log.entries.append("appear \(id)") }
                    .onDisappear { log.entries.append("disappear \(id)") }
            }
        }
    }
}

private struct KeyedWorking: TerminalView {
    let ids: [Int]
    var body: some TerminalView {
        VStack {
            ForEachWithID(ids, id: \.self) { id in
                VStack {
                    Text("inner \(id)").task { await waitForCancellation() }
                }
                .task { await waitForCancellation() }
            }
        }
    }
}

private final class Counts {
    var seen: [Int: Int] = [:]
    var bindings: [Int: Binding<Int>] = [:]
}

private struct Counter: TerminalView {
    let id: Int
    let counts: Counts
    @TerminalState var count = 0
    var body: some TerminalView {
        counts.seen[id] = count
        counts.bindings[id] = $count
        return Text("count \(count)")
    }
}

private struct Counters: TerminalView {
    let ids: [Int]
    let counts: Counts
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Item.init)) { item in Counter(id: item.id, counts: counts) }
        }
    }
}

@Observable
private final class Feed {
    var tick = 0
}

private struct TickRow: TerminalView {
    let id: Int
    let feed: Feed
    var body: some TerminalView {
        Text("\(id): \(feed.tick)").task { await waitForCancellation() }
    }
}

private struct Ticks: TerminalView {
    let ids: [Int]
    let feed: Feed
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Item.init)) { item in TickRow(id: item.id, feed: feed) }
        }
    }
}

@Suite("A row a ForEach drops runs its onDisappear and stops its task")
@MainActor
struct ForEachLifecycleTests {

    @Test func removingOneRowRunsItsOnDisappearAlone() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Logged(ids: [1, 2, 3], log: log))
        log.entries.removeAll()

        graph.update(from: Logged(ids: [1, 3], log: log))

        #expect(log.entries == ["disappear 2"])
    }

    @Test func everyViewInARemovedRowDisappearsInnermostFirst() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Nested(ids: [1, 2, 3], log: log))

        graph.update(from: Nested(ids: [1, 3], log: log))

        #expect(log.entries == ["a 2", "b 2", "row 2"])
    }

    @Test func aRemovedRowsTasksAreCancelled() {
        let graph = AttributeGraph()
        graph.update(from: Working(ids: [1, 2, 3]))
        let removed = taskNodes(in: rows(of: graph)[1])
        let running = removed.compactMap(\.lifecycleTask)
        #expect(removed.count == 2 && running.count == 2, "the row and the view inside it each start one")

        graph.update(from: Working(ids: [1, 3]))

        #expect(running.allSatisfy { $0.isCancelled }, "a removed row's work must stop")
        #expect(removed.allSatisfy { $0.lifecycleTask == nil })
        #expect(rows(of: graph).flatMap(taskNodes(in:)).allSatisfy { $0.lifecycleTask?.isCancelled == false },
                "the rows that stay keep working")
    }

    @Test func aRowForEachWithIDDropsRunsItsOnDisappear() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: KeyedLogged(ids: [1, 2, 3], log: log))
        log.entries.removeAll()

        graph.update(from: KeyedLogged(ids: [1, 3], log: log))

        #expect(log.entries == ["disappear 2"])
    }

    @Test func aRowForEachWithIDDropsHasItsTasksCancelled() {
        let graph = AttributeGraph()
        graph.update(from: KeyedWorking(ids: [1, 2, 3]))
        let removed = taskNodes(in: rows(of: graph)[1])
        let running = removed.compactMap(\.lifecycleTask)
        #expect(running.count == 2)

        graph.update(from: KeyedWorking(ids: [1, 3]))

        #expect(running.allSatisfy { $0.isCancelled })
        #expect(removed.allSatisfy { $0.lifecycleTask == nil })
    }

    @Test func aReorderRemovesNothingAndKeepsEveryNode() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Logged(ids: [1, 2, 3], log: log))
        let before = rows(of: graph)
        log.entries.removeAll()

        graph.update(from: Logged(ids: [3, 1, 2], log: log))

        #expect(log.entries.isEmpty, "\(log.entries)")
        let after = rows(of: graph)
        #expect(after.count == 3)
        #expect(after[0] === before[2] && after[1] === before[0] && after[2] === before[1])
    }

    @Test func aRowAddedBackStartsWithFreshState() {
        let counts = Counts()
        let graph = AttributeGraph()
        graph.update(from: Counters(ids: [1, 2, 3], counts: counts))
        counts.bindings[2]?.wrappedValue = 7
        graph.update(from: Counters(ids: [1, 2, 3], counts: counts))
        #expect(counts.seen[2] == 7)

        graph.update(from: Counters(ids: [1, 3], counts: counts))
        graph.update(from: Counters(ids: [1, 2, 3], counts: counts))

        #expect(counts.seen[2] == 0, "a row that left takes its state with it")
    }

    @Test func aNewIDInTheSamePlaceDisappearsTheOldRowFirst() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Logged(ids: [1], log: log))
        log.entries.removeAll()

        graph.update(from: Logged(ids: [2], log: log))

        #expect(log.entries == ["disappear 1", "appear 2"])
    }

    /// The row still had its parent, held weakly by a ForEach that is still
    /// in the tree, so it passed for attached: the drain after the update
    /// that removed it ran its body for what it read, and started its task
    /// again.
    @Test func aRemovedRowDoesNotRunAgainForWhatItRead() {
        let feed = Feed()
        let graph = AttributeGraph()
        graph.update(from: Ticks(ids: [1, 2, 3], feed: feed))
        guard let removed = taskNodes(in: rows(of: graph)[1]).first else {
            Issue.record("the row starts no task")
            return
        }

        feed.tick += 1
        graph.update(from: Ticks(ids: [1, 3], feed: feed))
        #expect(removed.lifecycleTask == nil)
        let evaluated = graph.bodyEvaluationCount
        graph.drain()

        #expect(graph.bodyEvaluationCount == evaluated, "a row that left ran its body again")
        #expect(removed.lifecycleTask == nil, "a row that left started its task again")
    }
}
