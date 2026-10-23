import Synchronization
@testable import TerminalUI

/// Records what inputs do at a wall, through the environment of the view a
/// test drives: rings of its bell, and the reasons of its `.bounce` hits and
/// `.onBoundaryHit` calls. Nothing process-wide is touched, so suites that
/// hit walls run side by side.
final class BoundaryRecorder: Sendable {
    private struct Hits {
        var bell = 0
        var bounce: [BoundaryHitReason] = []
        var modal: [BoundaryHitReason] = []
    }

    private let hits = Mutex(Hits())

    var bell: Int { hits.withLock { $0.bell } }
    var bounce: [BoundaryHitReason] { hits.withLock { $0.bounce } }
    var modal: [BoundaryHitReason] { hits.withLock { $0.modal } }

    /// An environment whose bell, bounce hook and `.onBoundaryHit` callback
    /// are this recorder's.
    var environment: EnvironmentValues {
        var env = EnvironmentValues()
        env.bell = BellAction { self.hits.withLock { $0.bell += 1 } }
        env.boundaryBounce = { reason in self.hits.withLock { $0.bounce.append(reason) } }
        env.onBoundaryHit = BoundaryHitCallback { reason in self.hits.withLock { $0.modal.append(reason) } }
        return env
    }
}
