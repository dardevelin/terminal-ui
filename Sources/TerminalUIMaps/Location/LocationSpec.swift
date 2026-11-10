import Foundation

/// A location provider named in a word, as a command line or a settings
/// file gives one:
///
/// | Spelling | Provider |
/// |----------|----------|
/// | `none` | no location |
/// | `here` | ``ManualLocationProvider`` at a point the app supplies |
/// | `gpx:PATH` | ``GPXReplayProvider`` of the file's track, else its route |
/// | `gpsd`, `gpsd:HOST:PORT` | ``GPSDLocationProvider``, localhost:2947 by default |
/// | `nmea:tcp:HOST:PORT` | ``NMEALocationProvider`` connecting to a server |
/// | `nmea:udp:PORT` | ``NMEALocationProvider`` listening for datagrams |
/// | `corelocation` | ``CoreLocationProvider`` (macOS) |
public enum LocationSpec: Sendable, Hashable, CustomStringConvertible {
    case none
    case here
    case gpx(path: String)
    case gpsd(host: String, port: UInt16)
    case nmeaTCP(host: String, port: UInt16)
    case nmeaUDP(port: UInt16)
    case coreLocation

    /// The provider a spelling names, or nil for one this does not read.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let rest = parts.count > 1 ? parts[1] : nil
        switch parts[0].lowercased() {
        case "none", "off": self = .none
        case "here", "manual": self = .here
        case "corelocation": self = .coreLocation
        case "gpx":
            guard let rest, !rest.isEmpty else { return nil }
            self = .gpx(path: rest)
        case "gpsd":
            guard let rest else {
                self = .gpsd(host: GPSDProtocol.defaultHost, port: GPSDProtocol.defaultPort)
                return
            }
            guard let (host, port) = LocationSpec.hostAndPort(rest) else { return nil }
            self = .gpsd(host: host, port: port)
        case "nmea":
            guard let rest else { return nil }
            let transport = rest.split(separator: ":", maxSplits: 1).map(String.init)
            switch transport.first?.lowercased() {
            case "tcp":
                guard transport.count == 2, let (host, port) = LocationSpec.hostAndPort(transport[1]) else { return nil }
                self = .nmeaTCP(host: host, port: port)
            case "udp":
                let port = transport.count == 2 ? UInt16(transport[1]) : NMEALocationProvider.defaultPort
                guard let port else { return nil }
                self = .nmeaUDP(port: port)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// `HOST:PORT`, the host perhaps a bracketed IPv6 address.
    private static func hostAndPort(_ text: String) -> (String, UInt16)? {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else {
            return nil
        }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    public var description: String {
        switch self {
        case .none: "none"
        case .here: "here"
        case .gpx(let path): "gpx:\(path)"
        case .gpsd(let host, let port): "gpsd:\(host):\(port)"
        case .nmeaTCP(let host, let port): "nmea:tcp:\(host):\(port)"
        case .nmeaUDP(let port): "nmea:udp:\(port)"
        case .coreLocation: "corelocation"
        }
    }

    /// The provider, or nil for `none`. `here` is the point given; a GPX
    /// file is read now and replayed at `replaySpeed`.
    public func makeProvider(here: GeoCoordinate, replaySpeed: Double = 1) throws -> (any LocationProvider)? {
        switch self {
        case .none:
            return nil
        case .here:
            return ManualLocationProvider(coordinate: here)
        case .gpx(let path):
            let document = try GPXDocument(contentsOf: URL(fileURLWithPath: path))
            guard let points = LocationSpec.replayPoints(of: document) else {
                throw LocationError.noData("\(path) has no track, route or waypoints")
            }
            return GPXReplayProvider(track: points, speed: replaySpeed,
                                     name: "replay \(URL(fileURLWithPath: path).lastPathComponent)")
        case .gpsd(let host, let port):
            return GPSDLocationProvider(host: host, port: port)
        case .nmeaTCP(let host, let port):
            return NMEALocationProvider(endpoint: .tcp(host: host, port: port))
        case .nmeaUDP(let port):
            return NMEALocationProvider(endpoint: .udp(port: port))
        case .coreLocation:
            #if canImport(CoreLocation)
            return CoreLocationProvider()
            #else
            throw LocationError.unavailable("Location Services are only on macOS")
            #endif
        }
    }

    /// What a GPX file replays: its first track with points, else its
    /// first route, else its waypoints in order.
    public static func replayPoints(of document: GPXDocument) -> [GPXPoint]? {
        if let track = document.tracks.first(where: { !$0.points.isEmpty }) { return track.points }
        if let route = document.routes.first(where: { !$0.points.isEmpty }) { return route.points }
        return document.waypoints.isEmpty ? nil : document.waypoints
    }
}
