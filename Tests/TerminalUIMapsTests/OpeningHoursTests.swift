import Foundation
import Testing
@testable import TerminalUIMaps

/// A moment in `zone`: the clock open-now is worked out against, fixed so
/// no test depends on when it runs. 2026-11-09 is a Monday.
func instant(_ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = utc) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

let utc = TimeZone(identifier: "UTC")!
private let monday = 9, tuesday = 10, friday = 13, saturday = 14, sunday = 15

@Suite("Opening hours")
struct OpeningHoursTests {
    @Test func weekdaysAndTimes() throws {
        let hours = OpeningHours("Mo-Fr 08:00-18:00; Sa 09:00-12:00")
        let week = try #require(hours.schedule)
        #expect(week.spans[.monday] == [480..<1_080])
        #expect(week.spans[.friday] == [480..<1_080])
        #expect(week.spans[.saturday] == [540..<720])
        #expect(week.spans[.sunday] == nil)
        #expect(hours.status(at: instant(monday, 9), in: utc) == .open(until: instant(monday, 18)))
        #expect(hours.status(at: instant(monday, 19), in: utc) == .closed(until: instant(tuesday, 8)))
        #expect(hours.status(at: instant(saturday, 13), in: utc) == .closed(until: instant(monday + 7, 8)))
    }

    @Test func listsOfDaysAndOfTimes() throws {
        let week = try #require(OpeningHours("Mo,We,Fr 10:00-12:00,14:00-18:30").schedule)
        #expect(week.spans[.wednesday] == [600..<720, 840..<1_110])
        #expect(week.spans[.tuesday] == nil)
        let spaced = try #require(OpeningHours("Mo-Fr 08:00-12:00, 14:00-18:00").schedule)
        #expect(spaced.spans[.monday] == [480..<720, 840..<1_080], "a space after the comma still lists times")
    }

    @Test func timesWithoutDaysAreEveryDayAndDaysWithoutTimesAllDay() throws {
        let daily = try #require(OpeningHours("08:00-21:00").schedule)
        #expect(Weekday.allCases.allSatisfy { daily.spans[$0] == [480..<1_260] })
        let weekend = try #require(OpeningHours("Sa-Su").schedule)
        #expect(weekend.spans[.sunday] == [0..<1_440])
        #expect(weekend.spans[.monday] == nil)
    }

    @Test func aRangeOfDaysWrapsThroughSunday() throws {
        let week = try #require(OpeningHours("Fr-Mo 10:00-16:00").schedule)
        #expect(Set(week.spans.keys) == [.friday, .saturday, .sunday, .monday])
    }

    @Test func pastMidnightRunsIntoTheNextDay() {
        let hours = OpeningHours("Mo-Th 10:00-24:00; Fr 10:00-01:00; Sa 09:00-01:00; Su 09:00-24:00")
        #expect(hours.schedule?.spans[.friday] == [600..<1_500])
        // Saturday at half past midnight is still Friday night.
        #expect(hours.status(at: instant(saturday, 0, 30), in: utc) == .open(until: instant(saturday, 1)))
        #expect(hours.status(at: instant(saturday, 2), in: utc) == .closed(until: instant(saturday, 9)))
        // Monday to Thursday close at midnight and open at ten.
        #expect(hours.status(at: instant(tuesday, 23), in: utc) == .open(until: instant(tuesday + 1, 0)))
        let late = OpeningHours("18:00-26:00")
        #expect(late.schedule?.spans[.monday] == [1_080..<1_560])
    }

    @Test func offAndClosedCloseTheDaysTheyName() {
        let hours = OpeningHours("Mo-Su 10:00-20:00; Su off")
        #expect(hours.schedule?.spans[.sunday] == nil)
        #expect(hours.schedule?.spans[.saturday] == [600..<1_200])
        #expect(OpeningHours("Mo-Sa 09:00-17:00; Sa closed").schedule?.spans[.saturday] == nil)
        #expect(hours.status(at: instant(sunday, 12), in: utc) == .closed(until: instant(monday + 7, 10)))
    }

    @Test func aLaterRuleReplacesAnEarlierOneAndACommaAddsToIt() {
        let replaced = OpeningHours("Mo-Sa 09:00-19:00; Sa 10:00-17:00")
        #expect(replaced.schedule?.spans[.saturday] == [600..<1_020])
        let added = OpeningHours("Mo-Fr 08:00-12:00, We 14:00-18:00")
        #expect(added.schedule?.spans[.wednesday] == [480..<720, 840..<1_080])
        #expect(added.schedule?.spans[.thursday] == [480..<720])
    }

    @Test func roundTheClock() {
        #expect(OpeningHours("24/7").status(at: instant(monday, 3), in: utc) == .alwaysOpen)
        #expect(OpeningHours("Mo-Su 00:00-24:00").status(at: instant(friday, 3), in: utc) == .alwaysOpen)
    }

    @Test func openNowIsInThePlacesTimeZone() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let hours = OpeningHours("Mo-Fr 09:00-17:00")
        // 08:30 UTC is 09:30 in Paris in November.
        #expect(hours.status(at: instant(monday, 8, 30), in: paris)?.isOpen == true)
        #expect(hours.status(at: instant(monday, 8, 30), in: utc)?.isOpen == false)
    }

    @Test func holidaysAreSetAsideAndSaidSo() {
        let hours = OpeningHours("Mo-Fr 09:00-17:00; PH off")
        #expect(hours.schedule?.spans[.monday] == [540..<1_020])
        #expect(hours.ignoresHolidays)
        #expect(!OpeningHours("Mo-Fr 09:00-17:00").ignoresHolidays)
    }

    /// What the parser does not read leaves no schedule, and nothing
    /// claims to know whether the place is open.
    @Test(arguments: [
        "Jan-Mar Mo-Fr 08:00-12:00", "sunrise-sunset", "Mo-Fr 18:00+", "Mo-Fr 08:00-12:00 \"by appointment\"",
        "Mo-Fr 08:00-18:00 || \"on call\"", "week 1-53/2 Fr 09:00-12:00", "2026 Mo 10:00-11:00", "Mo-Fr 8-18",
        "", "open",
    ])
    func formsItDoesNotReadHaveNoSchedule(text: String) {
        let hours = OpeningHours(text)
        #expect(hours.schedule == nil, "\(text)")
        #expect(hours.status(at: instant(monday, 12), in: utc) == nil)
        #expect(hours.text == text)
    }

    @Test func aRuleALine() {
        #expect(OpeningHours("Mo-Fr 07:30-18:00; Sa 08:00-17:00").lines == ["Mo-Fr 07:30-18:00", "Sa 08:00-17:00"])
    }

    @Test func calendarWeekdaysCountFromSunday() {
        #expect(Weekday(calendarWeekday: 1) == .sunday)
        #expect(Weekday(calendarWeekday: 2) == .monday)
        #expect(Weekday(calendarWeekday: 7) == .saturday)
    }
}
