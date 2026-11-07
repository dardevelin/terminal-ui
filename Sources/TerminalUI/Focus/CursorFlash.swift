import Observation
import Synchronization

/// The focused cursor, lit for a moment when an input refuses a key at a
/// wall — what `.boundaryFeedback(.bounce)`, the default, shows. A running
/// app supplies one, as `\.cursorFlash`; an input that draws a cursor reads
/// ``isLit`` while it holds focus and draws the cursor in the theme's
/// warning colour.
///
/// Observable by hand, its state under a lock: a hit lights it, and either
/// change redraws the cursor that reads ``isLit`` — even in an `.onDemand`
/// app, which an observed change wakes.
///
/// The moment is timed from the first frame the runtime draws while it is
/// lit, not from the hit. Timed from the hit, a frame that took longer than
/// the moment to come — a busy app, a loaded machine — drew the cursor
/// already dark, and the hit showed nothing. And it goes out on the main
/// actor, between frames: put out from another thread, the change could
/// land after a body read ``isLit`` and before `withObservationTracking`
/// installed its observers, which are installed only once the body
/// returns, and the cursor stayed lit until something else redrew it.
public final class CursorFlash: Sendable, Observable {
    /// About the shortest flash that is reliably seen; a key held at a wall
    /// repeats faster than this, and keeps the cursor lit.
    static let standardDuration: Duration = .milliseconds(100)

    private struct State {
        var lit = false
        /// Counts hits, so a timer from an earlier one does not put out the
        /// cursor a later one lit.
        var hits = 0
        /// The latest hit is not yet on screen, and its moment not started.
        var undrawn = false
    }

    private let state = Mutex(State())
    private let registrar = ObservationRegistrar()
    private let duration: Duration

    init(duration: Duration = CursorFlash.standardDuration) {
        self.duration = duration
    }

    /// Whether the cursor is lit now.
    public var isLit: Bool {
        registrar.access(self, keyPath: \.isLit)
        return state.withLock { $0.lit }
    }

    /// Lights the cursor until the flash's duration after the next frame
    /// drawn, or keeps it lit that long if it is lit already.
    func light() {
        let wasLit = state.withLock { state in
            defer {
                state.lit = true
                state.hits += 1
                state.undrawn = true
            }
            return state.lit
        }
        if !wasLit { announceChange() }
    }

    /// Called by the runtime after each frame it draws: the first one since
    /// a hit has put the lit cursor on screen, and starts its moment.
    /// Returns the task that ends it, for a caller that waits on it; a wait
    /// on the clock instead fails whenever the main actor is busier than the
    /// wait is long.
    @MainActor @discardableResult
    func frameDrawn() -> Task<Void, Never>? {
        let hit: Int? = state.withLock { state in
            guard state.undrawn else { return nil }
            state.undrawn = false
            return state.hits
        }
        guard let hit else { return nil }
        return Task { @MainActor [duration] in
            try? await Task.sleep(for: duration)
            self.putOut(after: hit)
        }
    }

    /// Puts the cursor out, unless a hit since `hit` keeps it lit.
    @MainActor
    func putOut(after hit: Int) {
        let wentDark = state.withLock { state in
            guard state.hits == hit else { return false }
            state.lit = false
            return true
        }
        if wentDark { announceChange() }
    }

    /// Tells observers ``isLit`` changed, after the change: an observer is
    /// told at `willSet`, and a redraw that ran between that and the write
    /// would read the old value and never hear of the new one.
    private func announceChange() {
        registrar.withMutation(of: self, keyPath: \.isLit) {}
    }
}
