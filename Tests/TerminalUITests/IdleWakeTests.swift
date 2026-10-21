#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Observation
import Testing
@testable import TerminalUI

// An app with nothing to do sleeps until something happens: the frame loop
// waits on a `WakeSignal` that every source of work raises, and the input
// task blocks in one `poll()` on stdin, the resize pipe and the shutdown
// pipe, with no timeout. Polling for work on a timer cost an idle
// `.onDemand` app — documented as zero CPU when idle — a wakeup every
// millisecond, and every app one every 16ms for a resize.

/// Whether `wait` finishes within `limit`.
private func finishes(within limit: Duration, _ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

@Observable
private final class Counter {
    var value = 0
}

private struct CounterView: TerminalView {
    let counter: Counter
    var body: some TerminalView { Text("\(counter.value)") }
}

@Suite("An idle app sleeps until something happens")
struct IdleWakeTests {

    @Test func aWakeBeforeTheWaitIsKept() async {
        let signal = WakeSignal()
        signal.wake()
        #expect(await finishes(within: .seconds(1)) { await signal.wait() })
    }

    @Test func aWaitSleepsUntilAWake() async {
        let signal = WakeSignal()
        let waiter = Task { await signal.wait() }
        try? await Task.sleep(for: .milliseconds(20))
        signal.wake()
        #expect(await finishes(within: .seconds(1)) { await waiter.value })
    }

    @Test func wakesBeforeOneWaitAreOneWake() async {
        let signal = WakeSignal()
        signal.wake()
        signal.wake()
        await signal.wait()
        #expect(!(await finishes(within: .milliseconds(150)) { await signal.wait() }))
    }

    @Test func anEventWakesTheLoop() async {
        let signal = WakeSignal()
        let queue = EventQueue(wake: signal)
        queue.push(.timer("tick"))
        #expect(await finishes(within: .seconds(1)) { await signal.wait() })
    }

    @Test @MainActor func aChangeToObservedStateWakesTheLoop() async {
        let signal = WakeSignal()
        let counter = Counter()
        let graph = AttributeGraph(wake: signal)
        graph.update(from: CounterView(counter: counter))
        counter.value = 1
        #expect(await finishes(within: .seconds(1)) { await signal.wait() })
    }
}

@Suite("The input task blocks until there is input, a resize or a shutdown")
struct InputActivityTests {

    private struct Pipes {
        let input: SelfPipe
        let resize: SelfPipe
        let shutdown: SelfPipe

        init() throws {
            input = try SelfPipe()
            resize = try SelfPipe()
            shutdown = try SelfPipe()
        }

        func wait() -> InputActivity {
            StdinByteSource.waitForActivity(input: input.read, resize: resize.read, shutdown: shutdown.read)
        }

        func close() {
            input.close()
            resize.close()
            shutdown.close()
        }
    }

    @Test func withNothingToReadItWaitsPastAnyTimeout() async throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        let waiter = Task.detached { pipes.wait() }
        try? await Task.sleep(for: .milliseconds(300))
        pipes.shutdown.signal()
        #expect(await waiter.value == .shutdown, "it returned before the shutdown was sent")
    }

    @Test func aResizeIsReportedAndConsumed() throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        pipes.resize.signal()
        pipes.resize.signal()
        #expect(pipes.wait() == .resize)
        pipes.input.signal()
        #expect(pipes.wait() == .input, "both resize bytes are one resize")
    }

    @Test func shutdownWinsOverEverythingElse() throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        pipes.input.signal()
        pipes.resize.signal()
        pipes.shutdown.signal()
        #expect(pipes.wait() == .shutdown)
    }
}
