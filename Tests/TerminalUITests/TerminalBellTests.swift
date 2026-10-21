import Synchronization
import Testing
@testable import TerminalUI

// `.boundaryFeedback(.bell)` routed every hit to a bell sink nothing had
// installed, so it never rang. The bell is now an environment action, as
// SwiftUI's `openURL` is: a running app supplies one that rings its
// `TerminalBell`, which wakes the frame loop to write BEL with the next frame.

@Suite("TerminalBell — rung anywhere, sounded by the frame loop")
struct TerminalBellTests {

    @Test("Rings between two frames are taken once")
    func ringsAreTakenOnce() {
        let bell = TerminalBell(wake: WakeSignal())
        #expect(!bell.isPending)
        bell.ring()
        bell.ring()
        #expect(bell.isPending)
        #expect(bell.take())
        #expect(!bell.take())
        #expect(!bell.isPending)
    }

    @Test("Ringing wakes an idle frame loop")
    func ringWakesTheLoop() async {
        let wake = WakeSignal()
        let bell = TerminalBell(wake: wake)
        let woke = await finishes(within: .seconds(2)) {
            async let waited: Void = wake.wait()
            try? await Task.sleep(for: .milliseconds(20))
            bell.ring()
            await waited
        }
        #expect(woke)
    }
}

/// Counts rings from any thread; the actions under test are `@Sendable`.
private final class RingCounter: Sendable {
    private let count = Mutex(0)

    var rings: Int { count.withLock { $0 } }

    var action: BellAction {
        BellAction { self.count.withLock { $0 += 1 } }
    }
}

@Suite("BoundaryHitAction — the environment's answer to a wall hit")
struct BoundaryHitActionTests {

    @Test(".bell rings the environment's bell")
    func bellRingsTheEnvironmentBell() {
        let counter = RingCounter()
        var env = EnvironmentValues()
        env.boundaryFeedback = .bell
        env.bell = counter.action
        env.boundaryHit(.rightEdge)
        #expect(counter.rings == 1)
    }

    @Test("Outside a running app the bell is silent")
    func defaultBellIsSilent() {
        var env = EnvironmentValues()
        env.boundaryFeedback = .bell
        env.boundaryHit(.leftEdge)
    }

    @Test("Other modes leave the bell alone")
    func otherModesDoNotRing() {
        let counter = RingCounter()
        for mode in [BoundaryFeedback.bounce, .modal, .none] {
            var env = EnvironmentValues()
            env.boundaryFeedback = mode
            env.bell = counter.action
            env.boundaryHit(.leftEdge)
        }
        #expect(counter.rings == 0)
    }

    // Under the Thread Sanitizer, a hook held in a plain stored property
    // reports this as a race: an app installs its bounce while a hit routes.
    @Test("Installing a bounce hook while another thread hits a wall is not a race")
    func concurrentInstallAndHit() async {
        // Its own emitter: the shared one is counted by suites running in
        // parallel with this one.
        let emitter = BoundaryFeedbackEmitter()
        let boundaryHit = BoundaryHitAction(mode: .bounce, callback: nil, bell: BellAction {},
                                            bounce: { emitter.bounceSink($0) })
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<1_000 {
                    emitter.bounceSink = { _ in }
                }
            }
            group.addTask {
                for _ in 0..<1_000 {
                    boundaryHit(.rightEdge)
                }
            }
        }
    }
}
