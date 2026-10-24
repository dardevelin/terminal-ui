import Foundation
import Testing
@testable import TerminalUI

// Work that blocks in the kernel runs on a thread of its own. As a task it
// held one of the cooperative pool's threads — a thread per core — until it
// returned: the input loop held one for the app's whole life, and where the
// pool was a thread or two wide, everything else the app started waited.
// verify.py runs the suite once more on a one-thread pool
// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), which deadlocks on any test or
// code that blocks a pool thread.

@Suite("Blocking work runs on a thread of its own")
struct BlockingThreadTests {

    @Test func itsValueIsWhatTheWorkReturned() async {
        let thread = BlockingThread(name: "test") { 6 * 7 }
        #expect(await thread.value == 42)
    }

    @Test func aValueAwaitedBeforeTheWorkEndsArrivesWhenItDoes() async {
        let release = DispatchSemaphore(value: 0)
        let thread = BlockingThread(name: "test") { () -> String in
            release.wait()
            return "done"
        }
        Task { try? await Task.sleep(for: .milliseconds(50)); release.signal() }
        #expect(await thread.value == "done")
    }

    /// The point of it: while the work blocks, tasks still run.
    @Test func blockedWorkLeavesTasksToRun() async {
        let release = DispatchSemaphore(value: 0)
        let thread = BlockingThread(name: "test") { release.wait() }
        let ran = await Task { true }.value
        release.signal()
        await thread.value
        #expect(ran)
    }
}
