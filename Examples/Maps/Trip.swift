import Foundation
import Observation
import TerminalUI
import TerminalUIMaps

/// A location provider the panel offers, by an id for its list.
struct LocationChoice: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let spec: LocationSpec

    /// What the panel lists: everything `--location` takes, the sample's
    /// drive among them.
    static func all(demoTrack: String?) -> [LocationChoice] {
        var choices = [
            LocationChoice(id: "none", title: "None", summary: "no position", spec: .none),
            LocationChoice(id: "here", title: "I am here", summary: "the map's middle, set by hand (i)", spec: .here),
        ]
        if let demoTrack {
            choices.append(LocationChoice(id: "demo", title: "Demo drive", summary: "replay \(SampleTown.name)'s drive",
                                          spec: .gpx(path: demoTrack)))
        }
        for (id, title, mode) in [("five-ways-drive", "Five Ways by car", TravelMode.driving),
                                  ("five-ways-ride", "Five Ways by bicycle", .cycling)]
            where FileManager.default.fileExists(atPath: TripModel.fiveWaysTrackPath(for: mode)) {
            choices.append(LocationChoice(id: id, title: title, summary: "replay through the confusing junction",
                                          spec: .gpx(path: TripModel.fiveWaysTrackPath(for: mode))))
        }
        choices += [
            LocationChoice(id: "gpsd", title: "gpsd", summary: "localhost:2947",
                           spec: .gpsd(host: GPSDLocationProvider.defaultHost, port: GPSDLocationProvider.defaultPort)),
            LocationChoice(id: "nmea-udp", title: "NMEA over UDP", summary: "a phone sending to port 10110",
                           spec: .nmeaUDP(port: NMEALocationProvider.defaultPort)),
            LocationChoice(id: "nmea-tcp", title: "NMEA over TCP", summary: "localhost:10110",
                           spec: .nmeaTCP(host: GPSDLocationProvider.defaultHost, port: NMEALocationProvider.defaultPort)),
        ]
        #if canImport(CoreLocation)
        choices.append(LocationChoice(id: "corelocation", title: "Location Services",
                                      summary: "this Mac's (needs the Info.plist build)", spec: .coreLocation))
        #endif
        return choices
    }
}

/// A stop of the plan, numbered for the list that shows it.
struct StopRow: Identifiable, Sendable, Equatable {
    var id: Int { waypoint.id }
    let number: Int
    let waypoint: Waypoint
}

/// The route being marked, where the traveller is, and the navigation
/// along it — the app's side of `RoutePlan`, the location providers and
/// `NavigationController`. Not isolated, as `MapsModel` is not; its tasks
/// run on the main actor and reach it through the `maps` global.
@Observable
final class TripModel {
    var plan = RoutePlan()
    var route: Route?
    var routeProgress = Progress.idle
    var stopSelection: Int?
    /// The GPX file the panel saves to and loads from.
    var fileText = "route.gpx"
    var fileNotice: String?

    var location = LocationSpec.none
    var locationName: String?
    var locationError: String?
    var lastFix: LocationFix?
    var locationSelection: String?
    let replaySpeed: Double
    /// Where the demo's GPX lives, if this checkout has it.
    let demoTrack: String?

    /// Fed with every fix; main-actor state, reached through
    /// `MainActor.assumeIsolated` by the views.
    let navigation = NavigationController()
    /// The camera that follows the traveller, its profile the route's
    /// mode's, switched with `w`.
    var navigationCamera = NavigationCamera()
    /// Whether the compass shows on the map (`C`).
    var showsCompass = true

    /// Whether the camera or the traveller is still moving, so the map's
    /// timeline draws frames; false when both have come to rest, and the
    /// app goes idle.
    var isAnimating = false

    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    /// The demo track, relative to the checkout `swift run` runs from.
    static let demoTrackPath = "Examples/Maps/Tracks/millbrook-drive.gpx"

    /// The drives through the sample town's Five Ways, by car and by
    /// bicycle, beside the demo track.
    static func fiveWaysTrackPath(for mode: TravelMode) -> String {
        mode == .cycling ? "Examples/Maps/Tracks/millbrook-five-ways-ride.gpx"
            : "Examples/Maps/Tracks/millbrook-five-ways-drive.gpx"
    }

    init(replaySpeed: Double) {
        self.replaySpeed = replaySpeed
        demoTrack = FileManager.default.fileExists(atPath: TripModel.demoTrackPath) ? TripModel.demoTrackPath : nil
    }

    var choices: [LocationChoice] { LocationChoice.all(demoTrack: demoTrack) }

    /// How the traveller moves: the route's mode's, switched with `w`.
    var profile: TravelProfile { navigationCamera.profile }

    var stopRows: [StopRow] {
        plan.waypoints.enumerated().map { StopRow(number: $0.offset + 1, waypoint: $0.element) }
    }

    @MainActor var isNavigating: Bool { navigation.isActive }

    // MARK: - Launch

    /// What the command line asked for: a location, and for a GPX file, its
    /// route to navigate — the demo.
    @MainActor
    func launch(_ spec: LocationSpec?) async {
        guard let spec else { return }
        if case .gpx(let path) = spec, let document = try? GPXDocument(contentsOf: URL(fileURLWithPath: path)) {
            loadPlan(from: document)
            apply(TravelProfile(mode: plan.mode))
            await routePlan()
            if route != nil { startNavigation() }
        }
        startLocation(spec)
    }

    // MARK: - Stops

    @MainActor
    func addStop(_ name: String, at coordinate: GeoCoordinate) {
        let id = plan.append(name, at: coordinate)
        stopSelection = id
        maps.notice = "added stop \(plan.waypoints.count): \(name)"
        replan()
    }

    /// A stop where a cell of the map is: a Ctrl+click.
    @MainActor
    func addStop(atCell cell: Point) {
        addStop("Pin \(plan.waypoints.count + 1)", at: maps.camera.coordinate(atCell: cell, in: maps.store.viewSize))
    }

    @MainActor
    func removeStop(_ id: Int) {
        plan.remove(id)
        stopSelection = plan.waypoints.first?.id
        replan()
    }

    @MainActor
    func moveStop(_ id: Int, by offset: Int) {
        plan.move(id, by: offset)
        replan()
    }

    @MainActor
    func reversePlan() {
        plan.reverse()
        replan()
    }

    @MainActor
    func clearPlan() {
        plan.removeAll()
        route = nil
        routeProgress = .idle
        stopNavigation()
    }

    /// Route again after the stops changed, once there are two.
    @MainActor
    private func replan() {
        routeTask?.cancel()
        guard plan.isRoutable else {
            route = nil
            routeProgress = .idle
            return
        }
        routeTask = Task { @MainActor in await maps.trip.routePlan() }
    }

    @MainActor
    func routePlan() async {
        guard plan.isRoutable else { return }
        guard let routes = maps.backend.routes else {
            routeProgress = .failed("\(maps.backend.preset.title) gives no directions")
            return
        }
        routeProgress = .working
        let coordinates = plan.coordinates, mode = plan.mode
        do {
            let found = try await routes.route(through: coordinates, mode: mode)
            guard !Task.isCancelled else { return }
            route = found
            routeProgress = .done
        } catch {
            guard !Task.isCancelled else { return }
            route = nil
            routeProgress = .failed(String(describing: error))
        }
    }

    // MARK: - Files

    private var fileURL: URL {
        URL(fileURLWithPath: (fileText.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
    }

    /// The plan as a GPX route, and the track navigation recorded, if any.
    @MainActor
    func savePlan() {
        let recorded = navigation.recordedTrack
        let document = GPXDocument(name: plan.waypoints.last.map { "To \($0.name)" },
                                   routes: plan.waypoints.isEmpty ? [] : [GPXRoute(plan)],
                                   tracks: recorded.isEmpty ? [] : [GPXTrack(name: "Recorded", segments: [recorded])])
        do {
            try document.write(to: fileURL)
            fileNotice = "saved \(plan.waypoints.count) stops\(recorded.isEmpty ? "" : " and the track") to \(fileText)"
        } catch {
            fileNotice = "could not save: \(error.localizedDescription)"
        }
    }

    @MainActor
    func loadPlanFile() {
        do {
            loadPlan(from: try GPXDocument(contentsOf: fileURL))
            fileNotice = "loaded \(plan.waypoints.count) stops from \(fileText)"
            replan()
        } catch {
            fileNotice = "could not load: \(error)"
        }
    }

    /// A file's first route as the plan; with none, its track's ends.
    @MainActor
    private func loadPlan(from document: GPXDocument) {
        if let first = document.routes.first(where: { $0.points.count >= 2 }) {
            plan = RoutePlan(gpx: first)
        } else if let points = LocationSpec.replayPoints(of: document), let start = points.first,
                  let end = points.last, points.count >= 2 {
            plan = RoutePlan(gpx: GPXRoute(points: [start, end]))
        }
        stopSelection = plan.waypoints.first?.id
    }

    // MARK: - Location

    @MainActor
    func startLocation(_ spec: LocationSpec) {
        locationTask?.cancel()
        location = spec
        locationError = nil
        lastFix = nil
        navigationCamera.clearFix()
        do {
            guard let provider = try spec.makeProvider(here: maps.camera.center, replaySpeed: replaySpeed) else {
                locationName = nil
                return
            }
            locationName = provider.name
            navigationCamera.recentre()
            locationTask = Task { @MainActor in
                do {
                    for try await fix in provider.fixes() {
                        await maps.trip.receive(fix)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    maps.trip.locationError = String(describing: error)
                }
            }
        } catch {
            locationName = nil
            locationError = String(describing: error)
        }
    }

    /// "I am here": the map's middle as the position.
    @MainActor
    func setHere() {
        startLocation(.here)
    }

    /// A fix only moves the traveller's anchor; the frames that follow,
    /// from the map's timeline, carry them on and ease the camera after
    /// them (`advance(to:)`).
    @MainActor
    func receive(_ fix: LocationFix) async {
        lastFix = fix
        navigationCamera.receive(fix)
        await navigation.receive(fix)
        isAnimating = true
    }

    /// One frame of the map's timeline: the navigation camera carries the
    /// traveller on and moves the map after them.
    @MainActor
    func advance(to date: Date) {
        navigationCamera.timeScale = roadTimeScale
        var camera = maps.camera
        isAnimating = navigationCamera.advance(to: date, camera: &camera, navigation: navigation, store: maps.store)
        if camera != maps.camera { maps.camera = camera }
    }

    /// How many seconds of the road a second on screen is: a replay's
    /// speed.
    private var roadTimeScale: Double {
        if case .gpx = location { replaySpeed } else { 1 }
    }

    /// The user panned or zoomed: stop following until re-centred.
    func userMovedCamera() {
        navigationCamera.userMovedCamera()
    }

    /// Follow again, flying back from wherever the user left the map.
    @MainActor
    func recentre() {
        navigationCamera.recentre()
        isAnimating = lastFix != nil
    }

    // MARK: - Navigation

    @MainActor
    func startNavigation() {
        guard let route else {
            maps.notice = "mark a route first: a adds the map's middle, Ctrl+click a point"
            return
        }
        apply(TravelProfile(mode: plan.mode))
        navigation.start(route: route, plan: plan, router: maps.backend.routes,
                         configuration: profile.navigationConfiguration)
        navigationCamera.recentre()
        maps.panel = nil
        maps.notice = nil
    }

    @MainActor
    func stopNavigation() {
        navigation.stop()
        var camera = maps.camera
        camera.bearing = 0
        maps.camera = camera
    }

    @MainActor
    func togglePause() {
        switch navigation.status {
        case .paused: navigation.resume()
        case .navigating, .rerouting: navigation.pause()
        default: break
        }
    }

    // MARK: - Keys and content

    /// The trip's keys, with the map focused and no panel open.
    @MainActor
    func handleKey(_ event: KeyEvent) -> KeyEventResult {
        switch event.key {
        case .character("a"):
            addStop("Pin \(plan.waypoints.count + 1)", at: maps.camera.center)
        case .character("p"):
            stopSelection = stopSelection ?? plan.waypoints.first?.id
            maps.open(.route)
        case .character("g"):
            locationSelection = choices.first { $0.spec == location }?.id ?? choices.first?.id
            maps.open(.location)
        case .character("i"):
            setHere()
        case .character("n"):
            if isNavigating { stopNavigation() } else { startNavigation() }
        case .character(" "):
            togglePause()
        case .character("r"):
            recentre()
        case .character("u"):
            cycleOrientation()
        case .character("<"):
            rotateMap(by: -TripModel.rotationStep)
        case .character(">"):
            rotateMap(by: TripModel.rotationStep)
        case .character("C"):
            toggleCompass()
        case .character("w"):
            cycleProfile()
        case .character("z"):
            toggleJunctionZoom()
        case .character("e"):
            toggleEasing()
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: - Camera behaviours, switched while running

    /// Degrees `<` and `>` turn the map: a twenty-fourth of a turn, a
    /// compass point and a half.
    static let rotationStep = 15.0

    /// Heading up, north up, locked; the map turns to the new orientation.
    @MainActor
    func cycleOrientation() {
        let orientation = navigationCamera.cycleOrientation(currentBearing: maps.camera.bearing)
        maps.notice = TripModel.describe(orientation, bearing: navigationCamera.lockedBearing)
        isAnimating = lastFix != nil
    }

    static func describe(_ orientation: NavigationCamera.Orientation, bearing: Double) -> String {
        switch orientation {
        case .headingUp: "heading up"
        case .northUp: "north up"
        case .locked: "locked at \(Int(bearing.rounded()) % TripModel.degreesInTurn)°"
        }
    }

    private static let degreesInTurn = 360

    /// Turn the map by `degrees`: while following it is then locked there,
    /// as Apple Maps keeps a map the user turned; while browsing it turns
    /// about its middle.
    @MainActor
    func rotateMap(by degrees: Double) {
        navigationCamera.rotate(by: degrees, currentBearing: maps.camera.bearing)
        if navigationCamera.isFollowing, lastFix != nil {
            maps.notice = TripModel.describe(.locked, bearing: navigationCamera.lockedBearing)
        }
        isAnimating = true
    }

    /// A tap on the compass: a turned map goes north up; a following map
    /// north up already goes heading up.
    @MainActor
    func compassTapped() {
        let bearing = maps.camera.bearing
        navigationCamera.compassTapped(currentBearing: bearing)
        if navigationCamera.isFollowing, lastFix != nil {
            maps.notice = TripModel.describe(navigationCamera.orientation, bearing: bearing)
        }
        isAnimating = true
    }

    @MainActor
    func toggleCompass() {
        showsCompass.toggle()
        maps.notice = showsCompass ? "compass shown" : "compass hidden"
    }

    /// Car, bicycle, on foot: the camera takes the new profile at once; a
    /// route not yet navigated is routed again for it.
    @MainActor
    func cycleProfile() {
        apply(profile.next)
        maps.notice = profile.title + (TripModel.routesCarsOnly(maps.backend.preset, mode: profile.travelMode)
            ? ": OSRM's demo server routes cars only" : "")
        if !isNavigating, plan.mode != profile.travelMode {
            plan.mode = profile.travelMode
            replan()
        }
        isAnimating = lastFix != nil
    }

    /// Whether the backend's router answers only cars: OSRM's demo server,
    /// router.project-osrm.org, loads the car profile alone.
    static func routesCarsOnly(_ preset: BackendPreset, mode: TravelMode) -> Bool {
        preset == .openStreetMap && mode != .driving
    }

    /// Take a profile's speeds, look-ahead and junction rules.
    func apply(_ newProfile: TravelProfile) {
        navigationCamera.profile = newProfile
    }

    /// Whether the zoom reads the junctions ahead or follows speed alone.
    @MainActor
    func toggleJunctionZoom() {
        navigationCamera.zoomsForJunctions.toggle()
        maps.notice = navigationCamera.zoomsForJunctions ? "zoom reads the junctions" : "zoom follows speed only"
        isAnimating = lastFix != nil
    }

    /// Whether the camera eases or jumps to each frame's target.
    @MainActor
    func toggleEasing() {
        navigationCamera.isSmooth.toggle()
        maps.notice = navigationCamera.isSmooth ? "smooth camera" : "camera jumps to each fix"
        isAnimating = lastFix != nil
    }

    /// Where the route being navigated, or the one planned, meets its
    /// stops: the dashed walks to the destination and from the start, and
    /// the side the destination is on. A reroute starts where the traveller
    /// was, so it has no walk from the start.
    @MainActor
    var routeEnds: RouteEnds? {
        let shownRoute = navigation.session?.route ?? route
        guard let shownRoute else { return nil }
        return RouteEnds(route: shownRoute,
                         origin: navigation.rerouteCount == 0 ? plan.waypoints.first?.coordinate : nil,
                         destination: plan.waypoints.last?.coordinate)
    }

    /// What the trip draws on the map: the route ahead in the accent and
    /// behind dimmer, the dashed walks at its ends, the stops, and the
    /// traveller.
    @MainActor
    var mapContent: MapContentGroup {
        var elements: [MapElement] = navigation.session != nil
            ? navigationCamera.routeLines(for: navigation).mapElements
            : route.map { MapPolyline($0).mapElements } ?? []
        elements += routeEnds?.mapElements ?? []
        for row in stopRows {
            elements += Marker("\(row.number) \(row.waypoint.name)", coordinate: row.waypoint.coordinate).mapElements
        }
        elements += navigationCamera.traveller?.mapElements ?? []
        return MapContentGroup(elements)
    }
}
