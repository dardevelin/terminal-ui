import Testing
@testable import TerminalUI

// `.task` owns work for as long as the view is on screen: started when it
// appears, cancelled when it leaves, restarted when its id changes. The handle
// lives on the node rather than in the modifier because `body` rebuilds the
// modifier every frame — a handle held by the modifier would be a different one
// by the time anything came to cancel it, and the work would outlive its view.

@MainActor
private func taskNode(in node: AttributeNode) -> AttributeNode? {
    if case .modifier(.task) = node.kind { return node }
    for child in node.children {
        if let found = taskNode(in: child) { return found }
    }
    return nil
}

private struct Ticking: TerminalView {
    let show: Bool

    var body: some TerminalView {
        VStack {
            if show {
                Text("working").task { while !Task.isCancelled { await Task.yield() } }
            } else {
                Text("gone")
            }
        }
    }
}

private struct Keyed: TerminalView {
    let id: Int

    var body: some TerminalView {
        Text("item \(id)").task(id: id) { while !Task.isCancelled { await Task.yield() } }
    }
}

@Suite("`.task` — work owned by a view")
@MainActor
struct TaskModifierTests {

    @Test("the work starts when the view appears")
    func startsOnAppear() {
        let graph = AttributeGraph()
        graph.update(from: Ticking(show: true))

        let node = taskNode(in: graph.root!)
        #expect(node != nil, "the modifier reaches the graph")
        #expect(node?.lifecycleTask != nil, "and brings its work with it")
    }

    @Test("the same view on a later frame does not start a second task")
    func doesNotRestartOnEveryFrame() {
        let graph = AttributeGraph()
        graph.update(from: Ticking(show: true))
        let first = taskNode(in: graph.root!)?.lifecycleTask

        graph.update(from: Ticking(show: true))
        let second = taskNode(in: graph.root!)?.lifecycleTask

        #expect(first == second, "`body` runs every frame; the work does not")
    }

    @Test("the work is cancelled when the view leaves")
    func cancelsOnDisappear() {
        let graph = AttributeGraph()
        graph.update(from: Ticking(show: true))
        guard let running = taskNode(in: graph.root!)?.lifecycleTask else {
            Issue.record("no task started")
            return
        }

        graph.update(from: Ticking(show: false))

        #expect(running.isCancelled,
                "a screen the user navigated away from must not keep working")
        #expect(taskNode(in: graph.root!) == nil)
    }

    @Test("a changed id restarts the work")
    func restartsOnIDChange() {
        let graph = AttributeGraph()
        graph.update(from: Keyed(id: 1))
        guard let first = taskNode(in: graph.root!)?.lifecycleTask else {
            Issue.record("no task started")
            return
        }

        graph.update(from: Keyed(id: 2))
        let second = taskNode(in: graph.root!)?.lifecycleTask

        #expect(first.isCancelled, "the work for the old id stops")
        #expect(second != nil)
        #expect(first != second, "and the new id gets its own")
    }

    @Test("an unchanged id leaves the work alone")
    func sameIDKeepsRunning() {
        let graph = AttributeGraph()
        graph.update(from: Keyed(id: 7))
        let first = taskNode(in: graph.root!)?.lifecycleTask

        graph.update(from: Keyed(id: 7))
        let second = taskNode(in: graph.root!)?.lifecycleTask

        #expect(first == second)
        #expect(first?.isCancelled == false)
    }
}
