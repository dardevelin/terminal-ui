import Foundation

/// The gpsd JSON protocol (gpsd.gitlab.io/gpsd/gpsd_json.html): a client
/// sends `?WATCH={"enable":true,"json":true};` and the daemon streams one
/// JSON object a line, each named by its `class`. A TPV — time, position,
/// velocity — object is a fix.
public enum GPSDProtocol {
    /// The daemon's registered port (IANA "gpsd", 2947/tcp).
    public static let defaultPort: UInt16 = 2947
    public static let defaultHost = "localhost"

    /// The command that asks for reports as JSON.
    public static let watchCommand = "?WATCH={\"enable\":true,\"json\":true};\n"

    /// TPV's `mode`: 0 unknown, 1 no fix, 2 a 2D fix, 3 a 3D fix.
    static let twoDimensionalFix = 2

    private struct Report: Decodable {
        var `class`: String
        var mode: Int?
        var time: String?
        var lat: Double?
        var lon: Double?
        /// Degrees from true north.
        var track: Double?
        /// Metres a second.
        var speed: Double?
        /// Estimated horizontal position error, metres. Newer daemons
        /// also give `epx` and `epy`, the longitude and latitude errors.
        var eph: Double?
        var epx: Double?
        var epy: Double?
    }

    /// The fix a line reports, or nil for a line that is not a TPV with a
    /// position — a VERSION, a DEVICES, a SKY, or a TPV of mode below 2.
    /// `now` stamps a TPV that gives no time.
    public static func fix(fromLine line: String, now: Date = Date()) -> LocationFix? {
        guard let report = try? JSONDecoder().decode(Report.self, from: Data(line.utf8)),
              report.class == "TPV", let mode = report.mode, mode >= twoDimensionalFix,
              let latitude = report.lat, let longitude = report.lon else { return nil }
        let accuracy = report.eph ?? both(report.epx, report.epy).map { max($0, $1) }
        return LocationFix(coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                           horizontalAccuracy: accuracy, course: report.track, speed: report.speed,
                           timestamp: report.time.flatMap(XSDDateTime.parse) ?? now, source: .gpsd)
    }
}

private func both(_ first: Double?, _ second: Double?) -> (Double, Double)? {
    guard let first, let second else { return nil }
    return (first, second)
}

/// Fixes from a gpsd daemon over TCP.
public struct GPSDLocationProvider: LocationProvider {
    public let host: String
    public let port: UInt16

    public init(host: String = GPSDProtocol.defaultHost, port: UInt16 = GPSDProtocol.defaultPort) {
        self.host = host
        self.port = port
    }

    public var name: String { "gpsd \(host):\(port)" }

    public func fixes() -> AsyncThrowingStream<LocationFix, any Error> {
        LineSocket.stream(.tcp(host: host, port: port), greeting: GPSDProtocol.watchCommand, state: ()) { _, line in
            GPSDProtocol.fix(fromLine: line)
        }
    }
}
