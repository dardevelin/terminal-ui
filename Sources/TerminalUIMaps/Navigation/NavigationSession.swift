import Foundation

/// The thresholds a ``NavigationSession`` judges fixes by.
///
/// The defaults follow what the navigation SDKs document. Off route is
/// Ferrostar's `RouteDeviationTracking.staticThreshold` — a fix farther
/// than `maximumDeviation` from the route line, from a fix whose accuracy
/// is no worse than `minimumHorizontalAccuracy` (a worse one "will not
/// trigger route deviation") — at the 50 m Mapbox's iOS Navigation SDK
/// uses for `RouteControllerMaximumDistanceBeforeRecalculating`. Steps
/// advance as Ferrostar's `DistanceToEndOfStep` condition does: within
/// `stepAdvanceDistance` of the step's end.
public struct NavigationConfiguration: Sendable, Equatable {
    /// Metres from the route beyond which a good fix is off route.
    public var maximumDeviation = 50.0
    /// The worst accuracy, in metres, a fix may have and still put the
    /// traveller off route.
    public var minimumHorizontalAccuracy = 10.0
    /// Metres before a manoeuvre at which the step it begins becomes the
    /// current one, so the banner moves on to what comes after it as the
    /// traveller reaches the junction.
    public var stepAdvanceDistance = 10.0
    /// Metres from the end at which the traveller has arrived: a parking
    /// space is rarely on the routed point.
    public var arrivalDistance = 20.0
    /// How far back along the route a fix may be matched, in metres: GPS
    /// jitter puts a slow traveller a little behind themselves.
    public var lookBehind = 20.0
    /// Metres added to the cost of matching a fix to a stretch of route
    /// heading more than a right angle away from the traveller's course,
    /// so on a route that comes back along the same street a fix is
    /// matched to the way the traveller is going.
    public var wrongWayPenalty = 30.0
    /// The slowest speed, in metres a second, whose course is trusted for
    /// that: a pedestrian's GPS course swings at random.
    public var minimumSpeedForCourse = 1.0
    /// A route that leaves more than this many degrees round from the
    /// traveller's course begins with a U-turn: past OSRM's sharp-turn
    /// band, which starts at 120°, the way on is back.
    public var reversalAngle = 120.0

    /// The documented defaults, each as its property states.
    public init() {}
}

/// Where navigation stands.
public enum NavigationState: Sendable, Equatable {
    /// No fix matched to the route yet.
    case awaitingFix
    /// The last fix matched the route within the allowed deviation.
    case onRoute
    /// The traveller is this many metres from the route.
    case offRoute(deviation: Double)
    /// The traveller reached the end of the route; later fixes change nothing.
    case arrived
}

/// What a fix changed.
public enum NavigationEvent: Sendable, Equatable {
    /// The first fix matched the route, on this step.
    case started(step: Int)
    /// The current step moved on, perhaps past several at once.
    case advanced(from: Int, to: Int)
    /// A stop on the way was reached: its number, counted from 1.
    case reachedStop(Int)
    /// A good fix put the traveller this far from the route: time to
    /// reroute.
    case leftRoute(deviation: Double)
    /// A fix matched the route again before any reroute.
    case rejoinedRoute
    /// A new route replaced the old one.
    case rerouted
    /// A fix came within `arrivalDistance` of the route's end.
    case arrived
}

/// Turn-by-turn progress along a route, fix by fix — a value with no clock,
/// no network and no screen, so every rule here is tested by feeding it
/// fixes.
///
/// Each fix is matched to the route line, projected onto its nearest stretch:
/// the nearest point of it no further back than `lookBehind` from the last
/// match. The current step is the last whose start lies within
/// `stepAdvanceDistance` ahead of that point, so a traveller who is
/// already past several steps — a fix after a tunnel, a replay resumed —
/// jumps straight to the right one. Steps are found on the line from the
/// router's step coordinates; a step the router gave no manoeuvre for has
/// one inferred from the line's bend there, from the bearings the
/// traveller arrives and leaves on.
///
/// Time remaining is the current step's duration for the share of it left,
/// plus every later step's, as Mapbox's `RouteProgress.durationRemaining`
/// adds it up; a router that gives no step durations (MapKit) has the
/// route's spread over its length.
public struct NavigationSession: Sendable {
    /// The route being followed: the one given, or the last a reroute put in its place.
    public private(set) var route: Route
    private(set) var line: RouteLine
    /// The thresholds fixes are judged by.
    public let configuration: NavigationConfiguration
    /// Where navigation stands after the last fix.
    public private(set) var state = NavigationState.awaitingFix
    /// The index into the route's steps of the one the traveller is on, from 0.
    public private(set) var stepIndex = 0
    /// Where the last fix matched the route.
    private(set) var position: RouteLinePosition?
    /// The last fix given, matched or not.
    public private(set) var lastFix: LocationFix?
    /// Stops on the way reached so far, over every route this session has
    /// followed: what a reroute leaves out of the stops still to visit.
    public private(set) var stopsReached = 0
    /// Each step's manoeuvre, the router's or one inferred.
    public private(set) var maneuvers: [Maneuver] = []
    /// Metres along the line to each step's start.
    private(set) var stepStarts: [Double] = []
    /// Whether the route leaves against the traveller's course, so the
    /// first thing to do is turn round: set by a reroute from a traveller
    /// heading away, cleared once their course agrees with the route.
    public private(set) var needsUTurn = false
    private var stepDurations: [Double] = []

    /// A session at the start of `route`, waiting for its first fix.
    public init(route: Route, configuration: NavigationConfiguration = NavigationConfiguration()) {
        self.route = route
        self.line = RouteLine(route.coordinates)
        self.configuration = configuration
        measureSteps()
    }

    // MARK: - Reading progress

    /// The step the traveller is on; nil when the route has no steps.
    public var currentStep: RouteStep? { route.steps.indices.contains(stepIndex) ? route.steps[stepIndex] : nil }

    /// The step whose manoeuvre comes next: the one after the current.
    public var upcomingStepIndex: Int? {
        route.steps.indices.contains(stepIndex + 1) ? stepIndex + 1 : nil
    }

    /// The step whose manoeuvre comes next; nil on the last step.
    public var upcomingStep: RouteStep? { upcomingStepIndex.map { route.steps[$0] } }

    /// The step after the upcoming one, for "then …".
    public var followingStep: RouteStep? {
        route.steps.indices.contains(stepIndex + 2) ? route.steps[stepIndex + 2] : nil
    }

    /// Metres travelled along the route.
    public var distanceAlong: Double { position?.distanceAlong ?? 0 }

    /// Metres to the upcoming manoeuvre, or to the end with none left.
    public var distanceToManeuver: Double {
        let target = upcomingStepIndex.map { stepStarts[$0] } ?? line.length
        return max(0, target - distanceAlong)
    }

    /// Metres still to travel along the route to its end.
    public var distanceRemaining: Double { max(0, line.length - distanceAlong) }

    /// Seconds still to travel at the router's pace.
    public var durationRemaining: Double {
        guard state != .arrived, !stepDurations.isEmpty else { return 0 }
        let start = stepStarts[stepIndex]
        let end = stepIndex + 1 < stepStarts.count ? stepStarts[stepIndex + 1] : line.length
        let share = end > start ? min(max((end - distanceAlong) / (end - start), 0), 1) : 0
        return stepDurations[stepIndex] * share + stepDurations[(stepIndex + 1)...].reduce(0, +)
    }

    /// When the traveller should arrive, by the last fix's clock.
    public var estimatedArrival: Date? {
        lastFix.map { $0.timestamp.addingTimeInterval(durationRemaining) }
    }

    /// The route split where the traveller is: what is behind, what ahead.
    public var travelledAndAhead: (travelled: [GeoCoordinate], ahead: [GeoCoordinate]) {
        line.split(atDistance: distanceAlong)
    }

    // MARK: - Fixes

    /// Take a fix; the events it caused, in order.
    @discardableResult
    public mutating func update(_ fix: LocationFix) -> [NavigationEvent] {
        lastFix = fix
        guard state != .arrived else { return [] }
        let configuration = configuration
        let floor = position.map { $0.distanceAlong - configuration.lookBehind } ?? 0
        let trustedCourse = fix.course.flatMap { course in
            (fix.speed ?? 0) >= configuration.minimumSpeedForCourse ? course : nil
        }
        guard let matched = line.project(fix.coordinate, from: max(floor, 0), penalty: { bearing, _ in
            guard let trustedCourse else { return 0 }
            return abs(GeoMeasure.turn(from: trustedCourse, to: bearing)) > Self.rightAngle
                ? configuration.wrongWayPenalty : 0
        }) else { return [] }

        var events: [NavigationEvent] = []
        guard matched.offset <= configuration.maximumDeviation else {
            let isTrusted = fix.horizontalAccuracy.map { $0 <= configuration.minimumHorizontalAccuracy } ?? false
            if isTrusted {
                if case .offRoute = state {} else { events.append(.leftRoute(deviation: matched.offset)) }
                state = .offRoute(deviation: matched.offset)
            }
            return events
        }
        switch state {
        case .awaitingFix: events.append(.started(step: 0))
        case .offRoute: events.append(.rejoinedRoute)
        case .onRoute, .arrived: break
        }
        state = .onRoute
        position = matched
        if needsUTurn, let trustedCourse, abs(GeoMeasure.turn(from: trustedCourse, to: matched.bearing)) < Self.rightAngle {
            needsUTurn = false
        }

        let reach = matched.distanceAlong + configuration.stepAdvanceDistance
        var newStep = stepIndex
        while newStep + 1 < stepStarts.count, stepStarts[newStep + 1] <= reach { newStep += 1 }
        let hasArrived = line.length - matched.distanceAlong <= configuration.arrivalDistance
        if hasArrived { newStep = max(newStep, route.steps.count - 1) }
        if newStep != stepIndex {
            for passed in (stepIndex + 1)...newStep where passed < route.steps.count - 1
                && maneuvers[passed].kind == .arrive {
                stopsReached += 1
                events.append(.reachedStop(stopsReached))
            }
            if case .started = events.first {
                events[0] = .started(step: newStep)
            } else {
                events.append(.advanced(from: stepIndex, to: newStep))
            }
            stepIndex = newStep
        }
        if hasArrived {
            state = .arrived
            events.append(.arrived)
        }
        return events
    }

    /// Follow a new route from where the traveller is — the router's answer
    /// to a ``NavigationEvent/leftRoute(deviation:)`` — and match the last
    /// fix to it at once.
    ///
    /// With the traveller's `course`, a route that leaves against it begins
    /// with a U-turn (``needsUTurn``).
    @discardableResult
    public mutating func reroute(_ newRoute: Route, course: Double? = nil) -> [NavigationEvent] {
        route = newRoute
        line = RouteLine(newRoute.coordinates)
        state = .awaitingFix
        stepIndex = 0
        position = nil
        needsUTurn = false
        measureSteps()
        var events: [NavigationEvent] = [.rerouted]
        if let lastFix {
            events += update(lastFix).filter { if case .started = $0 { false } else { true } }
        }
        if let course, let leaving = line.bearing(from: distanceAlong, to: min(line.length, distanceAlong + StepShapes.bearingSpan)) {
            needsUTurn = abs(GeoMeasure.turn(from: course, to: leaving)) > configuration.reversalAngle
        }
        return events
    }

    private static let rightAngle = 90.0

    // MARK: - Measuring the steps

    private mutating func measureSteps() {
        stepStarts = []
        var floor = 0.0
        for (index, step) in route.steps.enumerated() {
            let start: Double
            if index == 0 {
                start = 0
            } else if index == route.steps.count - 1, step.distance == 0 {
                start = line.length
            } else {
                start = line.project(step.coordinate, from: floor)?.distanceAlong ?? floor
            }
            floor = max(floor, start)
            stepStarts.append(floor)
        }
        maneuvers = route.steps.enumerated().map { index, step in
            if let maneuver = step.maneuver { return maneuver }
            if index == 0 { return Maneuver(kind: .depart, bearingAfter: line.bearing(from: 0, to: StepShapes.bearingSpan)) }
            let start = stepStarts[index]
            let before = line.bearing(from: start - StepShapes.bearingSpan, to: start)
            if index == route.steps.count - 1 { return Maneuver(kind: .arrive, bearingBefore: before) }
            guard let before, let after = line.bearing(from: start, to: start + StepShapes.bearingSpan) else {
                return Maneuver(kind: .continue)
            }
            return Maneuver.inferred(bearingBefore: before, bearingAfter: after)
        }
        let given = route.steps.map(\.duration)
        if given.reduce(0, +) > 0 || route.distance <= 0 {
            stepDurations = given
        } else {
            let pace = route.duration / route.distance
            stepDurations = route.steps.indices.map { index in
                let end = index + 1 < stepStarts.count ? stepStarts[index + 1] : line.length
                return (end - stepStarts[index]) * pace
            }
        }
    }
}
