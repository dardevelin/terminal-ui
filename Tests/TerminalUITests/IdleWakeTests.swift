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

@Suite("The input task blocks until there is input, a resize, a hang-up or a shutdown")
struct InputActivityTests {

    private struct Pipes {
        let input: SelfPipe
        let resize: SelfPipe
        let terminate: SelfPipe
        let shutdown: SelfPipe

        init() throws {
            input = try SelfPipe()
            resize = try SelfPipe()
            terminate = try SelfPipe()
            shutdown = try SelfPipe()
        }

        func wait(input: Int32? = nil) -> InputActivity {
            StdinByteSource.waitForActivity(input: input ?? self.input.read, resize: resize.read,
                                            terminate: terminate.read, shutdown: shutdown.read)
        }

        func close() {
            input.close()
            resize.close()
            terminate.close()
            shutdown.close()
        }
    }

    // macOS reports a hung-up terminal readable as well as hung up, and a
    // read of it returns nothing: taken for input, it woke the task at once,
    // forever.
    @Test func aHungUpTerminalIsAHangUpNotInput() throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        let terminal = try #require(PseudoTerminal())
        defer { terminal.closeReplica() }
        terminal.hangUp()
        #expect(pipes.wait(input: terminal.replica) == .hangUp)
    }

    @Test func aLiveTerminalWithALineToReadIsInput() throws {
        let pipes = try Pipes()
        defer { pipes.close() }
        let terminal = try #require(PseudoTerminal())
        defer {
            terminal.hangUp()
            terminal.closeReplica()
        }
        terminal.typeLine("x")
        #expect(pipes.wait(input: terminal.replica) == .input)
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
