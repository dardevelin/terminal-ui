import Testing
import TerminalUIConfig
@testable import TerminalUIRecording

// A picture's timeline from a log's real one. Times in a log are µs, in a
// timeline ms; the logs here draw nothing, since only when frames were
// drawn matters.

private func frame(_ time: Int, _ number: Int) -> String {
    #"{"t":\#(time),"frame":\#(number),"rows":[]}"#
}

private func mark(_ time: Int, _ label: String, hold: Int? = nil) -> String {
    #"{"t":\#(time),"mark":"\#(label)""# + (hold.map { #","hold":\#($0)"# } ?? "") + "}"
}

private func end(_ time: Int) -> String {
    #"{"t":\#(time),"end":true,"frames":0,"marks":0}"#
}

private func frames(_ timeline: PresentationTimeline) -> [[Int]] {
    timeline.frames.map { [$0.frame, $0.time] }
}

private let script = try! PresentationClock(mode: .script)
private let draw = try! PresentationClock(mode: .draw)

@Suite("The presentation clock")
struct PresentationClockTests {

    @Test func aQuantumIsAtLeastTwentyMilliseconds() throws {
        #expect(throws: RecordingLogError("a quantum is at least 20 ms, not 19 ms")) {
            try PresentationClock(mode: .script, quantum: 19)
        }
        #expect(try PresentationClock(mode: .script, quantum: 20).quantum == 20)
        #expect(script.quantum == 40)
    }

    @Test func timesRoundToTheNearestQuantumHalfUp() {
        #expect(script.quantised(microseconds: 19_999) == 0)
        #expect(script.quantised(microseconds: 20_000) == 40)
        #expect(script.quantised(microseconds: 59_999) == 40)
        #expect(script.quantised(microseconds: 60_000) == 80)
        #expect(script.quantised(microseconds: -5_000) == 0)
    }

    @Test func aHeldMarkShowsItsScreenForItsHold() throws {
        // A driver's dwell does not sleep: each key's frame comes a few ms
        // after the mark before it, and shows when that mark's hold ends.
        let log = try reader([header4x2, frame(0, 1), mark(1_000, "a", hold: 400),
                              frame(3_000, 2), mark(5_000, "b", hold: 600),
                              frame(6_000, 3), end(7_000)])
        let timeline = try script.timeline(of: log)
        #expect(frames(timeline) == [[0, 0], [1, 400], [2, 1_000]])
        #expect(timeline.marks == [.init(label: "a", time: 0), .init(label: "b", time: 400)])
        #expect(timeline.duration == 1_000)
    }

    @Test func aLiveSegmentPlaysItsQuantisedRealTimes() throws {
        let log = try reader([header4x2, frame(0, 1), mark(0, "live"),
                              frame(30_000, 2), frame(50_000, 3), frame(130_000, 4),
                              mark(200_000, "after", hold: 100), end(210_000)])
        let timeline = try script.timeline(of: log)
        // 30 ms and 50 ms both round to 40: the last of them is shown.
        #expect(frames(timeline) == [[0, 0], [2, 40], [3, 120]])
        #expect(timeline.marks == [.init(label: "live", time: 0), .init(label: "after", time: 200)])
        #expect(timeline.duration == 300)
    }

    @Test func framesBeforeTheFirstMarkCollapseIntoIt() throws {
        let log = try reader([header4x2, frame(0, 1), frame(10_000, 2), frame(500_000, 3),
                              mark(600_000, "start", hold: 200), end(700_000)])
        let timeline = try script.timeline(of: log)
        #expect(frames(timeline) == [[2, 0]])
        #expect(timeline.duration == 200)
    }

    @Test func aLogNobodyMarkedPlaysAsOneLiveSegment() throws {
        let log = try reader([header4x2, frame(0, 1), frame(90_000, 2), end(1_000_000)])
        let timeline = try script.timeline(of: log)
        #expect(frames(timeline) == [[0, 0], [1, 80]])
        #expect(timeline.marks.isEmpty)
        #expect(timeline.duration == 1_000)
    }

    @Test func atIsTheFrameShowingWhenTheMarkWasMade() throws {
        let log = try reader([header4x2, frame(0, 1), mark(1_000, "a", hold: 400),
                              frame(3_000, 2), mark(5_000, "b", hold: 600), frame(6_000, 3)])
        let still = try script.timeline(of: log, range: .at("b"))
        #expect(frames(still) == [[1, 0]])
        #expect(still.duration == 0)
        // The same frame whichever clock, since a still has no timeline.
        #expect(try draw.timeline(of: log, range: .at("b")) == still)
        #expect(throws: RecordingLogError("the log has no mark c")) { try script.timeline(of: log, range: .at("c")) }
    }

    @Test func fromToRunsFromOneMarksScreenToAnothers() throws {
        let log = try reader([header4x2, frame(0, 1), mark(1_000, "a", hold: 400),
                              frame(3_000, 2), mark(5_000, "b", hold: 600),
                              frame(6_000, 3), mark(7_000, "c", hold: 300),
                              frame(8_000, 4), end(9_000)])
        let range = try script.timeline(of: log, range: .between(from: "b", to: "c"))
        #expect(frames(range) == [[1, 0], [2, 600]])
        #expect(range.marks == [.init(label: "b", time: 0), .init(label: "c", time: 600)])
        #expect(range.duration == 600)

        let whole = try script.timeline(of: log, range: .between(from: "a", to: "c"))
        #expect(frames(whole) == [[0, 0], [1, 400], [2, 1_000]])
        #expect(throws: RecordingLogError("the mark a comes before c")) {
            try script.timeline(of: log, range: .between(from: "c", to: "a"))
        }
    }

    @Test func drawPlaysRealTimesWithLongGapsCut() throws {
        let log = try reader([header4x2, frame(0, 1), frame(500_000, 2), frame(10_000_000, 3),
                              mark(10_100_000, "m"), frame(10_250_000, 4), end(11_000_000)])
        let timeline = try draw.timeline(of: log)
        #expect(frames(timeline) == [[0, 0], [1, 500], [2, 2_500], [3, 2_750]])
        #expect(timeline.marks == [.init(label: "m", time: 2_600)])
        #expect(timeline.duration == 3_500)
    }

    @Test func drawRoundsToTheNearestMillisecondAndKeepsTheLastAtEachInstant() throws {
        let log = try reader([header4x2, frame(0, 1), frame(1_499, 2), frame(1_500, 3),
                              frame(2_400, 4), end(2_400)])
        #expect(frames(try draw.timeline(of: log)) == [[0, 0], [1, 1], [3, 2]])
    }

    @Test func gifDelaysAreCumulativelyRoundedSoTheyNeverDrift() {
        let timeline = PresentationTimeline(
            frames: [.init(frame: 0, time: 0), .init(frame: 1, time: 333), .init(frame: 2, time: 667),
                     .init(frame: 3, time: 1_000)],
            marks: [], duration: 1_333)
        let delays = timeline.gifDelays()
        #expect(delays.map(\.centiseconds) == [33, 34, 33, 33])
        #expect(delays.map(\.centiseconds).reduce(0, +) == 133)
    }

    @Test func aGIFFrameUnderTwoCentisecondsMergesIntoTheNext() {
        let timeline = PresentationTimeline(
            frames: [.init(frame: 0, time: 0), .init(frame: 1, time: 100), .init(frame: 2, time: 105),
                     .init(frame: 3, time: 112), .init(frame: 4, time: 200)],
            marks: [], duration: 300)
        #expect(timeline.gifDelays() == [.init(frame: 0, centiseconds: 10), .init(frame: 3, centiseconds: 10),
                                          .init(frame: 4, centiseconds: 10)])
    }

    @Test func theLastGIFFrameShowsForAtLeastTheShortestDelay() {
        let timeline = PresentationTimeline(frames: [.init(frame: 0, time: 0), .init(frame: 1, time: 500)],
                                            marks: [], duration: 500)
        #expect(timeline.gifDelays() == [.init(frame: 0, centiseconds: 50), .init(frame: 1, centiseconds: 2)])
    }

    @Test func durationsAreReadInWholeMilliseconds() {
        let cases: [(String, Int?)] = [
            ("40ms", 40), ("0ms", 0), ("2s", 2_000), ("1.5s", 1_500), ("0.25s", 250), ("1.125s", 1_125),
            ("1.2345s", nil), ("1.5ms", nil), ("40", nil), ("ms", nil), ("s", nil), ("-1s", nil),
            (".5s", nil), ("1.s", nil), ("1e3ms", nil), ("+40ms", nil),
        ]
        for (text, expected) in cases {
            #expect(PresentationClock.milliseconds(parsing: text) == expected, "\(text)")
        }
    }
}
