import Foundation

/// A recorded track as a timeline: where the traveller was at each moment
/// from its start, between its points by straight-line interpolation.
public struct TrackTimeline: Sendable, Equatable {
    /// The points, each with its seconds from the start.
    public let points: [GeoCoordinate]
    public let offsets: [Double]

    /// The speed a track with no times is taken to be travelled at, in
    /// metres a second: 30 km/h, a town's driving speed.
    public static let defaultSpeed = 30_000.0 / 3_600

    /// A timeline of track points. Their own times are kept when every
    /// point has one and they never run backwards; otherwise the track is
    /// timed as if travelled at `speed` throughout.
    public init(_ track: [GPXPoint], speed: Double = TrackTimeline.defaultSpeed) {
        let times = track.compactMap(\.time)
        let timed = times.count == track.count && !times.isEmpty
            && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
        if timed, let start = times.first {
            self.init(points: track.map(\.coordinate), offsets: times.map { $0.timeIntervalSince(start) })
        } else {
            self.init(coordinates: track.map(\.coordinate), speed: speed)
        }
    }

    /// A timeline of a line travelled at a steady speed.
    public init(coordinates: [GeoCoordinate], speed: Double = TrackTimeline.defaultSpeed) {
        var offsets: [Double] = []
        var elapsed = 0.0
        for (index, coordinate) in coordinates.enumerated() {
            if index > 0 { elapsed += GeoMeasure.distance(coordinates[index - 1], coordinate) / max(speed, .ulpOfOne) }
            offsets.append(elapsed)
        }
        self.init(points: coordinates, offsets: offsets)
    }

    public init(points: [GeoCoordinate], offsets: [Double]) {
        self.points = points
        self.offsets = offsets
    }

    /// The track's length in time, in seconds.
    public var duration: Double { offsets.last ?? 0 }

    /// Where the traveller is `seconds` from the start, which way they are
    /// going and how fast: the course and speed of the segment they are
    /// on, none while standing still.
    public func sample(at seconds: Double) -> (coordinate: GeoCoordinate, course: Double?, speed: Double?)? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return (first, nil, 0) }
        let time = min(max(seconds, 0), duration)
        var segment = 0
        while segment < points.count - 2, offsets[segment + 1] < time { segment += 1 }
        let start = points[segment], end = points[segment + 1]
        let span = offsets[segment + 1] - offsets[segment]
        let fraction = span > 0 ? (time - offsets[segment]) / span : 1
        let length = GeoMeasure.distance(start, end)
        let coordinate = GeoMeasure.interpolate(start, end, fraction: min(max(fraction, 0), 1))
        guard length > 0 else { return (coordinate, nil, 0) }
        return (coordinate, GeoMeasure.bearing(start, end), span > 0 ? length / span : nil)
    }
}

/// A recorded track played back as fixes — the simulator every navigation
/// test, and the app's demo mode, run on.
///
/// A fix is reported every `interval` of the track's time, and the replay
/// waits `interval / speed` of `clock`'s between them, so a speed of 10
/// drives a ten-minute track in a minute with the same fixes. A test hands
/// it a clock whose sleeps return at once and gets the whole track without
/// waiting. Fixes are timestamped from `startDate` — the moment the stream
/// starts, unless given — plus the track time, so an arrival time reads
/// as if the drive were now.
public struct GPXReplayProvider<ReplayClock: Clock>: LocationProvider where ReplayClock.Duration == Duration {
    public let timeline: TrackTimeline
    public let speed: Double
    public let interval: Duration
    /// The accuracy every fix claims, in metres: a good receiver's.
    public let accuracy: Double
    public let name: String
    private let clock: ReplayClock
    private let startDate: Date?

    /// One second, the rate a phone or a receiver reports at.
    public static var defaultInterval: Duration { .seconds(1) }
    /// A clear sky's accuracy, in metres.
    public static var defaultAccuracy: Double { 5 }

    public init(timeline: TrackTimeline, speed: Double = 1, interval: Duration = defaultInterval,
                accuracy: Double = defaultAccuracy, name: String = "replay", clock: ReplayClock,
                startDate: Date? = nil) {
        self.timeline = timeline
        self.speed = speed > 0 ? speed : 1
        self.interval = interval > .zero ? interval : Self.defaultInterval
        self.accuracy = accuracy
        self.name = name
        self.clock = clock
        self.startDate = startDate
    }

    public func fixes() -> AsyncThrowingStream<LocationFix, any Error> {
        let timeline = timeline, speed = speed, interval = interval, accuracy = accuracy
        let clock = clock, startDate = startDate
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard !timeline.points.isEmpty else {
                    continuation.finish(throwing: LocationError.noData("the track has no points"))
                    return
                }
                let start = startDate ?? Date()
                let step = Double(interval.components.seconds)
                    + Double(interval.components.attoseconds) / GPXReplayProvider.attosecondsPerSecond
                var elapsed = 0.0
                while true {
                    let time = min(elapsed, timeline.duration)
                    if let sample = timeline.sample(at: time) {
                        continuation.yield(LocationFix(coordinate: sample.coordinate, horizontalAccuracy: accuracy,
                                                       course: sample.course, speed: sample.speed,
                                                       timestamp: start.addingTimeInterval(time), source: .replay))
                    }
                    guard time < timeline.duration else { break }
                    do {
                        try await clock.sleep(for: interval / speed)
                    } catch {
                        break
                    }
                    elapsed += step
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static var attosecondsPerSecond: Double { 1e18 }
}

extension GPXReplayProvider where ReplayClock == ContinuousClock {
    /// A replay against the system's clock.
    public init(timeline: TrackTimeline, speed: Double = 1, interval: Duration = defaultInterval,
                accuracy: Double = defaultAccuracy, name: String = "replay") {
        self.init(timeline: timeline, speed: speed, interval: interval, accuracy: accuracy, name: name,
                  clock: ContinuousClock())
    }
}
