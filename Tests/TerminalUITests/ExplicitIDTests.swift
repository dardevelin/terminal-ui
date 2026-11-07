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
}
