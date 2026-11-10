import Foundation
import Observation

/// Where a navigation is: the session's state, as the app shows it.
public enum NavigationStatus: Sendable, Equatable {
    case idle
    case navigating
    case paused
    /// Off the route, a new one being asked for.
    case rerouting
    case arrived
}

/// Live navigation: a ``NavigationSession`` fed with fixes, rerouted
/// through a ``RouteProvider`` when the traveller leaves the route, and
/// the fixes it took recorded as a track.
///
/// Main-actor state, observed by the views; ``receive(_:)`` is awaited a
/// fix at a time, so a test drives a whole replay through it in order and
/// reads what happened in ``history``.
@MainActor @Observable
public final class NavigationController {
    public private(set) var session: NavigationSession?
    public private(set) var status = NavigationStatus.idle
    /// The stops being navigated through; a reroute visits those not yet
    /// reached.
    public private(set) var plan = RoutePlan()
    /// Every event since navigation started, in order.
    public private(set) var history: [NavigationEvent] = []
    /// Why the last reroute failed, until one succeeds.
    public private(set) var rerouteError: String?
    /// The fixes taken while navigating, as a GPX track segment.
    public private(set) var recordedTrack: [GPXPoint] = []
    /// How many reroutes were asked for.
    public private(set) var rerouteCount = 0

    @ObservationIgnored private var router: (any RouteProvider)?
    @ObservationIgnored private var lastRerouteAttempt: Date?
    /// Bumped by every start and stop, so a reroute answered after either
    /// is dropped rather than given to the navigation that followed.
    @ObservationIgnored private var generation = 0

    /// After a failed reroute, how long, by the fixes' clock, before
    /// another is tried.
    public static let rerouteRetryInterval: TimeInterval = 10

    public nonisolated init() {}

    /// Begin navigating `route`, which goes through `plan`'s stops, asking
    /// `router` for a new one when the traveller leaves it.
    public func start(route: Route, plan: RoutePlan, router: (any RouteProvider)?,
                      configuration: NavigationConfiguration = NavigationConfiguration()) {
        generation += 1
        session = NavigationSession(route: route, configuration: configuration)
        self.plan = plan
        self.router = router
        status = .navigating
        history = []
        rerouteError = nil
        recordedTrack = []
        rerouteCount = 0
        lastRerouteAttempt = nil
    }

    /// Stop taking fixes into the session; the position still shows.
    public func pause() {
        if status == .navigating || status == .rerouting { status = .paused }
    }

    /// Take fixes again: the next one finds the step the traveller is on,
    /// however far they went meanwhile.
    public func resume() {
        if status == .paused { status = .navigating }
    }

    public func stop() {
        generation += 1
        session = nil
        status = .idle
        router = nil
    }

    public var isActive: Bool { session != nil && status != .idle }

    /// Take one fix: match it, and reroute if it left the route. Returns
    /// once any reroute has been answered.
    public func receive(_ fix: LocationFix) async {
        guard var session, status == .navigating || status == .rerouting else { return }
        recordedTrack.append(GPXPoint(coordinate: fix.coordinate, time: fix.timestamp))
        let events = session.update(fix)
        self.session = session
        history += events
        if events.contains(.arrived) {
            status = .arrived
            return
        }
        guard case .offRoute = session.state, status == .navigating else { return }
        if let lastRerouteAttempt, rerouteError != nil,
           fix.timestamp.timeIntervalSince(lastRerouteAttempt) < Self.rerouteRetryInterval {
            return
        }
        await reroute(from: fix)
    }

    private func reroute(from fix: LocationFix) async {
        guard let router, let current = session else { return }
        status = .rerouting
        rerouteCount += 1
        lastRerouteAttempt = fix.timestamp
        let waypoints = plan.remaining(from: fix.coordinate, after: current.stopsReached)
        // The way the traveller is going, when they move fast enough for
        // their course to mean it: the new route should leave along it.
        let course = fix.course.flatMap { (fix.speed ?? 0) >= current.configuration.minimumSpeedForCourse ? $0 : nil }
        let generation = generation
        do {
            let route = try await router.route(through: waypoints, mode: plan.mode, departing: course)
            guard self.generation == generation, status == .rerouting, var session else { return }
            history += session.reroute(route, course: course)
            self.session = session
            rerouteError = nil
            status = session.state == .arrived ? .arrived : .navigating
        } catch {
            guard self.generation == generation else { return }
            // A reroute given up with the task that asked for it is no
            // failure to show: the position's source stopped.
            if !(Task.isCancelled || error is CancellationError) {
                rerouteError = String(describing: error)
            }
            if status == .rerouting { status = .navigating }
        }
    }

    /// Take every fix of a stream until it ends or navigation does.
    public func follow(_ fixes: AsyncThrowingStream<LocationFix, any Error>) async throws {
        for try await fix in fixes {
            await receive(fix)
            if status == .arrived || status == .idle { return }
        }
    }
}
