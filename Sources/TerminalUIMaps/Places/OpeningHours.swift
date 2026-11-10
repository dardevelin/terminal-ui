import Foundation

/// A place's opening hours, as OpenStreetMap's `opening_hours` tag writes
/// them, read as far as this parser goes.
///
/// The tag's grammar (wiki.openstreetmap.org/wiki/Key:opening_hours/
/// specification) is large. This reads the forms that cover most shops and
/// restaurants:
///
/// - `24/7`;
/// - rules of weekdays and times: `Mo-Fr 08:00-18:00`, `Mo,We,Fr
///   10:00-12:00`, `Tu-Fr 11:45-14:30,18:30-22:30`;
/// - times with no weekdays, every day: `08:00-21:00`;
/// - weekdays with no times, all day: `Sa-Su`;
/// - times past midnight: `Fr 18:00-02:00`, `22:00-24:00`, `18:00-26:00`;
/// - `off` and `closed`: `Su off`;
/// - rules after `;` replacing earlier ones for the days they name, and
///   rules after `,` adding to them: `Mo-Sa 09:00-19:00; Sa 10:00-17:00`.
///
/// It does not read months, dates, weeks, years, sun times (`sunrise`),
/// open ends (`18:00+`), comments, or `||` fallbacks: hours that use them
/// keep their ``text`` and have no ``schedule``, and nothing claims to know
/// whether the place is open. Rules for public or school holidays (`PH
/// off`, `SH 10:00-12:00`) are set aside — this has no calendar of them —
/// and ``ignoresHolidays`` says so.
public struct OpeningHours: Sendable, Hashable {
    /// The tag's value as given.
    public let text: String
    /// The week the hours describe, or nil where they use a form this does
    /// not read.
    public let schedule: WeeklySchedule?
    /// Whether a rule for public or school holidays was set aside.
    public let ignoresHolidays: Bool

    public init(_ text: String) {
        self.text = text
        var parser = OpeningHoursParser(text)
        if let parsed = parser.parse() {
            schedule = parsed.schedule
            ignoresHolidays = parsed.ignoresHolidays
        } else {
            schedule = nil
            ignoresHolidays = false
        }
    }

    /// The rules one to a line, for a card: `;` separates them.
    public var lines: [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the place is open at `date`, in the place's `timeZone`, and
    /// until when; nil where the hours could not be read.
    public func status(at date: Date, in timeZone: TimeZone) -> OpeningStatus? {
        schedule?.status(at: date, in: timeZone)
    }
}

/// A day of the week, Monday first as `opening_hours` orders them.
public enum Weekday: Int, Sendable, Hashable, CaseIterable, Comparable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    /// The tag's two-letter name.
    public var abbreviation: String {
        ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"][rawValue]
    }

    /// The day's short English name, for a card.
    public var shortName: String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][rawValue]
    }

    /// The day after.
    public var next: Weekday { Weekday(rawValue: (rawValue + 1) % Weekday.allCases.count) ?? .monday }

    init?(abbreviation: Substring) {
        guard let index = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"].firstIndex(of: String(abbreviation)) else {
            return nil
        }
        self.init(rawValue: index)
    }

    /// The weekday of `Calendar.component(.weekday)`, which counts Sunday
    /// as 1.
    init(calendarWeekday: Int) {
        self = Weekday(rawValue: (calendarWeekday + Weekday.mondayOffset) % Weekday.allCases.count) ?? .monday
    }

    /// Calendar's 2 (Monday) to this enum's 0: add five, mod seven.
    private static let mondayOffset = 5

    public static func < (left: Weekday, right: Weekday) -> Bool { left.rawValue < right.rawValue }
}

/// When a place is open, a week at a time: for each weekday the spans it is
/// open, in minutes from that day's midnight. A span may run past 1440,
/// into the next day, as `Fr 18:00-02:00` does.
public struct WeeklySchedule: Sendable, Hashable {
    public var spans: [Weekday: [Range<Int>]]

    public static let minutesPerDay = 1_440

    public init(spans: [Weekday: [Range<Int>]]) {
        self.spans = spans.filter { !$0.value.isEmpty }
    }

    /// Open every minute of every day.
    public var isAlwaysOpen: Bool {
        let week = merged(Weekday.allCases.flatMap { day in
            (spans[day] ?? []).map { ($0.lowerBound + day.rawValue * Self.minutesPerDay)..<($0.upperBound + day.rawValue
                * Self.minutesPerDay) }
        })
        return week.first.map { $0.lowerBound <= 0 && $0.upperBound >= Self.minutesPerWeek } ?? false
    }

    private static let minutesPerWeek = 7 * minutesPerDay
    private static let secondsPerMinute = 60

    /// Whether the place is open at `date` in `timeZone`, and when that
    /// next changes.
    public func status(at date: Date, in timeZone: TimeZone) -> OpeningStatus {
        if isAlwaysOpen { return .alwaysOpen }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: date)
        let minute = Int(date.timeIntervalSince(midnight)) / Self.secondsPerMinute
        let today = Weekday(calendarWeekday: calendar.component(.weekday, from: date))
        // Every span from yesterday's (which may run into today) to a week
        // on, in minutes from today's midnight, overlapping ones joined.
        var timeline: [Range<Int>] = []
        var day = Weekday(rawValue: (today.rawValue + Weekday.allCases.count - 1) % Weekday.allCases.count) ?? today
        for offset in -1...Weekday.allCases.count {
            for span in spans[day] ?? [] {
                let start = offset * Self.minutesPerDay
                timeline.append((start + span.lowerBound)..<(start + span.upperBound))
            }
            day = day.next
        }
        let joined = merged(timeline)
        func instant(_ minutes: Int) -> Date {
            calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? date
        }
        if let current = joined.first(where: { $0.contains(minute) }) {
            return .open(until: instant(current.upperBound))
        }
        if let next = joined.first(where: { $0.lowerBound > minute }) {
            return .closed(until: instant(next.lowerBound))
        }
        return .closed(until: nil)
    }

    private func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Whether a place is open now.
public enum OpeningStatus: Sendable, Hashable {
    /// Open every hour of the week.
    case alwaysOpen
    /// Open, until the date given.
    case open(until: Date)
    /// Closed, until the date given, or nil where it opens on none of the
    /// next seven days.
    case closed(until: Date?)

    public var isOpen: Bool {
        switch self {
        case .alwaysOpen, .open: true
        case .closed: false
        }
    }
}

/// The reader behind ``OpeningHours``: a rule at a time, a token at a time,
/// failing on anything outside the subset it documents.
private struct OpeningHoursParser {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    private enum Tokens {
        static let alwaysOpen = "24/7"
        static let closedWords: Set<String> = ["off", "closed"]
        static let holidayPrefixes = ["PH", "SH"]
        static let timeSeparator: Character = ":"
        static let rangeSeparator: Character = "-"
        static let listSeparator: Character = ","
        static let ruleSeparator: Character = ";"
        static let fallbackSeparator = "||"
        static let minutesPerHour = 60
        /// The latest an hour may be written: `26:00` is 2 a.m. the next
        /// day, which the specification allows past 24.
        static let latestHour = 48
    }

    /// One rule: the days it covers (every day when it names none), and
    /// what it says of them.
    private struct Rule {
        var days: Set<Weekday>
        var spans: [Range<Int>]
        var isAdditional: Bool
    }

    mutating func parse() -> (schedule: WeeklySchedule, ignoresHolidays: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(Tokens.fallbackSeparator), !trimmed.contains("\"") else {
            return nil
        }
        var schedule: [Weekday: [Range<Int>]] = [:]
        var ignoresHolidays = false
        for normal in trimmed.split(separator: Tokens.ruleSeparator) {
            let piece = normal.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if Tokens.holidayPrefixes.contains(where: { piece.hasPrefix($0) }) {
                ignoresHolidays = true
                continue
            }
            guard let rules = Self.rules(in: piece) else { return nil }
            for rule in rules {
                for day in rule.days {
                    if rule.isAdditional {
                        schedule[day, default: []] += rule.spans
                    } else {
                        schedule[day] = rule.spans
                    }
                }
            }
        }
        return (WeeklySchedule(spans: schedule), ignoresHolidays)
    }

    /// The rules of one `;`-separated piece: the first, and those a `,`
    /// before a weekday adds to it.
    private static func rules(in piece: String) -> [Rule]? {
        if piece == Tokens.alwaysOpen {
            return [Rule(days: Set(Weekday.allCases), spans: [0..<WeeklySchedule.minutesPerDay], isAdditional: false)]
        }
        var rules: [Rule] = []
        var words = piece.split(separator: " ").map(String.init)
        var isAdditional = false
        while !words.isEmpty {
            var days = Set(Weekday.allCases)
            if let first = words.first, let selected = weekdays(first) {
                days = selected
                words.removeFirst()
            }
            var spans = [0..<WeeklySchedule.minutesPerDay]
            var addsAnother = false
            if let first = words.first {
                if Tokens.closedWords.contains(first.lowercased()) {
                    spans = []
                    words.removeFirst()
                } else {
                    // `10:00-12:00, 14:00-18:00` goes on listing times;
                    // `10:00-12:00, Sa 10:00-14:00` ends the rule with
                    // the comma and begins an additional one.
                    spans = []
                    while let word = words.first, addsAnother || spans.isEmpty, weekdays(word) == nil {
                        var timeText = word
                        addsAnother = timeText.hasSuffix(String(Tokens.listSeparator))
                        if addsAnother { timeText.removeLast() }
                        guard let parsed = times(timeText) else { return nil }
                        spans += parsed
                        words.removeFirst()
                    }
                    guard !spans.isEmpty else { return nil }
                }
            }
            rules.append(Rule(days: days, spans: spans, isAdditional: isAdditional))
            if words.isEmpty { break }
            guard addsAnother || words.first.map({ weekdays($0) != nil }) == true else { return nil }
            isAdditional = true
        }
        return rules
    }

    /// `Mo-Fr`, `Mo,We,Fr`, `Sa`: the days, or nil for a word that is not
    /// a weekday selector.
    private static func weekdays(_ word: String) -> Set<Weekday>? {
        var days = Set<Weekday>()
        for part in word.split(separator: Tokens.listSeparator) {
            let ends = part.split(separator: Tokens.rangeSeparator)
            guard let first = ends.first.flatMap(Weekday.init(abbreviation:)) else { return nil }
            guard ends.count == 2 else {
                guard ends.count == 1 else { return nil }
                days.insert(first)
                continue
            }
            guard let last = Weekday(abbreviation: ends[1]) else { return nil }
            var day = first
            days.insert(day)
            while day != last {
                day = day.next
                days.insert(day)
            }
        }
        return days.isEmpty ? nil : days
    }

    /// `08:00-12:00,13:00-18:00`: the spans, an end at or before its start
    /// running into the next day.
    private static func times(_ word: String) -> [Range<Int>]? {
        var spans: [Range<Int>] = []
        for part in word.split(separator: Tokens.listSeparator) {
            let ends = part.split(separator: Tokens.rangeSeparator)
            guard ends.count == 2, let start = minutes(ends[0]), var end = minutes(ends[1]) else { return nil }
            if end <= start { end += WeeklySchedule.minutesPerDay }
            spans.append(start..<end)
        }
        return spans.isEmpty ? nil : spans
    }

    /// `HH:MM` as minutes after midnight.
    private static func minutes(_ text: Substring) -> Int? {
        let parts = text.split(separator: Tokens.timeSeparator)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...Tokens.latestHour).contains(hour), (0..<Tokens.minutesPerHour).contains(minute) else { return nil }
        return hour * Tokens.minutesPerHour + minute
    }
}
