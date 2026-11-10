import Foundation

/// NMEA 0183 position sentences, as a receiver or a phone's GPS-sharing
/// app sends them: `$GPRMC` (recommended minimum: time, status, position,
/// speed, course, date) and `$GPGGA` (fix data: position, quality, HDOP),
/// any talker — GP, GN, GL, GA, GB, BD — accepted. Fields follow NMEA 0183
/// v4.11; the layout is the one gpsd's "NMEA 0183 Revealed"
/// (gpsd.gitlab.io/gpsd/NMEA.html) documents.
///
/// A sentence is `$` + fields separated by commas + `*` + two hex digits,
/// the XOR of every byte between `$` and `*`. A sentence whose checksum is
/// missing or wrong is dropped: on a UDP stream from a phone, a garbled
/// line is otherwise a position kilometres away.
struct NMEADecoder: Sendable {
    /// The HDOP of the last GGA, which RMC does not carry.
    private var horizontalDilution: Double?
    /// Whether an RMC has been seen: once one has, GGA only refines its
    /// accuracy, and a GGA with no date of its own reports nothing.
    private var sawRecommendedMinimum = false
    private let now: @Sendable () -> Date

    /// The user equivalent range error, in metres, an accuracy is HDOP
    /// times: a horizontal error of about HDOP × UERE (Kaplan and Hegarty,
    /// *Understanding GPS/GNSS*, 3rd ed., §11.2). Five metres is a
    /// typical single-frequency receiver's.
    static let userEquivalentRangeError = 5.0

    /// The knot, 1 852 m an hour exactly (the international nautical mile).
    static let metresPerSecondPerKnot = 1_852.0 / 3_600

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// The fields of a sentence whose checksum holds, its first the talker
    /// and type ("GPRMC"); nil for anything else.
    static func fields(of sentence: String) -> [Substring]? {
        let trimmed = sentence.trimmingXMLWhitespace()
        guard trimmed.hasPrefix("$"), let star = trimmed.lastIndex(of: "*") else { return nil }
        let body = trimmed[trimmed.index(after: trimmed.startIndex)..<star]
        let checksumText = trimmed[trimmed.index(after: star)...]
        guard checksumText.count == Checksum.digits, let expected = UInt8(checksumText, radix: Checksum.radix)
        else { return nil }
        let actual = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        guard actual == expected else { return nil }
        return body.split(separator: ",", omittingEmptySubsequences: false)
    }

    private enum Checksum {
        static let digits = 2
        static let radix = 16
    }

    /// The fix a sentence completes, if it does.
    mutating func decode(_ sentence: String) -> LocationFix? {
        guard let fields = NMEADecoder.fields(of: sentence), let kind = fields.first,
              kind.count == Layout.addressLength else { return nil }
        switch kind.suffix(Layout.typeLength) {
        case "RMC": return recommendedMinimum(fields)
        case "GGA": return fixData(fields)
        default: return nil
        }
    }

    private enum Layout {
        /// Two letters of talker, three of sentence type.
        static let addressLength = 5
        static let typeLength = 3

        enum RMC {
            static let time = 1
            static let status = 2
            static let latitude = 3
            static let latitudeHemisphere = 4
            static let longitude = 5
            static let longitudeHemisphere = 6
            static let speedKnots = 7
            static let course = 8
            static let date = 9
            /// NMEA 2.3's mode indicator; `N` is no fix.
            static let mode = 12
            static let minimumFields = 10
        }

        enum GGA {
            static let time = 1
            static let latitude = 2
            static let latitudeHemisphere = 3
            static let longitude = 4
            static let longitudeHemisphere = 5
            static let quality = 6
            static let horizontalDilution = 8
            static let minimumFields = 9
        }
    }

    private mutating func recommendedMinimum(_ fields: [Substring]) -> LocationFix? {
        typealias RMC = Layout.RMC
        guard fields.count >= RMC.minimumFields else { return nil }
        sawRecommendedMinimum = true
        guard fields[RMC.status] == "A" else { return nil }
        if fields.count > RMC.mode, fields[RMC.mode] == "N" { return nil }
        guard let coordinate = NMEADecoder.coordinate(latitude: fields[RMC.latitude],
                                                      fields[RMC.latitudeHemisphere],
                                                      longitude: fields[RMC.longitude],
                                                      fields[RMC.longitudeHemisphere]) else { return nil }
        let speed = Double(fields[RMC.speedKnots]).map { $0 * NMEADecoder.metresPerSecondPerKnot }
        let course = Double(fields[RMC.course])
        let timestamp = NMEADecoder.date(fields[RMC.date], time: fields[RMC.time]) ?? now()
        return LocationFix(coordinate: coordinate,
                           horizontalAccuracy: horizontalDilution.map { $0 * NMEADecoder.userEquivalentRangeError },
                           course: course, speed: speed, timestamp: timestamp, source: .nmea)
    }

    private mutating func fixData(_ fields: [Substring]) -> LocationFix? {
        typealias GGA = Layout.GGA
        guard fields.count >= GGA.minimumFields, let quality = Int(fields[GGA.quality]), quality > 0 else {
            return nil
        }
        horizontalDilution = Double(fields[GGA.horizontalDilution])
        guard !sawRecommendedMinimum,
              let coordinate = NMEADecoder.coordinate(latitude: fields[GGA.latitude], fields[GGA.latitudeHemisphere],
                                                      longitude: fields[GGA.longitude],
                                                      fields[GGA.longitudeHemisphere]) else { return nil }
        let today = now()
        let timestamp = NMEADecoder.time(fields[GGA.time], on: today) ?? today
        return LocationFix(coordinate: coordinate,
                           horizontalAccuracy: horizontalDilution.map { $0 * NMEADecoder.userEquivalentRangeError },
                           timestamp: timestamp, source: .nmea)
    }

    /// `ddmm.mmmm` and `dddmm.mmmm` — degrees then decimal minutes — with
    /// their hemisphere letters.
    static func coordinate(latitude: Substring, _ north: Substring, longitude: Substring,
                           _ east: Substring) -> GeoCoordinate? {
        guard let latitudeDegrees = degrees(latitude, degreeDigits: 2),
              let longitudeDegrees = degrees(longitude, degreeDigits: 3),
              north == "N" || north == "S", east == "E" || east == "W" else { return nil }
        let coordinate = GeoCoordinate(latitude: north == "S" ? -latitudeDegrees : latitudeDegrees,
                                       longitude: east == "W" ? -longitudeDegrees : longitudeDegrees)
        guard abs(coordinate.latitude) <= Degrees.quarterTurn, abs(coordinate.longitude) <= Degrees.halfTurn else {
            return nil
        }
        return coordinate
    }

    private static let minutesPerDegree = 60.0

    private static func degrees(_ field: Substring, degreeDigits: Int) -> Double? {
        guard field.count > degreeDigits, let whole = Double(field.prefix(degreeDigits)),
              let minutes = Double(field.dropFirst(degreeDigits)), minutes < minutesPerDegree else { return nil }
        return whole + minutes / minutesPerDegree
    }

    /// RMC's `ddmmyy` date and `hhmmss.ss` time, UTC. A two-digit year is
    /// taken in 1980–2079: GPS time begins in 1980, so a year from 80 on
    /// is the 1900s.
    static func date(_ dateField: Substring, time timeField: Substring) -> Date? {
        guard dateField.count == DateLayout.dateLength,
              let day = Int(dateField.prefix(2)), let month = Int(dateField.dropFirst(2).prefix(2)),
              let year = Int(dateField.suffix(2)) else { return nil }
        let century = year >= DateLayout.gpsEpochYear ? DateLayout.previousCentury : DateLayout.century
        let days = XSDDateTime.daysFromCivil(year: century + year, month: month, day: day)
        return secondsOfDay(timeField).map { Date(timeIntervalSince1970: Double(days) * DateLayout.secondsPerDay + $0) }
    }

    /// GGA's time of day, on the UTC day of `day`.
    static func time(_ timeField: Substring, on day: Date) -> Date? {
        let midnight = (day.timeIntervalSince1970 / DateLayout.secondsPerDay).rounded(.down) * DateLayout.secondsPerDay
        return secondsOfDay(timeField).map { Date(timeIntervalSince1970: midnight + $0) }
    }

    private static func secondsOfDay(_ field: Substring) -> Double? {
        guard field.count >= DateLayout.timeLength, let hours = Double(field.prefix(2)),
              let minutes = Double(field.dropFirst(2).prefix(2)), let seconds = Double(field.dropFirst(4)) else {
            return nil
        }
        return hours * DateLayout.secondsPerHour + minutes * DateLayout.secondsPerMinute + seconds
    }

    private enum DateLayout {
        static let dateLength = 6
        static let timeLength = 6
        static let century = 2_000
        static let previousCentury = 1_900
        /// 1980, when GPS time begins, as a two-digit year.
        static let gpsEpochYear = 80
        static let secondsPerMinute = 60.0
        static let secondsPerHour = 3_600.0
        static let secondsPerDay = 86_400.0
    }

    /// A sentence's checksum, for writing one: the XOR of its body.
    static func checksum(of body: String) -> String {
        let value = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        let hex = String(value, radix: Checksum.radix, uppercase: true)
        return hex.count < Checksum.digits ? "0" + hex : hex
    }
}

/// Fixes from NMEA sentences over the network: a TCP server to connect to
/// (gpsd's raw port, a phone app serving its GPS), or UDP datagrams
/// arriving on a port (a phone app broadcasting it).
public struct NMEALocationProvider: LocationProvider {
    /// Where the sentences come from.
    public enum Endpoint: Sendable, Hashable {
        /// Connect to a server.
        case tcp(host: String, port: UInt16)
        /// Listen for datagrams on a port, every interface.
        case udp(port: UInt16)
    }

    public let endpoint: Endpoint

    /// The port NMEA-over-IP commonly uses, 10110 (IANA "nmea-0183").
    public static let defaultPort: UInt16 = 10110

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    public var name: String {
        switch endpoint {
        case .tcp(let host, let port): "NMEA tcp \(host):\(port)"
        case .udp(let port): "NMEA udp :\(port)"
        }
    }

    public func fixes() -> AsyncThrowingStream<LocationFix, any Error> {
        LineSocket.stream(endpoint, greeting: nil, state: NMEADecoder()) { decoder, line in
            decoder.decode(line)
        }
    }
}
