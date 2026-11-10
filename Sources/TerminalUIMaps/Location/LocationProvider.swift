import Foundation

/// Where a fix came from.
public enum LocationSource: String, Sendable, Hashable, Codable {
    /// A recorded track played back.
    case replay
    /// The gpsd daemon.
    case gpsd
    /// NMEA 0183 sentences from a receiver or a phone.
    case nmea
    /// Apple's Location Services.
    case coreLocation
    /// Set by hand: "I am here".
    case manual
}

/// One position report: where, how sure, which way and how fast, and when
/// — the fields CoreLocation's `CLLocation` and gpsd's TPV report share.
public struct LocationFix: Sendable, Hashable {
    /// Where the source reports the position to be.
    public var coordinate: GeoCoordinate
    /// The radius, in metres, the true position is likely within; nil
    /// where the source does not say.
    public var horizontalAccuracy: Double?
    /// The direction of travel, degrees clockwise from true north; nil when
    /// unknown or standing still.
    public var course: Double?
    /// Metres a second over the ground; nil when unknown.
    public var speed: Double?
    /// When the position was measured.
    public var timestamp: Date
    /// Which kind of provider reported the fix.
    public var source: LocationSource

    /// A fix at `coordinate`, measured at `timestamp`, with whichever of
    /// accuracy, course and speed the source gives.
    public init(coordinate: GeoCoordinate, horizontalAccuracy: Double? = nil, course: Double? = nil,
                speed: Double? = nil, timestamp: Date, source: LocationSource) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
        self.timestamp = timestamp
        self.source = source
    }
}

/// Answers "where am I?", as a stream of fixes.
///
/// The stream runs until the provider has no more to say — a replay that
/// reached its end — or fails: a connection refused or dropped ends it
/// with the error, so the app can say why the position stopped. Cancelling
/// the task that iterates it stops the provider.
public protocol LocationProvider: Sendable {
    /// A short name for the status bar: "gpsd localhost:2947".
    var name: String { get }

    /// Fixes as they arrive. Each call starts a stream of its own.
    func fixes() -> AsyncThrowingStream<LocationFix, any Error>
}

/// Why a location provider stopped.
public enum LocationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A connection could not be made or was lost.
    case connection(String)
    /// The platform's location service refused, or is off.
    case notAuthorized(String)
    /// The source has nothing to give: a track with no points.
    case noData(String)
    /// This build or system cannot offer the provider.
    case unavailable(String)

    /// The reason, as the provider worded it.
    public var description: String {
        switch self {
        case .connection(let reason): reason
        case .notAuthorized(let reason): reason
        case .noData(let reason): reason
        case .unavailable(let reason): reason
        }
    }
}

/// "I am here": the one position it is given, once.
public struct ManualLocationProvider: LocationProvider {
    /// The point every fix reports.
    public let coordinate: GeoCoordinate
    private let now: @Sendable () -> Date

    /// A provider that reports `coordinate`, stamped with the time `now`
    /// gives when the stream starts.
    public init(coordinate: GeoCoordinate, now: @escaping @Sendable () -> Date = { Date() }) {
        self.coordinate = coordinate
        self.now = now
    }

    /// "here".
    public var name: String { "here" }

    /// The single fix, then the end of the stream. Its accuracy is nil — a
    /// person pointing at a map — so navigation never judges it off route.
    public func fixes() -> AsyncThrowingStream<LocationFix, any Error> {
        let fix = LocationFix(coordinate: coordinate, timestamp: now(), source: .manual)
        return AsyncThrowingStream { continuation in
            continuation.yield(fix)
            continuation.finish()
        }
    }
}
