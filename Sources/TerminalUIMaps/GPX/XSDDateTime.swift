import Foundation

/// The `xsd:dateTime` a GPX `<time>` holds (W3C XML Schema Part 2 §3.2.7,
/// the ISO 8601 profile `YYYY-MM-DDThh:mm:ss[.s+][Z|±hh:mm]`), read and
/// written in pure arithmetic so the same text gives the same instant on
/// every system. A time with no zone is taken as UTC, as GPX 1.1 says
/// times are.
enum XSDDateTime {
    /// The instant a date-time names, or nil for text that is not one.
    static func parse(_ text: String) -> Date? {
        let characters = Array(text.trimmingXMLWhitespace().utf8)
        var reader = Digits(bytes: characters)
        guard let year = reader.number(count: Width.year), reader.take("-"),
              let month = reader.number(count: Width.field), reader.take("-"),
              let day = reader.number(count: Width.field), reader.take("T"),
              let hour = reader.number(count: Width.field), reader.take(":"),
              let minute = reader.number(count: Width.field), reader.take(":"),
              let second = reader.number(count: Width.field),
              (1...Calendar.months).contains(month), (1...Calendar.longestMonth).contains(day),
              hour <= Calendar.lastHour, minute <= Calendar.lastMinute, second <= Calendar.lastSecond
        else { return nil }
        var fraction = 0.0
        if reader.take(".") {
            var scale = 1.0
            var any = false
            while let digit = reader.digit() {
                scale /= Double(Calendar.decimalBase)
                fraction += Double(digit) * scale
                any = true
            }
            guard any else { return nil }
        }
        var offsetSeconds = 0
        if reader.take("Z") {
            offsetSeconds = 0
        } else if let sign = reader.sign() {
            guard let hours = reader.number(count: Width.field), reader.take(":"),
                  let minutes = reader.number(count: Width.field) else { return nil }
            offsetSeconds = sign * (hours * Calendar.secondsPerHour + minutes * Calendar.secondsPerMinute)
        }
        guard reader.isAtEnd else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * Calendar.secondsPerDay + hour * Calendar.secondsPerHour
            + minute * Calendar.secondsPerMinute + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// The instant in UTC, `Z`-suffixed, with milliseconds when it has any.
    static func format(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = Int(interval.rounded(.down))
        var milliseconds = Int(((interval - Double(seconds)) * Double(Calendar.millisecondsPerSecond)).rounded())
        if milliseconds == Calendar.millisecondsPerSecond {
            seconds += 1
            milliseconds = 0
        }
        let days = Int((Double(seconds) / Double(Calendar.secondsPerDay)).rounded(.down))
        let secondOfDay = seconds - days * Calendar.secondsPerDay
        let (year, month, day) = civilFromDays(days)
        let hour = secondOfDay / Calendar.secondsPerHour
        let minute = secondOfDay % Calendar.secondsPerHour / Calendar.secondsPerMinute
        let second = secondOfDay % Calendar.secondsPerMinute
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        var text = "\(padded(year, Width.year))-\(padded(month, Width.field))-\(padded(day, Width.field))"
            + "T\(padded(hour, Width.field)):\(padded(minute, Width.field)):\(padded(second, Width.field))"
        if milliseconds > 0 { text += ".\(padded(milliseconds, Width.milliseconds))" }
        return text + "Z"
    }

    private enum Width {
        static let year = 4
        static let field = 2
        static let milliseconds = 3
    }

    private enum Calendar {
        static let months = 12
        static let longestMonth = 31
        static let lastHour = 23
        static let lastMinute = 59
        /// 60 for a leap second, which the schema allows.
        static let lastSecond = 60
        static let decimalBase = 10
        static let secondsPerMinute = 60
        static let secondsPerHour = 3_600
        static let secondsPerDay = 86_400
        static let millisecondsPerSecond = 1_000
        /// Days in a 400-year era of the proleptic Gregorian calendar.
        static let daysPerEra = 146_097
        static let yearsPerEra = 400
        /// Days from 0000-03-01 to 1970-01-01.
        static let epochShift = 719_468
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date — Howard
    /// Hinnant's `days_from_civil` ("chrono-Compatible Low-Level Date
    /// Algorithms"), which counts years from March so the leap day ends
    /// the year.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - (Calendar.yearsPerEra - 1)) / Calendar.yearsPerEra
        let yearOfEra = shiftedYear - era * Calendar.yearsPerEra
        let monthFromMarch = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * Calendar.daysPerEra + dayOfEra - Calendar.epochShift
    }

    /// The inverse, Hinnant's `civil_from_days`.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + Calendar.epochShift
        let era = (shifted >= 0 ? shifted : shifted - (Calendar.daysPerEra - 1)) / Calendar.daysPerEra
        let dayOfEra = shifted - era * Calendar.daysPerEra
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        let year = yearOfEra + era * Calendar.yearsPerEra + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private struct Digits {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position == bytes.count }

        mutating func digit() -> Int? {
            guard position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) else {
                return nil
            }
            defer { position += 1 }
            return Int(bytes[position] - UInt8(ascii: "0"))
        }

        mutating func number(count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let digit = digit() else { return nil }
                value = value * Calendar.decimalBase + digit
            }
            return value
        }

        mutating func take(_ literal: Unicode.Scalar) -> Bool {
            guard position < bytes.count, bytes[position] == UInt8(ascii: literal) else { return false }
            position += 1
            return true
        }

        mutating func sign() -> Int? {
            if take("+") { return 1 }
            if take("-") { return -1 }
            return nil
        }
    }
}
