import Foundation
import Synchronization

/// When each ``TimelineView`` in a running app is due to draw again, and the
/// wake that brings the frame loop round for it.
///
/// A timeline view asks for its next date as its body runs; nothing else
/// keeps a record of it. When the date comes, the view's node is posted to
/// the graph's ``InvalidationInbox`` like a node whose observed state
/// changed, and only that body runs again — which asks for the next date. A
/// view that leaves the tree, or is paused, asks for nothing, and the app is
/// idle again: no timer runs while no view wants one.
///
/// A checked `Sendable`, its state under a lock, because the environment that
/// carries it is: in practice the main actor alone touches it.
final class TimelineScheduler: Sendable {
    private struct Request {
        weak var node: AttributeNode?
        var date: Date
        /// When the date was asked for. A clock set back past it — by hand,
        /// or a machine waking — leaves the date further off than it was
        /// ever meant to be, and an animation would hold still until the
        /// clock caught up: such a request is due at once instead.
        var askedAt: Date

        func isDue(at current: Date) -> Bool {
            date <= current || current < askedAt
        }
    }

    private struct State {
        var requests: [ObjectIdentifier: Request] = [:]
        /// The task that wakes the loop for the earliest date still ahead.
        var sleeper: Task<Void, Never>?
        /// When `sleeper` wakes the loop.
        var sleeperDeadline: Date?
    }

    /// The longest the wake sleeps at once. A date further off is woken for
    /// in steps of this, each frame they bring arming the next: a sleep is a
    /// `Duration`, which a date years ahead would overflow.
    static let longestSleep: TimeInterval = 24 * 60 * 60

    private let state = Mutex(State())
    private let inbox: InvalidationInbox
    private let wake: WakeSignal?
    /// Now, for the views and for deciding what is due. A test passes a
    /// clock it moves by hand.
    let now: @Sendable () -> Date
    /// The least time between two frames an animation draws. Zero where the
    /// render mode's own cap paces the loop; an `.onDemand` app, which has
    /// none, would otherwise draw an animation as fast as it could.
    let animationFloor: TimeInterval

    init(inbox: InvalidationInbox, wake: WakeSignal?, animationFloor: TimeInterval = 0,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.inbox = inbox
        self.wake = wake
        self.animationFloor = animationFloor
        self.now = now
    }

    /// Draw `node` again at `date`, or at the earlier date it already asked
    /// for. A date that is not a finite time — a schedule an infinite
    /// interval apart — never comes, and is not asked for.
    func schedule(_ node: AttributeNode, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        let key = ObjectIdentifier(node)
        let current = now()
        state.withLock { state in
            if let existing = state.requests[key], existing.node === node, existing.date <= date { return }
            state.requests[key] = Request(node: node, date: date, askedAt: current)
        }
    }

    /// Forget what `node` asked for: it has paused, and draws nothing more
    /// until it asks again.
    func cancel(_ node: AttributeNode) {
        _ = state.withLock { $0.requests.removeValue(forKey: ObjectIdentifier(node)) }
    }

    /// Draw `node` again on the next frame, no sooner than `minimumInterval`
    /// seconds — or ``animationFloor`` — from now.
    func requestFrame(for node: AttributeNode, minimumInterval: TimeInterval?) {
        schedule(node, at: now().addingTimeInterval(max(animationFloor, minimumInterval ?? 0)))
    }

    /// The earliest date a view still in the tree asked for.
    var nextDate: Date? {
        state.withLock { state in
            guard !state.requests.isEmpty else { return nil }
            var earliest: Date?
            var gone: [ObjectIdentifier] = []
            for (key, request) in state.requests {
                guard let node = request.node, !node.isRetired else {
                    gone.append(key)
                    continue
                }
                if earliest.map({ request.date < $0 }) ?? true { earliest = request.date }
            }
            for key in gone { state.requests[key] = nil }
            return earliest
        }
    }

    /// Whether a view is due now.
    var hasDue: Bool {
        guard nextDate != nil else { return false }
        let current = now()
        return state.withLock { state in
            state.requests.values.contains { request in
                request.node.map { !$0.isRetired } == true && request.isDue(at: current)
            }
        }
    }

    /// Post every view that is due to the graph, so its body runs again on
    /// this frame, and forget it: its body asks again if it still wants to.
    func postDue() {
        let current = now()
        let due: [AttributeNode] = state.withLock { state in
            var due: [AttributeNode] = []
            for (key, request) in state.requests where request.isDue(at: current) {
                state.requests[key] = nil
                if let node = request.node, !node.isRetired { due.append(node) }
            }
            return due
        }
        for node in due { inbox.post(node) }
    }

    /// Have the frame loop woken at the earliest date still ahead, so an app
    /// that sleeps between a periodic view's dates wakes for the next one.
    /// Nothing ahead, or nothing but what is due already, needs no wake.
    func armWake() {
        guard let wake else { return }
        let next = nextDate
        let current = now()
        state.withLock { state in
            guard let next, next > current else {
                state.sleeper?.cancel()
                state.sleeper = nil
                state.sleeperDeadline = nil
                return
            }
            let deadline = min(next, current.addingTimeInterval(Self.longestSleep))
            if state.sleeperDeadline == deadline { return }
            state.sleeper?.cancel()
            state.sleeperDeadline = deadline
            let delay = deadline.timeIntervalSince(current)
            state.sleeper = Task {
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { wake.wake() }
            }
        }
    }

    /// Stop the wake, when the app ends.
    func cancel() {
        state.withLock { state in
            state.sleeper?.cancel()
            state.sleeper = nil
            state.sleeperDeadline = nil
            state.requests.removeAll()
        }
    }

    #if DEBUG
    /// How many views have asked to be drawn again. For tests.
    var requestCount: Int { state.withLock { $0.requests.count } }

    /// When the wake is armed to bring the loop round, if it is. For tests.
    var wakeDeadline: Date? { state.withLock { $0.sleeperDeadline } }
    #endif
}
