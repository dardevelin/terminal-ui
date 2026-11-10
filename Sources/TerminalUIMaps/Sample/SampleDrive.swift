import Foundation

/// A drive through the sample town to replay: the stops of a route, the
/// route the sample's directions give through them, and a track of a car
/// following it once a second — with, when asked, a wrong turn on the
/// way: straight on past a junction where the route turns, a U-turn, and
/// back. The app's demo replays it, and the navigation tests ride it.
enum SampleDrive {
    /// The stops: from the station, by the town hall, to the library.
    static var stops: [Place] {
        ["Millbrook Station", "Town Hall", "Public Library"].compactMap { name in
            SampleTown.places.first { $0.name == name }
        }
    }

    static var plan: RoutePlan { RoutePlan(places: stops) }

    /// The route through the stops, as the sample's directions give it.
    static func route() async throws -> Route {
        try await SampleRoutes().route(through: plan.coordinates, mode: .driving)
    }

    /// When the recorded drive starts: a fixed instant, so the file is the
    /// same every time it is made.
    static let startDate = Date(timeIntervalSince1970: 1_794_301_200)

    /// The car's speed, metres a second: the sample's 30 km/h.
    static let speed = 30_000.0 / 3_600

    /// How far past the junction the wrong turn goes before turning back.
    static let detourLength = 150.0

    /// A point a second along the route at `speed`, timed from `startDate`;
    /// with `detourAtStep`, the drive goes straight on at that step's
    /// manoeuvre for `detourLength`, turns round and comes back to it.
    static func track(along route: Route, detourAtStep detourStep: Int? = nil) -> [GPXPoint] {
        var path = route.coordinates
        if let detourStep, route.steps.indices.contains(detourStep),
           let arriving = route.steps[detourStep].maneuver?.bearingBefore,
           case let junction = route.steps[detourStep].coordinate,
           let index = path.firstIndex(where: { GeoMeasure.distance($0, junction) < junctionTolerance }) {
            let beyond = GeoMeasure.destination(from: junction, bearing: arriving, distance: detourLength)
            path.insert(contentsOf: [beyond, junction], at: index + 1)
        }
        let timeline = TrackTimeline(coordinates: path, speed: speed)
        var points: [GPXPoint] = []
        var second = 0.0
        while second < timeline.duration {
            if let sample = timeline.sample(at: second) {
                points.append(GPXPoint(coordinate: sample.coordinate, time: startDate.addingTimeInterval(second)))
            }
            second += 1
        }
        if let last = path.last {
            points.append(GPXPoint(coordinate: last, time: startDate.addingTimeInterval(timeline.duration)))
        }
        return points
    }

    /// Points within this many metres are the same junction.
    static let junctionTolerance = 1.0

    /// The step the shipped drive takes its wrong turn at: the turn off
    /// Station Road, the first junction where going straight on stays on a
    /// street.
    static let detourStep = 1

    /// The step the demo's wrong turn is at — the turn onto Oak Street:
    /// one where going straight on
    /// leaves the stops still ahead, so the reroute carries on forward. At
    /// `detourStep` the next stop is behind the car on the street it went
    /// down, and reaching it means turning round — as any router would
    /// have it, OSRM's 20 s U-turn penalty being far less than the block.
    static let rerouteDetourStep = 4

    /// The demo's GPX: the stops as a route, the drive as a track.
    static func document() async throws -> GPXDocument {
        GPXDocument(name: "A drive through \(SampleTown.name)",
                    routes: [GPXRoute(plan, name: "Station to library")],
                    tracks: [GPXTrack(name: "Drive with a wrong turn",
                                      segments: [try await trackFollowingReroute()])])
    }

    /// The drive the demo replays: along the route to the detour's junction,
    /// straight on past it for `detourLength`, and from there along the
    /// route the sample's directions give for the stops still ahead,
    /// leaving the way the car is going — what the app tells a driver who
    /// missed the turn. No U-turn: a navigator that reroutes forward should
    /// be shown a driver who follows it.
    static func trackFollowingReroute(detourAtStep detourStep: Int = rerouteDetourStep) async throws
        -> [GPXPoint] {
        let router = SampleRoutes()
        let route = try await router.route(through: plan.coordinates, mode: .driving)
        guard route.steps.indices.contains(detourStep),
              let arriving = route.steps[detourStep].maneuver?.bearingBefore,
              case let junction = route.steps[detourStep].coordinate,
              let index = route.coordinates.firstIndex(where: { GeoMeasure.distance($0, junction) < junctionTolerance })
        else { return track(along: route) }
        let beyond = GeoMeasure.destination(from: junction, bearing: arriving, distance: detourLength)
        // The stops not reached by the junction: those whose place on the
        // route lies after it.
        let junctionAlong = RouteLine(route.coordinates).project(junction)?.distanceAlong ?? 0
        let line = RouteLine(route.coordinates)
        let ahead = plan.coordinates.dropFirst().filter { stop in
            (line.project(stop)?.distanceAlong ?? 0) > junctionAlong
        }
        let reroute = try await router.route(through: [beyond] + ahead, mode: .driving, departing: arriving)
        let path = Array(route.coordinates[...index]) + reroute.coordinates
        return track(along: Route(coordinates: path, distance: 0, duration: 0, steps: []))
    }
}
