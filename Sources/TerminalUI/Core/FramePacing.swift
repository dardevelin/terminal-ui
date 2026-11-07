/// The frame loop's pause between passes: how long the loop waits, by its
/// render mode, before it drains events and draws again.
///
/// On the main actor, as the loop is: a nonisolated `async` method would hop
/// off it to run, and that hop is itself a suspension — one that would let
/// the main actor's other jobs run whether or not the pause gave them a turn,
/// and hide a pause that never does.
@MainActor
struct FramePacing {
    let renderMode: RenderMode
    let wake: WakeSignal

    /// Returns when the next pass is due; always suspends at least once.
    ///
    /// With nothing to do, sleeps until there is something: an event, a
    /// frame to draw, a quit fired outside event handling or — in a debug
    /// build — a remote command, which the loop's one `pump()` serves before
    /// it drains events, so a query is answered only after the keys sent
    /// before it are drawn. `.uncapped` never sleeps.
    ///
    /// - Parameters:
    ///   - frameStart: When the pass began; `.capped` waits out what is left
    ///     of its interval after it.
    ///   - hasWork: Whether the loop has anything to do now.
    func awaitNextPass(after frameStart: ContinuousClock.Instant, hasWork: () -> Bool) async {
        if case .uncapped = renderMode {
            await Task.yield()
            return
        }
        // Wakes raised while the loop was busy were for work it has just
        // done; one left pending would only cost an empty pass.
        wake.discardPending()
        while !hasWork() {
            await wake.wait()
            if Task.isCancelled { break }
        }
        // `.capped` draws at most one frame per interval: woken early, it
        // waits out the rest. After a long idle there is none left.
        if case .capped(let interval) = renderMode {
            let remaining = interval - (ContinuousClock.now - frameStart)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
        // A loop with work waiting suspends nowhere above: the wait returns
        // at once, and a frame longer than its interval leaves no sleep.
        // Every other job on the main actor — a `.task`, a cursor flash
        // going out — then waited for the loop to fall idle, which a busy
        // app or a loaded machine put off indefinitely. This gives them a
        // turn each pass.
        await Task.yield()
    }
}
