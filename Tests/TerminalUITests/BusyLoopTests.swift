import Testing
@testable import TerminalUI

// The frame loop runs on the main actor, and with work waiting nothing in a
// pass suspended: the wait for work returned at once, a `.capped` frame
// longer than its interval left no sleep, and `.onDemand` never sleeps. Every
// other job on the main actor — a `.task` body, a cursor flash going out —
// waited for the loop to fall idle, which a busy app never did.
//
// These drive the loop's pause directly, from the main actor as the loop
// does, and await nothing else between starting the job and checking it ran:
// any other suspension would give the job the turn the pause is meant to.
// The pause is on the main actor for the same reason. Declared nonisolated
// (its `hasWork` made `@MainActor` to compile), its call hops off the main
// actor, and that hop alone lets the job run: every test here then passes
// with both of the pause's yields removed.

@MainActor
private final class Flag {
    var value = false
}

@Suite("A busy frame loop lets the main actor's other work run")
@MainActor
struct BusyLoopTests {

    /// Passes enough for a job queued before the first to have had its turn
    /// many times over.
    private static let passLimit = 100

    @Test("A task started while every pass has work runs",
          arguments: [RenderMode.onDemand, .fps60, .uncapped])
    func aTaskRunsWhileEveryPassHasWork(renderMode: RenderMode) async {
        let pacing = FramePacing(renderMode: renderMode, wake: WakeSignal())
        // A pass that began long ago, as one that outran its interval: a
        // capped pause has none of it left to sleep.
        let frameStart = ContinuousClock.now - .seconds(1)
        let ran = Flag()
        Task { @MainActor in ran.value = true }
        var passes = 0
        while !ran.value && passes < Self.passLimit {
            await pacing.awaitNextPass(after: frameStart) { true }
            passes += 1
        }
        #expect(ran.value, "a main-actor task never ran in \(passes) passes that each had work")
    }

    @Test("A cursor flash goes out while every pass has work")
    func aCursorFlashGoesOutWhileEveryPassHasWork() async {
        let pacing = FramePacing(renderMode: .onDemand, wake: WakeSignal())
        let frameStart = ContinuousClock.now - .seconds(1)
        let flash = CursorFlash(duration: .milliseconds(10))
        flash.light()
        flash.frameDrawn()
        let deadline = ContinuousClock.now + eventualLimit
        while flash.isLit && ContinuousClock.now < deadline {
            await pacing.awaitNextPass(after: frameStart) { true }
        }
        #expect(!flash.isLit, "the flash stayed lit through \(eventualLimit) of passes that each had work")
    }

    @Test("With nothing to do, it waits for a wake")
    func withNothingToDoItWaitsForAWake() async {
        let wake = WakeSignal()
        let pacing = FramePacing(renderMode: .onDemand, wake: wake)
        let hasWork = Flag()
        let returned = Flag()
        let pace = Task { @MainActor in
            await pacing.awaitNextPass(after: .now) { hasWork.value }
            returned.value = true
        }
        // Each yield hands the main actor to the pace, which runs until it
        // suspends: a pause that did not wait would have returned well
        // within these, with no clock involved.
        for _ in 0..<Self.passLimit {
            await Task.yield()
        }
        #expect(!returned.value, "the pause returned with nothing to do and no wake")
        hasWork.value = true
        wake.wake()
        #expect(await finishes(within: eventualLimit) { await pace.value },
                "a wake with work waiting did not end the pause")
    }
}
