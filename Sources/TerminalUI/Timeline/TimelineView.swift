import Foundation

/// A view that draws again on a schedule — SwiftUI's `TimelineView`.
///
/// Its content is built from a ``TimelineViewDefaultContext`` whose ``TimelineViewDefaultContext/date``
/// is the schedule's latest date: build what the moment shows from it, and
/// the view keeps it current.
///
/// ```swift
/// TimelineView(.animation) { context in
///     let angle = context.date.timeIntervalSinceReferenceDate
///     Spinning(angle: angle)
/// }
///
/// TimelineView(.periodic(from: .now, by: 1)) { context in
///     Text(context.date.formatted(date: .omitted, time: .standard))
/// }
/// ```
///
/// With ``AnimationTimelineSchedule`` the content is built again for every
/// frame the app draws, at its render mode's cap — an `.onDemand` app, which
/// has none, at 60 a second. Other schedules wake the app at each of their
/// dates and draw nothing between them.
///
/// Only the timeline's own body runs again, as for a change to the state it
/// read; and a timeline that leaves the tree, or whose animation is
/// paused, asks for nothing, so an app with none running stays idle.
public struct TimelineView<Schedule: TimelineSchedule, Content: TerminalView>: TerminalView {
    /// What the content is built from: the schedule's date and its cadence.
    public typealias Context = TimelineViewDefaultContext

    /// When the view draws again.
    public let schedule: Schedule
    /// Builds the view for a moment of the schedule.
    public let content: (Context) -> Content

    /// A view built from `content` at each of `schedule`'s dates.
    public init(_ schedule: Schedule, @TerminalViewBuilder content: @escaping (Context) -> Content) {
        self.schedule = schedule
        self.content = content
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        content(TimelineDriver.context(for: schedule))
    }
}

/// What a ``TimelineView`` builds its content from.
public struct TimelineViewDefaultContext: Sendable {
    /// How often a timeline updates — what a view can leave out when it
    /// updates seldom, as a clock drops its seconds hand.
    public enum Cadence: Int, Comparable, Sendable {
        /// Updates many times a second.
        case live
        /// Updates about once a second.
        case seconds
        /// Updates about once a minute.
        case minutes

        /// Whether `lhs` updates more often than `rhs`.
        public static func < (lhs: Cadence, rhs: Cadence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The moment to draw: the schedule's latest date, or for an animation
    /// the frame's.
    public let date: Date
    /// How often the timeline updates.
    public let cadence: Cadence

    /// A context for `date`, updating at `cadence`. Tests build one to
    /// exercise a timeline's content directly.
    public init(date: Date, cadence: Cadence) {
        self.date = date
        self.cadence = cadence
    }
}

/// How a schedule is asked for its dates — SwiftUI's `TimelineScheduleMode`.
public enum TimelineScheduleMode: Sendable {
    /// Every date the schedule has.
    case normal
    /// As few dates as the schedule can do with.
    case lowFrequency
}

/// The dates a ``TimelineView`` draws at — SwiftUI's `TimelineSchedule`.
///
/// A schedule is asked for its dates from the moment the view updates; the
/// view shows the latest that has passed and wakes for the first still to
/// come. An empty sequence, or one with nothing to come, draws once.
public protocol TimelineSchedule {
    /// The dates, in increasing order.
    associatedtype Entries: Sequence where Entries.Element == Date

    /// The dates from `startDate` on, starting with the latest at or before
    /// it, if there is one.
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries
}

// MARK: - Schedules

/// Every frame — SwiftUI's `AnimationTimelineSchedule`.
public struct AnimationTimelineSchedule: TimelineSchedule, Sendable, Equatable {
    /// The least time, in seconds, between two frames; nil draws every frame
    /// the app's render mode allows.
    public let minimumInterval: Double?
    /// Whether the animation holds still, at the date it had when paused.
    public let paused: Bool

    /// Every frame, no more often than `minimumInterval` seconds, unless
    /// `paused`.
    public init(minimumInterval: Double? = nil, paused: Bool = false) {
        self.minimumInterval = minimumInterval
        self.paused = paused
    }

    /// The dates a frame lands on: `startDate`, then one every
    /// `minimumInterval` — or every sixtieth of a second, the nearest a
    /// sequence can say "every frame" — and nothing after `startDate` once
    /// paused. A ``TimelineView`` does not ask: it draws each frame as it
    /// comes.
    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> PeriodicTimelineSchedule.Entries {
        PeriodicTimelineSchedule.Entries(start: startDate,
                                         interval: minimumInterval ?? TimelineDriver.frameInterval,
                                         limit: paused ? 1 : nil)
    }
}

/// A date every `interval` seconds from a start — SwiftUI's
/// `PeriodicTimelineSchedule`.
public struct PeriodicTimelineSchedule: TimelineSchedule, Sendable, Equatable {
    /// The dates `start + n × interval`, from the latest at or before the
    /// date they were asked from.
    public struct Entries: Sequence, IteratorProtocol, Sendable {
        var upcoming: Date
        let interval: TimeInterval
        var remaining: Int?

        init(start: Date, interval: TimeInterval, limit: Int? = nil) {
            self.upcoming = start
            self.interval = interval
            self.remaining = limit
        }

        /// The next date, or nil when a limited sequence has none left.
        public mutating func next() -> Date? {
            if let remaining {
                guard remaining > 0 else { return nil }
                self.remaining = remaining - 1
            }
            defer { upcoming = upcoming.addingTimeInterval(interval) }
            return upcoming
        }
    }

    /// The first date.
    public let start: Date
    /// The seconds between two dates; at most every sixtieth of a second.
    public let interval: TimeInterval

    /// A date every `interval` seconds, the first at `startDate`.
    public init(from startDate: Date, by interval: TimeInterval) {
        self.start = startDate
        self.interval = interval
    }

    /// The dates from the latest at or before `startDate` — or from the
    /// first, when `startDate` comes before it.
    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // `max` hands NaN back when it comes first, as an interval would.
        let step = interval.isNaN ? TimelineDriver.frameInterval : max(interval, TimelineDriver.frameInterval)
        let elapsed = startDate.timeIntervalSince(start)
        guard elapsed > 0, elapsed.isFinite else { return Entries(start: start, interval: step) }
        let passed = (elapsed / step).rounded(.down)
        return Entries(start: start.addingTimeInterval(passed * step), interval: step)
    }
}

/// The start of every minute — SwiftUI's `EveryMinuteTimelineSchedule`.
public struct EveryMinuteTimelineSchedule: TimelineSchedule, Sendable, Equatable {
    /// A date at the start of each minute.
    public init() {}

    /// The start of the minute `startDate` falls in, and each minute after.
    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> PeriodicTimelineSchedule.Entries {
        let seconds = startDate.timeIntervalSinceReferenceDate
        let minuteStart = (seconds / TimelineDriver.secondsPerMinute).rounded(.down) * TimelineDriver.secondsPerMinute
        return PeriodicTimelineSchedule.Entries(start: Date(timeIntervalSinceReferenceDate: minuteStart),
                                                interval: TimelineDriver.secondsPerMinute)
    }
}

/// The dates given, in order — SwiftUI's `ExplicitTimelineSchedule`.
public struct ExplicitTimelineSchedule<Dates: Sequence>: TimelineSchedule where Dates.Element == Date {
    /// The dates.
    public let dates: Dates

    /// A schedule of `dates`, which must be in increasing order.
    public init(_ dates: Dates) {
        self.dates = dates
    }

    /// The dates, whatever `startDate` is: the view skips those passed.
    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Dates {
        dates
    }
}

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    /// Every frame.
    public static var animation: AnimationTimelineSchedule { AnimationTimelineSchedule() }

    /// Every frame, no more often than `minimumInterval` seconds, unless
    /// `paused`.
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused)
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// A date every `interval` seconds, the first at `startDate`.
    public static func periodic(from startDate: Date, by interval: TimeInterval) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: startDate, by: interval)
    }
}

extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    /// The start of every minute.
    public static var everyMinute: EveryMinuteTimelineSchedule { EveryMinuteTimelineSchedule() }
}

extension TimelineSchedule {
    /// The dates given, in increasing order.
    public static func explicit<Dates: Sequence>(_ dates: Dates) -> ExplicitTimelineSchedule<Dates>
    where Self == ExplicitTimelineSchedule<Dates> {
        ExplicitTimelineSchedule(dates)
    }
}

// MARK: - Driving

/// Works out a timeline's moment as its body runs, and asks the app's
/// ``TimelineScheduler`` to run the body again at the next.
enum TimelineDriver {
    /// A sixtieth of a second: the fastest a schedule's dates come, and what
    /// "every frame" means to a sequence.
    static let frameInterval: TimeInterval = 1.0 / 60.0
    static let secondsPerMinute: TimeInterval = 60
    /// The most passed dates a body steps over to reach the current one; a
    /// schedule that is still behind after that shows the date it reached.
    static let maximumSkippedEntries = 10_000

    static func context<S: TimelineSchedule>(for schedule: S) -> TimelineViewDefaultContext {
        let node = GraphContext.currentNode
        let scheduler = GraphContext.currentEnvironment?.timelineScheduler
        let now = scheduler?.now() ?? Date()

        if let animation = schedule as? AnimationTimelineSchedule {
            guard !animation.paused else {
                // A frame asked for before the pause is not drawn: the body
                // that asked may run again in the frame the pause lands in,
                // as its parent's does, and either order must end paused.
                if let node { scheduler?.cancel(node) }
                let held = node?.timelineDate ?? now
                node?.timelineDate = held
                return TimelineViewDefaultContext(date: held, cadence: .live)
            }
            node?.timelineDate = now
            if let node, let scheduler {
                scheduler.requestFrame(for: node, minimumInterval: animation.minimumInterval)
            }
            return TimelineViewDefaultContext(date: now, cadence: .live)
        }

        var current: Date?
        var upcoming: Date?
        var skipped = 0
        for entry in schedule.entries(from: now, mode: .normal) {
            if entry > now {
                upcoming = entry
                break
            }
            current = entry
            skipped += 1
            if skipped >= maximumSkippedEntries { break }
        }
        if let upcoming, let node, let scheduler {
            scheduler.schedule(node, at: upcoming)
        }
        let date = current ?? now
        node?.timelineDate = date
        return TimelineViewDefaultContext(date: date, cadence: cadence(of: schedule))
    }

    private static func cadence<S: TimelineSchedule>(of schedule: S) -> TimelineViewDefaultContext.Cadence {
        if schedule is EveryMinuteTimelineSchedule { return .minutes }
        guard let periodic = schedule as? PeriodicTimelineSchedule else { return .live }
        if periodic.interval >= secondsPerMinute { return .minutes }
        return periodic.interval >= 1 ? .seconds : .live
    }
}
