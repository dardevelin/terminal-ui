import Foundation
import Observation
import Synchronization
import Testing
@testable import TerminalUI

// A TimelineView asks the app's scheduler for its next date as its body
// runs, and the scheduler posts it to the graph when that date comes. These
// tests move a clock by hand and drain the graph as the frame loop would:
// nothing here waits on real time.

/// A clock the test moves.
private final class ManualClock: Sendable {
    private let current = Mutex(Date(timeIntervalSinceReferenceDate: 1_000_000))

    var now: Date { current.withLock { $0 } }

    /// Set the clock back, as a user or a waking machine may.
    func setBack(by seconds: TimeInterval) {
        advance(by: -seconds)
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@Observable
private final class Shown {
    var timeline = true
}

/// A graph whose environment carries a scheduler on `clock`, the way a
/// running app's frames do.
@MainActor
private struct Harness {
    let graph = AttributeGraph()
    let clock = ManualClock()
    let scheduler: TimelineScheduler
    let environment: EnvironmentValues

    init(animationFloor: TimeInterval = 0) {
        let clock = clock
        scheduler = TimelineScheduler(inbox: graph.invalidationInbox, wake: nil,
                                      animationFloor: animationFloor, now: { clock.now })
        var environment = EnvironmentValues()
        environment.timelineScheduler = scheduler
        self.environment = environment
    }

    func update(_ view: some TerminalView) {
        GraphContext.$currentEnvironment.withValue(environment) { _ = graph.update(from: view) }
    }

    /// One pass of the frame loop: post what is due, and drain it.
    @discardableResult
    func frame() -> Bool {
        scheduler.postDue()
        return GraphContext.$currentEnvironment.withValue(environment) { graph.drain() }
    }

    /// The text the tree shows, depth first.
    var text: String {
        func collect(_ node: AttributeNode) -> String {
            if case .primitive(.text(let spans)) = node.kind { return spans.map(\.text).joined() }
            return node.children.map(collect).joined()
        }
        return graph.root.map(collect) ?? ""
    }
}

private func seconds(_ date: Date) -> String {
    String(Int(date.timeIntervalSinceReferenceDate))
}

private struct Toggled: TerminalView {
    let shown: Shown
    var body: some TerminalView {
        if shown.timeline {
            TimelineView(.animation) { context in Text(seconds(context.date)) }
        } else {
            Text("gone")
        }
    }
}

@Suite("TimelineView draws on its schedule, and costs nothing otherwise")
@MainActor
struct TimelineViewTests {

    @Test func anAnimationDrawsAgainOnTheNextFrameWithTheFramesDate() {
        let harness = Harness()
        harness.update(TimelineView(.animation) { context in Text(seconds(context.date)) })
        #expect(harness.text == "1000000")
        #expect(harness.scheduler.hasDue)

        harness.clock.advance(by: 2)
        #expect(harness.frame())
        #expect(harness.text == "1000002")
        // Drawing again asked for the frame after.
        #expect(harness.scheduler.requestCount == 1)
    }

    @Test func aPausedAnimationAsksForNothingAndHoldsItsDate() {
        let harness = Harness()
        let paused = Shown()
        paused.timeline = false
        struct Pausable: TerminalView {
            let paused: Shown
            var body: some TerminalView {
                TimelineView(.animation(paused: paused.timeline)) { context in Text(seconds(context.date)) }
            }
        }
        harness.update(Pausable(paused: paused))
        harness.clock.advance(by: 3)
        harness.frame()
        #expect(harness.text == "1000003")

        // The frame the pause lands in may draw the timeline once more, at
        // its date — its own request and its parent's change arrive together.
        paused.timeline = true
        harness.clock.advance(by: 5)
        harness.frame()
        let held = harness.text
        #expect(held == "1000003" || held == "1000008")
        #expect(harness.scheduler.requestCount == 0)
        #expect(!harness.scheduler.hasDue)
        harness.clock.advance(by: 5)
        #expect(!harness.frame(), "nothing is drawn for a paused animation")
        #expect(harness.text == held, "a paused animation shows the date it paused at")
    }

    @Test func aClockSetBackDoesNotHoldAnAnimationStill() {
        let harness = Harness()
        harness.update(TimelineView(.animation(minimumInterval: 0.5)) { context in Text(seconds(context.date)) })
        harness.clock.setBack(by: 3600)
        #expect(harness.scheduler.hasDue, "the frame asked for an hour ahead of the clock is due")
        #expect(harness.frame())
        #expect(harness.text == "996400")
    }

    @Test func aMinimumIntervalHoldsTheNextFrameBack() {
        let harness = Harness()
        harness.update(TimelineView(.animation(minimumInterval: 0.5)) { context in Text(seconds(context.date)) })
        #expect(!harness.scheduler.hasDue)
        harness.clock.advance(by: 0.25)
        #expect(!harness.frame())
        harness.clock.advance(by: 0.25)
        #expect(harness.frame())
    }

    @Test func anOnDemandAppAnimatesAtSixtyFramesASecond() {
        #expect(TerminalRuntime<Text>.animationFloor(for: .onDemand) == 1.0 / 60.0)
        #expect(TerminalRuntime<Text>.animationFloor(for: .fps60) == 0)
        let harness = Harness(animationFloor: 1.0 / 60.0)
        harness.update(TimelineView(.animation) { context in Text(seconds(context.date)) })
        #expect(!harness.scheduler.hasDue)
        harness.clock.advance(by: 1.0 / 60.0)
        #expect(harness.scheduler.hasDue)
    }

    @Test func aPeriodicTimelineShowsItsLatestDateAndWakesForTheNext() {
        let harness = Harness()
        let start = harness.clock.now.addingTimeInterval(-25)
        harness.update(TimelineView(.periodic(from: start, by: 10)) { context in
            Text("\(seconds(context.date)) \(context.cadence)")
        })
        #expect(harness.text == "999995 seconds")
        #expect(harness.scheduler.nextDate == start.addingTimeInterval(30))

        harness.clock.advance(by: 4)
        #expect(!harness.frame(), "nothing is due before the next date")
        harness.clock.advance(by: 1)
        #expect(harness.frame())
        #expect(harness.text == "1000005 seconds")
    }

    @Test func everyMinuteFallsOnTheMinute() {
        let schedule = EveryMinuteTimelineSchedule()
        let date = Date(timeIntervalSinceReferenceDate: 125)
        let dates = Array(schedule.entries(from: date, mode: .normal).prefix(2))
        #expect(dates == [Date(timeIntervalSinceReferenceDate: 120), Date(timeIntervalSinceReferenceDate: 180)])
    }

    @Test func anExplicitScheduleShowsTheLastDatePassed() {
        let harness = Harness()
        let now = harness.clock.now
        let dates = [now.addingTimeInterval(-2), now.addingTimeInterval(-1), now.addingTimeInterval(4)]
        harness.update(TimelineView(.explicit(dates)) { context in Text(seconds(context.date)) })
        #expect(harness.text == "999999")
        #expect(harness.scheduler.nextDate == dates[2])
    }

    @Test func aTimelineThatLeavesTheTreeAsksForNothingMore() {
        let harness = Harness()
        let shown = Shown()
        harness.update(Toggled(shown: shown))
        #expect(harness.scheduler.nextDate != nil)

        shown.timeline = false
        harness.frame()
        #expect(harness.text == "gone")
        harness.clock.advance(by: 1)
        harness.frame()
        #expect(harness.scheduler.nextDate == nil)
        #expect(!harness.graph.hasDirtyNodes, "an app with no timeline left is idle")
    }

    @Test func aScheduleThatNeverComesAgainAsksForNothingAndDoesNotTrap() {
        let harness = Harness()
        let start = harness.clock.now
        harness.update(VStack {
            TimelineView(.periodic(from: start, by: .infinity)) { context in Text(seconds(context.date)) }
            TimelineView(.periodic(from: start, by: .nan)) { _ in Text("nan") }
            TimelineView(.animation(minimumInterval: .infinity)) { _ in Text("never") }
        })
        #expect(harness.text.hasPrefix("1000000"))
        #expect(harness.scheduler.nextDate == start.addingTimeInterval(1.0 / 60.0),
                "only the NaN interval, read as every frame, comes again")
    }

    @Test func aDateFarAheadIsWokenForADayAtATime() {
        let clock = ManualClock()
        let graph = AttributeGraph()
        let scheduler = TimelineScheduler(inbox: graph.invalidationInbox, wake: WakeSignal(),
                                          now: { clock.now })
        var environment = EnvironmentValues()
        environment.timelineScheduler = scheduler
        let years = TimeInterval(100 * 365 * 24 * 60 * 60)
        let start = clock.now
        GraphContext.$currentEnvironment.withValue(environment) {
            _ = graph.update(from: TimelineView(.explicit([start.addingTimeInterval(years)])) { _ in Text("later") })
        }
        scheduler.armWake()
        #expect(scheduler.wakeDeadline == start.addingTimeInterval(TimelineScheduler.longestSleep))
        scheduler.cancel()
    }

    @Test func withoutARunningAppATimelineDrawsItsMomentOnce() {
        let graph = AttributeGraph()
        graph.update(from: TimelineView(.animation) { _ in Text("once") })
        #expect(!graph.hasDirtyNodes)
    }
}
