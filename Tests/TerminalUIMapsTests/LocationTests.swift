#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing
@testable import TerminalUIMaps

/// A sentence with its checksum appended, as a receiver sends it.
private func sentence(_ body: String) -> String { "$\(body)*\(NMEADecoder.checksum(of: body))" }

@Suite("NMEA 0183")
struct NMEATests {
    private let fixedNow = Date(timeIntervalSince1970: 1_794_301_200)

    @Test func aChecksumIsTheXorOfTheBody() {
        // The worked example in gpsd's "NMEA 0183 Revealed".
        let text = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
        #expect(NMEADecoder.fields(of: text)?.first == "GPGGA")
        #expect(NMEADecoder.fields(of: text.replacingOccurrences(of: "*47", with: "*48")) == nil)
        #expect(NMEADecoder.fields(of: "$GPGGA,123519,4807.038,N") == nil, "no checksum, no sentence")
    }

    @Test func recommendedMinimumGivesPositionCourseSpeedAndTime() throws {
        var decoder = NMEADecoder(now: { [fixedNow] in fixedNow })
        let decoded = decoder.decode(sentence("GNRMC,081836.50,A,3751.65,S,14507.36,E,10.0,360.0,130998,011.3,E,A"))
        let fix = try #require(decoded)
        #expect(abs(fix.coordinate.latitude - -(37 + 51.65 / 60)) < 1e-9)
        #expect(abs(fix.coordinate.longitude - (145 + 7.36 / 60)) < 1e-9)
        // A knot is a nautical mile, 1852 m, an hour. Named, so the type
        // checker is not left to try every literal type in one expression:
        // Linux's took longer than it allows on CI's runner.
        let metresPerSecondInAKnot: Double = 1_852.0 / 3_600.0
        let expectedSpeed: Double = 10 * metresPerSecondInAKnot
        #expect(abs((fix.speed ?? 0) - expectedSpeed) < 1e-9)
        #expect(fix.course == 360)
        #expect(fix.timestamp == XSDDateTime.parse("1998-09-13T08:18:36.5Z"))
        #expect(fix.horizontalAccuracy == nil, "RMC carries no dilution")
        #expect(fix.source == .nmea)
    }

    @Test func fixDataGivesTheAccuracyLaterRecommendedMinimumsUse() throws {
        var decoder = NMEADecoder(now: { [fixedNow] in fixedNow })
        let firstDecoded = decoder.decode(sentence("GPGGA,090000,4807.038,N,01131.000,E,1,08,1.5,545.4,M,46.9,M,,"))
        let first = try #require(firstDecoded)
        #expect(first.horizontalAccuracy == 1.5 * NMEADecoder.userEquivalentRangeError)
        #expect(first.timestamp == fixedNow, "a GGA's time of day, on today's date")
        let nextDecoded = decoder.decode(sentence("GPRMC,090001,A,4807.038,N,01131.000,E,0.5,54.7,101126,,"))
        let next = try #require(nextDecoded)
        #expect(next.horizontalAccuracy == 1.5 * NMEADecoder.userEquivalentRangeError)
        let refined = decoder.decode(sentence("GPGGA,090001,4807.038,N,01131.000,E,1,08,1.0,545.4,M,46.9,M,,"))
        #expect(refined == nil,
                "once RMC flows, GGA only refines it")
    }

    @Test(arguments: ["GPRMC,081836,V,3751.65,S,14507.36,E,000.0,360.0,130998,011.3,E",
                      "GPRMC,081836,A,3751.65,S,14507.36,E,000.0,360.0,130998,011.3,E,N",
                      "GPGGA,090000,4807.038,N,01131.000,E,0,00,99.9,,M,,M,,",
                      "GPRMC,081836,A,9951.65,S,14507.36,E,000.0,360.0,130998,011.3,E",
                      "GPGSV,3,1,11,03,03,111,00,04,15,270,00,06,01,010,00,13,06,292,00"])
    func reportsNothingWithoutAValidFix(body: String) {
        var decoder = NMEADecoder()
        let decoded = decoder.decode(sentence(body))
        #expect(decoded == nil)
    }
}

@Suite("gpsd")
struct GPSDTests {
    @Test func aTPVIsAFix() throws {
        let line = #"{"class":"TPV","device":"/dev/ttyUSB0","mode":3,"time":"2026-11-10T09:00:00.000Z","#
            + #""lat":46.498293369,"lon":7.567411672,"alt":1343.127,"eph":3.5,"epv":32.321,"track":10.3788,"#
            + #""speed":0.091,"climb":-0.085}"#
        let fix = try #require(GPSDProtocol.fix(fromLine: line))
        #expect(fix.coordinate == GeoCoordinate(latitude: 46.498293369, longitude: 7.567411672))
        #expect(fix.horizontalAccuracy == 3.5 && fix.course == 10.3788 && fix.speed == 0.091)
        #expect(fix.timestamp == Date(timeIntervalSince1970: 1_794_301_200))
        #expect(fix.source == .gpsd)
    }

    @Test func newerDaemonsGiveTheErrorAsLongitudeAndLatitude() throws {
        let fix = try #require(GPSDProtocol.fix(fromLine: #"{"class":"TPV","mode":2,"lat":1,"lon":2,"epx":4,"epy":6}"#))
        #expect(fix.horizontalAccuracy == 6)
    }

    @Test(arguments: [#"{"class":"VERSION","release":"3.25"}"#, #"{"class":"TPV","mode":1}"#,
                      #"{"class":"TPV","mode":3,"lat":1}"#, "not json", #"{"class":"SKY","satellites":[]}"#])
    func otherReportsAreNotFixes(line: String) {
        #expect(GPSDProtocol.fix(fromLine: line) == nil)
    }

    /// A gpsd stand-in on the loopback interface, on a thread of its own:
    /// it reads the client's WATCH, answers with what a daemon sends, and
    /// hangs up.
    @Test func theProviderWatchesAndStreamsFixesOverTCP() async throws {
        let server = try LoopbackServer(lines: [
            #"{"class":"VERSION","release":"3.25","proto_major":3,"proto_minor":15}"#,
            #"{"class":"TPV","mode":3,"lat":51.5,"lon":-0.12,"eph":4,"speed":3,"track":90}"#,
            #"{"class":"TPV","mode":3,"lat":51.5001,"lon":-0.12,"eph":4}"#,
        ])
        var fixes: [LocationFix] = []
        do {
            for try await fix in GPSDLocationProvider(host: "127.0.0.1", port: server.port).fixes() {
                fixes.append(fix)
            }
            Issue.record("a closed connection ends the stream with an error")
        } catch let error as LocationError {
            #expect(error == .connection("the server closed the connection"))
        }
        #expect(fixes.map(\.coordinate.latitude) == [51.5, 51.5001])
        #expect(await server.received.hasPrefix(GPSDProtocol.watchCommand))
    }

    @Test func aRefusedConnectionEndsTheStreamWithWhy() async throws {
        let port = try LoopbackServer.unusedPort()
        await #expect(throws: LocationError.self) {
            for try await _ in GPSDLocationProvider(host: "127.0.0.1", port: port).fixes() {}
        }
    }
}

/// A one-connection TCP server on 127.0.0.1 at a port the system picks.
private final class LoopbackServer: Sendable {
    let port: UInt16
    private let finished: AsyncStream<String>

    init(lines: [String]) throws {
        let listener = try LoopbackServer.listeningSocket()
        port = try LoopbackServer.port(of: listener)
        let (stream, continuation) = AsyncStream<String>.makeStream()
        finished = stream
        let thread = Thread {
            let connection = accept(listener, nil, nil)
            close(listener)
            guard connection >= 0 else {
                continuation.finish()
                return
            }
            var buffer = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(connection, &buffer, buffer.count)
            let received = String(decoding: buffer.prefix(max(0, bytesRead)), as: UTF8.self)
            for line in lines {
                let bytes = Array((line + "\r\n").utf8)
                _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            }
            close(connection)
            continuation.yield(received)
            continuation.finish()
        }
        thread.start()
    }

    /// What the client sent before the server answered.
    var received: String {
        get async {
            for await text in finished { return text }
            return ""
        }
    }

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    struct Failed: Error {}

    private static func listeningSocket() throws -> Int32 {
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { throw Failed() }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw Failed()
        }
        return descriptor
    }

    private static func port(of descriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw Failed() }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A port nothing listens on: one the system handed out and took back.
    static func unusedPort() throws -> UInt16 {
        let descriptor = try listeningSocket()
        defer { close(descriptor) }
        return try port(of: descriptor)
    }
}

@Suite("GPX replay")
struct GPXReplayTests {
    private let plane = LocalPlane(reference: GeoCoordinate(latitude: 0.01, longitude: 0.01))

    @Test func aTimelineInterpolatesBetweenPoints() throws {
        let timeline = TrackTimeline(points: [plane.reference, plane.coordinate(east: 0, north: 100)], offsets: [0, 10])
        let middle = try #require(timeline.sample(at: 5))
        #expect(GeoMeasure.distance(middle.coordinate, plane.coordinate(east: 0, north: 50)) < 0.01)
        #expect(abs(GeoMeasure.turn(from: 0, to: middle.course ?? 180)) < 0.01, "due north")
        #expect(abs((middle.speed ?? 0) - 10) < 0.01)
        #expect(timeline.sample(at: 99)?.coordinate == plane.coordinate(east: 0, north: 100))
    }

    @Test func pointsWithoutTimesAreTimedAtTheGivenSpeed() {
        let track = [GPXPoint(coordinate: plane.reference), GPXPoint(coordinate: plane.coordinate(east: 300, north: 0))]
        #expect(abs(TrackTimeline(track, speed: 10).duration - 30) < 0.01)
    }

    @Test func aReplayReportsEachIntervalAndSleepsItOverTheSpeed() async throws {
        let clock = ManualClock()
        let start = Date(timeIntervalSince1970: 1_000)
        let timeline = TrackTimeline(points: [plane.reference, plane.coordinate(east: 0, north: 100)], offsets: [0, 10])
        let replay = GPXReplayProvider(timeline: timeline, speed: 4, interval: .seconds(2), clock: clock,
                                       startDate: start)
        var fixes: [LocationFix] = []
        for try await fix in replay.fixes() { fixes.append(fix) }
        #expect(fixes.map(\.timestamp.timeIntervalSince1970) == [1_000, 1_002, 1_004, 1_006, 1_008, 1_010])
        #expect(clock.sleeps == (1...5).map { .milliseconds(500 * $0) }, "two track seconds at four times speed")
        #expect(fixes.allSatisfy { $0.source == .replay && $0.horizontalAccuracy == 5 })
        #expect(GeoMeasure.distance(fixes[2].coordinate, plane.coordinate(east: 0, north: 40)) < 0.01)
    }

    @Test func anEmptyTrackSaysSo() async {
        let replay = GPXReplayProvider(timeline: TrackTimeline(points: [], offsets: []), clock: ManualClock())
        await #expect(throws: LocationError.self) { for try await _ in replay.fixes() {} }
    }
}

@Suite("Location specs")
struct LocationSpecTests {
    @Test(arguments: [
        ("none", LocationSpec.none), ("here", .here), ("corelocation", .coreLocation),
        ("gpx:/tmp/a:b.gpx", .gpx(path: "/tmp/a:b.gpx")),
        ("gpsd", .gpsd(host: "localhost", port: 2947)), ("gpsd:10.0.0.2:3000", .gpsd(host: "10.0.0.2", port: 3000)),
        ("gpsd:[::1]:2947", .gpsd(host: "::1", port: 2947)),
        ("nmea:tcp:phone.local:11123", .nmeaTCP(host: "phone.local", port: 11123)),
        ("nmea:udp:10110", .nmeaUDP(port: 10110)), ("nmea:udp", .nmeaUDP(port: 10110)),
    ])
    func readsEverySpelling(text: String, spec: LocationSpec) {
        #expect(LocationSpec(text) == spec)
        #expect(LocationSpec(spec.description) == spec)
    }

    @Test(arguments: ["gpx", "gpx:", "gpsd:host", "nmea", "nmea:tcp:host", "nmea:serial:x", "satellite"])
    func refusesWhatItDoesNotKnow(text: String) {
        #expect(LocationSpec(text) == nil)
    }

    @Test func iAmHereIsOneFix() async throws {
        let here = GeoCoordinate(latitude: 1, longitude: 2)
        let provider = try #require(try LocationSpec.here.makeProvider(here: here))
        var fixes: [LocationFix] = []
        for try await fix in provider.fixes() { fixes.append(fix) }
        #expect(fixes.map(\.coordinate) == [here] && fixes.first?.source == .manual)
    }
}
