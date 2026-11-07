import Observation
import Testing
@testable import TerminalUI

// `.id(_:)` given a different value updated the view in place: the id sat on
// a modifier node whose child kept the structural path `.index(0)`, so the
// reconciler never saw identity change. Its `@TerminalState` kept its values,
// neither `onDisappear` nor `onAppear` ran, and its `.task` kept running. A
// view given a new id now leaves as an `if` branch that switches away does,
// and a new one is built in its place.

private final class Log {
    var entries: [String] = []
}

/// The work a view starts: it sleeps until cancelled, so a task that is never
/// cancelled costs nothing while the suite runs.
@MainActor
private func waitForCancellation() async {
    try? await Task.sleep(for: .seconds(3600))
}

@MainActor
private func taskNodes(in node: AttributeNode) -> [AttributeNode] {
    var found: [AttributeNode] = []
    if case .modifier(.task) = node.kind { found.append(node) }
    for child in node.children { found += taskNodes(in: child) }
    return found
}

@MainActor
private func renderedText(_ node: AttributeNode) -> String? {
    if case .primitive(.text(let spans)) = node.kind { return spans.map(\.text).joined() }
    return node.children.lazy.compactMap { renderedText($0) }.first
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
private func rows(of graph: AttributeGraph) -> [AttributeNode] {
    graph.root.flatMap(forEachNode(in:))?.children ?? []
}

private final class Counts {
    var seen: [String: Int] = [:]
    var bindings: [String: Binding<Int>] = [:]
}

private struct Counter: TerminalView {
    let name: String
    let counts: Counts
    @TerminalState var count = 0
    var body: some TerminalView {
        counts.seen[name] = count
        counts.bindings[name] = $count
        return Text("\(name) \(count)")
    }
}

private struct TaggedCounter: TerminalView {
    let tag: Int
    let counts: Counts
    var body: some TerminalView {
        VStack {
            Counter(name: "counter", counts: counts).id(tag)
        }
    }
}

private struct Logged: TerminalView {
    let tag: Int
    let log: Log
    var body: some TerminalView {
        VStack {
            Text("view \(tag)")
                .onAppear { log.entries.append("appear \(tag)") }
                .onDisappear { log.entries.append("disappear \(tag)") }
                .id(tag)
        }
    }
}

private struct Nested: TerminalView {
    let tag: Int
    let log: Log
    var body: some TerminalView {
        VStack {
            HStack {
                Text("a").onDisappear { log.entries.append("a \(tag)") }
                Text("b").onDisappear { log.entries.append("b \(tag)") }
            }
            .onDisappear { log.entries.append("outer \(tag)") }
            .id(tag)
        }
    }
}

private struct Working: TerminalView {
    let tag: Int
    var label = "work"
    var log: Log?
    var body: some TerminalView {
        VStack {
            Text("\(label) \(tag)")
                .onAppear { log?.entries.append("appear") }
                .onDisappear { log?.entries.append("disappear") }
                .task { await waitForCancellation() }
                .id(tag)
        }
    }
}

private struct Versioned: Identifiable {
    let id: Int
    var version = 0
}

private struct VersionedRows: TerminalView {
    let items: [Versioned]
    let counts: Counts
    var body: some TerminalView {
        VStack {
            ForEach(items) { item in
                Counter(name: "row \(item.id)", counts: counts).id(item.version)
            }
        }
    }
}

private struct Message: Identifiable {
    let id: Int
}

/// The shape Chat, Coder and Storybook use: each row tagged with its own key,
/// so `.scrollPosition(id:)` can name it.
private struct KeyedRows: TerminalView {
    let ids: [Int]
    let log: Log
    var body: some TerminalView {
        VStack {
            ForEach(ids.map(Message.init)) { message in
                Text("message \(message.id)")
                    .onAppear { log.entries.append("appear \(message.id)") }
                    .onDisappear { log.entries.append("disappear \(message.id)") }
                    .task { await waitForCancellation() }
                    .id(message.id)
            }
        }
    }
}

/// A composite whose body's root is the view `.id` names, beside state of
/// its own.
private struct RootTagged: TerminalView {
    let tag: Int
    let counts: Counts
    @TerminalState var outer = 0
    var body: some TerminalView {
        counts.seen["outer"] = outer
        counts.bindings["outer"] = $outer
        return Counter(name: "inner", counts: counts).id(tag)
    }
}

@Observable
private final class Document {
    var version = 0
    var tick = 0
}

private struct ModelTagged: TerminalView {
    let document: Document
    let counts: Counts
    var body: some TerminalView {
        VStack {
            Counter(name: "inner", counts: counts).id(document.version)
        }
    }
}

private struct Ticker: TerminalView {
    let tag: Int
    let document: Document
    let log: Log
    var body: some TerminalView {
        log.entries.append("body \(tag)")
        return Text("\(tag): \(document.tick)").task { await waitForCancellation() }
    }
}

private struct TaggedTicker: TerminalView {
    let tag: Int
    let document: Document
    let log: Log
    var body: some TerminalView {
        VStack {
            Ticker(tag: tag, document: document, log: log).id(tag)
        }
    }
}

@Suite("A view given a new id is a new view")
@MainActor
struct ExplicitIDTests {

    @Test func aNewIDResetsState() {
        let counts = Counts()
        let graph = AttributeGraph()
        graph.update(from: TaggedCounter(tag: 1, counts: counts))
        counts.bindings["counter"]?.wrappedValue = 7
        graph.update(from: TaggedCounter(tag: 1, counts: counts))
        #expect(counts.seen["counter"] == 7, "the same id keeps the view's state")

        graph.update(from: TaggedCounter(tag: 2, counts: counts))

        #expect(counts.seen["counter"] == 0, "a new id is a new view, with fresh state")
    }

    @Test func theOldViewDisappearsBeforeTheNewOneAppears() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Logged(tag: 1, log: log))
        log.entries.removeAll()

        graph.update(from: Logged(tag: 2, log: log))

        #expect(log.entries == ["disappear 1", "appear 2"])
    }

    @Test func everyViewUnderTheOldIDDisappearsInnermostFirst() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Nested(tag: 1, log: log))

        graph.update(from: Nested(tag: 2, log: log))

        #expect(log.entries == ["a 1", "b 1", "outer 1"])
    }

    @Test func aNewIDRestartsTheTask() {
        let graph = AttributeGraph()
        graph.update(from: Working(tag: 1))
        guard let old = graph.root.flatMap(taskNodes(in:))?.first, let running = old.lifecycleTask else {
            Issue.record("the view starts no task")
            return
        }

        graph.update(from: Working(tag: 2))

        #expect(running.isCancelled, "the old view's work must stop")
        #expect(old.lifecycleTask == nil)
        let fresh = graph.root.flatMap(taskNodes(in:)) ?? []
        #expect(fresh.count == 1)
        #expect(fresh.first !== old, "a new id builds a new node")
        #expect(fresh.first?.lifecycleTask?.isCancelled == false, "the new view's task runs")
    }

    @Test func theSameIDLeavesTheNodeInPlace() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: Working(tag: 1, label: "before", log: log))
        guard let node = graph.root.flatMap(taskNodes(in:))?.first, let running = node.lifecycleTask else {
            Issue.record("the view starts no task")
            return
        }
        log.entries.removeAll()

        graph.update(from: Working(tag: 1, label: "after", log: log))

        #expect(graph.root.flatMap(taskNodes(in:))?.first === node)
        #expect(log.entries.isEmpty, "\(log.entries)")
        #expect(!running.isCancelled)
        #expect(graph.root.flatMap(renderedText) == "after 1")
    }

    @Test func aNewIDInAForEachRowResetsThatRowAlone() {
        let counts = Counts()
        let graph = AttributeGraph()
        var items = [Versioned(id: 1), Versioned(id: 2), Versioned(id: 3)]
        graph.update(from: VersionedRows(items: items, counts: counts))
        counts.bindings["row 1"]?.wrappedValue = 7
        counts.bindings["row 2"]?.wrappedValue = 7
        graph.update(from: VersionedRows(items: items, counts: counts))
        let before = rows(of: graph)

        items[1].version += 1
        graph.update(from: VersionedRows(items: items, counts: counts))

        #expect(counts.seen["row 1"] == 7, "a row whose id held keeps its state")
        #expect(counts.seen["row 2"] == 0, "the row given a new id starts over")
        let after = rows(of: graph)
        #expect(after.count == 3)
        #expect(zip(before, after).allSatisfy { $0 === $1 }, "the ForEach's own rows stay")
    }

    @Test func aRowTaggedWithItsOwnKeyIsUntouchedByAnAppendOrAReorder() {
        let log = Log()
        let graph = AttributeGraph()
        graph.update(from: KeyedRows(ids: [1, 2, 3], log: log))
        func content() -> [String: AttributeNode] {
            Dictionary(uniqueKeysWithValues: (graph.root.flatMap(taskNodes(in:)) ?? []).compactMap { node in
                renderedText(node).map { ($0, node) }
            })
        }
        let before = content()
        let running = before.values.compactMap(\.lifecycleTask)
        #expect(before.count == 3 && running.count == 3)
        log.entries.removeAll()

        graph.update(from: KeyedRows(ids: [1, 2, 3, 4], log: log))
        #expect(log.entries == ["appear 4"], "only the row added appears")

        log.entries.removeAll()
        graph.update(from: KeyedRows(ids: [4, 3, 1, 2], log: log))
        #expect(log.entries.isEmpty, "\(log.entries)")

        let after = content()
        for (text, node) in before {
            #expect(after[text] === node, "\(text) was rebuilt")
        }
        #expect(running.allSatisfy { !$0.isCancelled })
    }

    @Test func aNewIDAtABodysRootResetsTheViewItNamesAlone() {
        let counts = Counts()
        let graph = AttributeGraph()
        graph.update(from: RootTagged(tag: 1, counts: counts))
        counts.bindings["outer"]?.wrappedValue = 7
        counts.bindings["inner"]?.wrappedValue = 7
        graph.update(from: RootTagged(tag: 1, counts: counts))
        #expect(counts.seen["outer"] == 7 && counts.seen["inner"] == 7)

        graph.update(from: RootTagged(tag: 2, counts: counts))

        #expect(counts.seen["inner"] == 0, "the view `.id` is applied to starts over")
        #expect(counts.seen["outer"] == 7, "the composite whose body it is keeps its own state")
    }

    @Test func aNewIDFromAnObservableResetsStateOnDrain() {
        let counts = Counts()
        let document = Document()
        let graph = AttributeGraph()
        graph.update(from: ModelTagged(document: document, counts: counts))
        counts.bindings["inner"]?.wrappedValue = 7
        graph.update(from: ModelTagged(document: document, counts: counts))
        #expect(counts.seen["inner"] == 7)

        document.version += 1
        graph.drain()

        #expect(counts.seen["inner"] == 0)
    }

    @Test func aReplacedViewDoesNotRunAgainForWhatItRead() {
        let log = Log()
        let document = Document()
        let graph = AttributeGraph()
        graph.update(from: TaggedTicker(tag: 1, document: document, log: log))
        guard let old = graph.root.flatMap(taskNodes(in:))?.first else {
            Issue.record("the view starts no task")
            return
        }

        graph.update(from: TaggedTicker(tag: 2, document: document, log: log))
        #expect(old.lifecycleTask == nil)
        log.entries.removeAll()

        document.tick += 1
        graph.drain()

        #expect(log.entries == ["body 2"], "\(log.entries)")
        #expect(old.lifecycleTask == nil, "a view that left started its task again")
    }
}
