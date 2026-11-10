import Foundation

/// A drive and a ride through Five Ways, the sample town's confusing
/// corner: a five-way junction whose two northern roads leave 25° apart,
/// Kiln Circus, a roundabout 24 m across, and a staggered crossroads that
/// is two turns 20 m apart — to the Eastwood Visitor Centre, which stands
/// off the end of its road. The car sets off from the Town Hall along High
/// Street; the bicycle from St Anne's Church down the Silver Greenway, a
/// cycle path no car may take. Each slows for its turns, as a driver and
/// a rider do, so the camera's hold is seen through a speed that changes.
enum SampleFiveWays {
    /// How a traveller of the track moves.
    struct Pace: Sendable, Equatable {
        /// Metres a second along the straights.
        var cruise: Double
        /// Metres a second through a turn.
        var turning: Double
        /// Metres a second gained or lost each second.
        var acceleration: Double
    }

    /// 30 km/h, the sample router's town speed, down to 14 km/h for a turn
    /// at a comfortable 1.5 m/s².
    static let drivingPace = Pace(cruise: 30_000.0 / 3_600, turning: 4, acceleration: 1.5)
    /// 15 km/h, slowing to 9 km/h for a turn at 1 m/s².
    static let cyclingPace = Pace(cruise: 15_000.0 / 3_600, turning: 2.5, acceleration: 1)

    /// The destination of both.
    static let destinationName = "Eastwood Visitor Centre"

    static func stops(for mode: TravelMode) -> [Place] {
        let start = mode == .cycling ? "St Anne's Church" : "Town Hall"
        return [start, destinationName].compactMap { name in SampleTown.places.first { $0.name == name } }
    }

    static func plan(for mode: TravelMode) -> RoutePlan { RoutePlan(places: stops(for: mode), mode: mode) }

    static func route(for mode: TravelMode) async throws -> Route {
        try await SampleRoutes().route(through: plan(for: mode).coordinates, mode: mode)
    }

    static func pace(for mode: TravelMode) -> Pace { mode == .cycling ? cyclingPace : drivingPace }

    /// A point a second along `route`, timed from ``SampleDrive/startDate``:
    /// at `pace`'s cruise, braking to its turning speed for every
    /// manoeuvre that turns, and away again after.
    static func track(along route: Route, pace: Pace) -> [GPXPoint] {
        let session = NavigationSession(route: route)
        let turns = session.stepStarts.indices.filter { index in
            index > 0 && index < session.stepStarts.count - 1
                && session.turnAngle(atDistance: session.stepStarts[index]) >= Maneuver.straightOnTurn
        }.map { session.stepStarts[$0] }
        let line = session.line
        func speed(at distance: Double) -> Double {
            var limit = pace.cruise
            for turn in turns {
                // v² = v₀² + 2as: the fastest a traveller can go that far
                // from a turn and still be at the turning speed there.
                limit = min(limit, (pace.turning * pace.turning + 2 * pace.acceleration * abs(distance - turn))
                    .squareRoot())
            }
            return limit
        }
        var points: [GPXPoint] = []
        var along = 0.0
        var step = 0
        while along < line.length {
            if step % stepsPerSecond == 0 {
                points.append(GPXPoint(coordinate: line.coordinate(atDistance: along),
                                       time: SampleDrive.startDate.addingTimeInterval(Double(step / stepsPerSecond))))
            }
            along += speed(at: along) / Double(stepsPerSecond)
            step += 1
        }
        let seconds = (step + stepsPerSecond - 1) / stepsPerSecond
        points.append(GPXPoint(coordinate: line.coordinate(atDistance: line.length),
                               time: SampleDrive.startDate.addingTimeInterval(Double(seconds))))
        return points
    }

    /// Steps a second a track's motion is summed over: ten, fine enough
    /// that the braking curve is smooth at a second's sampling.
    static let stepsPerSecond = 10

    /// The GPX of the drive or the ride: the stops as a route, typed with
    /// the mode, and the track.
    static func document(for mode: TravelMode) async throws -> GPXDocument {
        let route = try await route(for: mode)
        let plan = plan(for: mode)
        let what = mode == .cycling ? "ride" : "drive"
        return GPXDocument(name: "A \(what) through Five Ways, \(SampleTown.name)",
                           routes: [GPXRoute(plan, name: "To \(destinationName)")],
                           tracks: [GPXTrack(name: "Five Ways \(what)", type: mode.gpxType,
                                             segments: [track(along: route, pace: pace(for: mode))])])
    }

    /// The shipped files, relative to the checkout.
    static func trackPath(for mode: TravelMode) -> String {
        mode == .cycling ? "Examples/Maps/Tracks/millbrook-five-ways-ride.gpx"
            : "Examples/Maps/Tracks/millbrook-five-ways-drive.gpx"
    }
}

extension Maneuver {
    /// Turns gentler than this, in degrees, go straight on: OSRM's band.
    static let straightOnTurn = TurnBands.straight
}
