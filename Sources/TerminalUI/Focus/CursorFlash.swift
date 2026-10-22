import Observation
import Synchronization

/// The focused cursor, lit for a moment when an input refuses a key at a
/// wall — what `.boundaryFeedback(.bounce)`, the default, shows. A running
/// app supplies one, as `\.cursorFlash`; an input that draws a cursor reads
/// ``isLit`` while it holds focus and draws the cursor in the theme's
/// warning colour.
///
/// Observable by hand, its state under a lock: a hit lights it on the main
/// actor and a timer puts it out from a task, and either change redraws the
/// cursor that reads ``isLit`` — even in an `.onDemand` app, which an
/// observed change wakes.
public final class CursorFlash: Sendable, Observable {
    /// About the shortest flash that is reliably seen; a key held at a wall
    /// repeats faster than this, and keeps the cursor lit.
    static let standardDuration: Duration = .milliseconds(100)

    private struct State {
        var lit = false
        /// Counts hits, so a timer from an earlier one does not put out the
        /// cursor a later one lit.
        var hits = 0
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

    /// Lights the cursor for the flash's duration, or for that long after
    /// this hit if it is lit already.
    func light() {
        let (hit, wasLit) = state.withLock { state in
            defer {
                state.lit = true
                state.hits += 1
            }
            return (state.hits + 1, state.lit)
        }
        if !wasLit { announceChange() }
        Task { [duration] in
            try? await Task.sleep(for: duration)
            self.putOut(after: hit)
        }
    }

    /// Puts the cursor out, unless a hit since `hit` keeps it lit.
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
