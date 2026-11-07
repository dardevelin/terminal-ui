import Foundation
import Observation
import Synchronization
import Testing
@testable import TerminalUI

// What Observation itself cannot report, read from its source
// (stdlib/public/Observation: ObservationTracking.swift,
// ObservationRegistrar.swift):
//
// - `withObservationTracking` runs `apply` against a thread-local access
//   list, and `ObservationRegistrar.access` only appends to that list. The
//   willSet observers are registered (`_installTracking` →
//   `registerTracking`) after `apply` returns. A change another thread makes
//   while `apply` runs meets no observer at all.
// - `withMutation` calls the registered willSet observers on the mutating
//   thread, before the store. A main actor that runs the body in between
//   reads the old value and registers fresh observers, which that store
//   never reaches.
//
// Neither window can be closed through public API: the registrar exposes no
// version, and the access list holds no values and cannot be reached. So
// the contract is to change observed state on the main actor, and these
// tests pin what happens to a change that does not. The graph-level ones
// state the stale result as a known issue, so a toolchain that closes a
// window turns them red rather than leaving them asserting the old gap.
//
// The second thread is a Foundation `Thread`, not a task: the main actor
// blocks on it, and on the one-thread cooperative pool verify.py runs, a
// task it waited on could never be scheduled.

private final class Counter: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storage = Mutex(0)

    var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return storage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) {
                storage.withLock { $0 = newValue }
            }
        }
    }

    /// Sets `newValue` as `value`'s setter does, but holds between
    /// Observation's notice and the store: signals `noticed`, then waits for
    /// `resume`.
    func set(_ newValue: Int, pausingOn noticed: DispatchSemaphore, until resume: DispatchSemaphore) {
        registrar.withMutation(of: self, keyPath: \.value) {
            noticed.signal()
            resume.wait()
            storage.withLock { $0 = newValue }
        }
    }
}

/// What an `onChange` saw, readable from the thread that asks after it.
private final class Seen<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ initial: Value) { storage = Mutex(initial) }
    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Runs `work` on a thread of its own and returns once it has finished.
private func onAnotherThreadAndWait(_ work: @escaping @Sendable () -> Void) {
    let finished = startThread(work)
    finished.wait()
}

/// Starts `work` on a thread of its own; the semaphore is signalled when it
/// has finished.
private func startThread(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        work()
        finished.signal()
    }
    thread.name = "observation-window-writer"
    thread.start()
    return finished
}

/// Reads the counter, and the first time it reads 0, has another thread set
/// it to 1 before the body returns.
private struct ChangedWhileItsBodyRuns: TerminalView {
    let counter: Counter
    var body: some TerminalView {
        let read = counter.value
        if read == 0 {
            onAnotherThreadAndWait { counter.value = 1 }
        }
        return Text("value \(read)")
    }
}

private struct CounterView: TerminalView {
    let counter: Counter
    var body: some TerminalView {
        Text("value \(counter.value)")
    }
}

@MainActor
private func firstLine(of graph: AttributeGraph) -> String {
    let width = 20
    var buffer = CellBuffer(width: width, height: 2)
    guard let root = graph.root else { return "" }
    let rect = Rect(x: 0, y: 0, width: width, height: 2)
    Layout.measureAndPlace(graph: root, in: rect)
    GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
    return (0..<width).map { String(buffer[$0, 0].character) }.joined()
        .trimmingCharacters(in: .whitespaces)
}

@Suite("Observation tells a body nothing of a change made while it runs")
@MainActor
struct ObservationWindowTests {

    @Test func aChangeOnAnotherThreadWhileApplyRunsMeetsNoObserver() {
        let counter = Counter()
        let fired = Seen(false)

        withObservationTracking {
            _ = counter.value
            onAnotherThreadAndWait { counter.value = 1 }
        } onChange: {
            fired.value = true
        }

        #expect(!fired.value)
        #expect(counter.value == 1)

        counter.value = 2
        #expect(fired.value,
                "the observer exists once apply has returned")
    }

    @Test func onChangeRunsBeforeTheNewValueIsStored() {
        let counter = Counter()
        let seen = Seen<Int?>(nil)

        withObservationTracking {
            _ = counter.value
        } onChange: {
            seen.value = counter.value
        }
        counter.value = 5

        #expect(seen.value == 0)
        #expect(counter.value == 5)
    }

    @Test func aChangeOnAnotherThreadWhileTheBodyRunsLeavesTheViewStale() {
        let counter = Counter()
        let graph = AttributeGraph()
        graph.update(from: ChangedWhileItsBodyRuns(counter: counter))

        #expect(firstLine(of: graph) == "value 0")
        #expect(counter.value == 1)
        withKnownIssue("Observation installs a body's observers only when the body returns") {
            let reported = graph.hasDirtyNodes
            #expect(reported)
        }

        counter.value = 2
        #expect(graph.hasDirtyNodes, "the observers the body left are in place")
        #expect(graph.drain())
        #expect(firstLine(of: graph) == "value 2")
        #expect(!graph.hasDirtyNodes)
    }

    @Test func aStoreLandingAfterTheBodyReranIsNeverReported() {
        let counter = Counter()
        let graph = AttributeGraph()
        graph.update(from: CounterView(counter: counter))
        #expect(firstLine(of: graph) == "value 0")

        let noticed = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = startThread {
            counter.set(1, pausingOn: noticed, until: resume)
        }
        noticed.wait()

        #expect(graph.hasDirtyNodes, "onChange fired at willSet")
        #expect(graph.drain())
        #expect(firstLine(of: graph) == "value 0", "the body re-read the old value")

        resume.signal()
        finished.wait()

        #expect(counter.value == 1)
        #expect(firstLine(of: graph) == "value 0")
        withKnownIssue("Observation reports a change before the new value is stored") {
            let reported = graph.hasDirtyNodes
            #expect(reported)
        }
    }
}
