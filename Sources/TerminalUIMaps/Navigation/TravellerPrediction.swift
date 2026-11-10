import Foundation

/// Where the traveller is between fixes, and which way the map should
/// face.
///
/// Fixes come once a second; drawn only at them, the traveller hops and
/// the heading lurches at every corner. Between fixes the traveller is
/// carried along the route at the last fix's speed — dead reckoning on the
/// route, as navigation SDKs animate the puck (Mapbox Navigation's
/// `RouteController` interpolation, Ferrostar's snapped location).
///
/// The way the map faces is the traveller's own course when they are
/// moving and it is known: the route only leans it toward a turn ahead, by
/// at most ``Configuration/maximumAnticipation``, so a turn is anticipated
/// but one not taken never swings the map. Where the course and the route
/// part — a missed turn — the traveller is carried along their course, not
/// round the corner they did not take.
public struct TravellerPrediction: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// The longest, in seconds, the traveller is carried on past a fix:
        /// a late or lost fix should not send them on down the road.
        public var maximumPrediction = 1.5
        /// The heading looks this many seconds of travel ahead…
        public var lookAheadTime = 2.5
        /// …but never less than this, in metres, so a crawl still looks
        /// along the street rather than at the next paving stone…
        public var minimumLookAhead = 25.0
        /// …nor more, so a fast road still turns at its own bends.
        public var maximumLookAhead = 120.0
        /// The most, in degrees, the route ahead turns the heading from the
        /// traveller's course: a third of a right angle shows the turn is
        /// coming and which way, and is all the map has turned if the
        /// traveller goes straight on — less than a cell's slant on most
        /// streets, against the quarter turn of following the route.
        public var maximumAnticipation = 30.0
        /// Degrees between the course and the route where the traveller is
        /// beyond which they are not following it: half a right angle, past
        /// any lane change or bend a fix's course shows on a road.
        public var courseDisagreement = 45.0
        /// Metres a carried traveller is stepped along the route while
        /// checking it still runs with their course.
        public var carryStep = 2.0

        public init(maximumPrediction: Double = 1.5, lookAheadTime: Double = 2.5, minimumLookAhead: Double = 25,
                    maximumLookAhead: Double = 120, maximumAnticipation: Double = 30, courseDisagreement: Double = 45) {
            self.maximumPrediction = maximumPrediction
            self.lookAheadTime = lookAheadTime
            self.minimumLookAhead = minimumLookAhead
            self.maximumLookAhead = maximumLookAhead
            self.maximumAnticipation = maximumAnticipation
            self.courseDisagreement = courseDisagreement
        }
    }

    /// The traveller as drawn: where, how far along the route if they are
    /// following it, and which way the map should face.
    public struct Estimate: Sendable, Equatable {
        public var coordinate: GeoCoordinate
        /// Nil when the traveller is carried along their course instead.
        public var distanceAlong: Double?
        /// Degrees clockwise from north.
        public var course: Double
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The traveller `secondsSinceFix` after a fix that placed them
    /// `distanceAlong` metres along `line`, going `speed` metres a second.
    ///
    /// With their `course` — given when they move fast enough for it to
    /// mean their direction — the heading is that course leaned toward the
    /// route ahead by no more than ``Configuration/maximumAnticipation``,
    /// the carrying stops where the route turns away from the course, and
    /// a course that disagrees with the route at the fix carries them from
    /// `fix` along the course instead.
    public func estimate(on line: RouteLine, distanceAlong: Double, speed: Double, secondsSinceFix: Double,
                         course: Double? = nil, fix: GeoCoordinate? = nil) -> Estimate {
        let carried = max(0, speed) * min(max(0, secondsSinceFix), configuration.maximumPrediction)
        let lookAhead = min(max(max(0, speed) * configuration.lookAheadTime, configuration.minimumLookAhead),
                            configuration.maximumLookAhead)
        guard let course else {
            let along = min(max(0, distanceAlong + carried), line.length)
            return Estimate(coordinate: line.coordinate(atDistance: along), distanceAlong: along,
                            course: routeBearing(on: line, at: along, span: lookAhead))
        }
        let start = min(max(0, distanceAlong), line.length)
        if let here = stepBearing(on: line, at: start),
           abs(GeoMeasure.turn(from: course, to: here)) > configuration.courseDisagreement {
            return estimate(from: fix ?? line.coordinate(atDistance: start), course: course, speed: speed,
                            secondsSinceFix: secondsSinceFix)
        }
        // Carried along the route while it runs with the course: at a
        // corner the traveller waits for the next fix to say which way.
        var along = start
        let end = min(start + carried, line.length)
        while along < end {
            let next = min(along + configuration.carryStep, end)
            if let bearing = line.bearing(from: along, to: next),
               abs(GeoMeasure.turn(from: course, to: bearing)) > configuration.courseDisagreement { break }
            along = next
        }
        let ahead = routeBearing(on: line, at: along, span: lookAhead)
        let lean = min(max(GeoMeasure.turn(from: course, to: ahead), -configuration.maximumAnticipation),
                       configuration.maximumAnticipation)
        return Estimate(coordinate: line.coordinate(atDistance: along), distanceAlong: along,
                        course: GeoMeasure.normalizedBearing(course + lean))
    }

    /// The traveller carried straight on from a fix at `coordinate` along
    /// `course`: off the route, or not following it.
    public func estimate(from coordinate: GeoCoordinate, course: Double?, speed: Double,
                         secondsSinceFix: Double) -> Estimate {
        guard let course else { return Estimate(coordinate: coordinate, distanceAlong: nil, course: 0) }
        let carried = max(0, speed) * min(max(0, secondsSinceFix), configuration.maximumPrediction)
        return Estimate(coordinate: GeoMeasure.destination(from: coordinate, bearing: course, distance: carried),
                        distanceAlong: nil, course: course)
    }

    /// The traveller of a navigation `secondsSinceFix` after `fix`: on the
    /// route while the session has them on it, along their course while
    /// off it or rerouting, and still while `paused` or arrived. The course
    /// counts only from `headingUpSpeed` on, below which a GPS course
    /// swings at random.
    public func estimate(for session: NavigationSession?, rerouting: Bool, paused: Bool, fix: LocationFix,
                         secondsSinceFix: Double, headingUpSpeed: Double) -> Estimate {
        let course = (fix.speed ?? 0) >= headingUpSpeed ? fix.course : nil
        if let session, session.state == .onRoute || session.state == .arrived, !rerouting, session.position != nil {
            let speed = session.state == .arrived || paused ? 0 : max(0, fix.speed ?? 0)
            return estimate(on: session.line, distanceAlong: session.distanceAlong, speed: speed,
                            secondsSinceFix: secondsSinceFix, course: course, fix: fix.coordinate)
        }
        var estimate = estimate(from: fix.coordinate, course: course, speed: paused ? 0 : max(0, fix.speed ?? 0),
                                secondsSinceFix: secondsSinceFix)
        if course == nil, let given = fix.course { estimate.course = given }
        return estimate
    }

    private func routeBearing(on line: RouteLine, at along: Double, span: Double) -> Double {
        line.bearing(from: along, to: min(along + span, line.length))
            ?? line.bearing(from: max(0, along - span), to: along)
            ?? 0
    }

    /// The route's direction just past `along`.
    private func stepBearing(on line: RouteLine, at along: Double) -> Double? {
        line.bearing(from: along, to: min(along + configuration.carryStep, line.length))
            ?? line.bearing(from: max(0, along - configuration.carryStep), to: along)
    }
}
