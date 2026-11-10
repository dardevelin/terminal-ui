import TerminalUI
import TerminalUIMaps

/// The stops of the route being marked: reordered and removed from the
/// list, routed through, saved and loaded as GPX, and navigated.
struct RoutePanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let trip = model.trip
        VStack(alignment: .leading, spacing: 0) {
            Text("Route").bold().foreground(theme.foregroundEmphasis)
            if trip.plan.waypoints.isEmpty {
                Text("No stops yet").foreground(theme.foregroundSubtle)
                Text("a adds the map's middle,").foreground(theme.foregroundMuted)
                Text("Ctrl+click a point, or a in search").foreground(theme.foregroundMuted)
            } else {
                List(trip.stopRows, selection: Binding(get: { trip.stopSelection }, set: { maps.trip.stopSelection = $0 })) {
                    row in
                    HStack(spacing: 1) {
                        Text(row.number == 1 ? "◉" : row.number == trip.plan.waypoints.count ? "◎" : "\(row.number)")
                            .foreground(theme.accent).bold()
                        Text(row.waypoint.name).foreground(theme.foreground)
                    }
                }
                .onKeyPress { event in RoutePanel.stopKey(event) }
                Text("[ ] move · x remove · v reverse").foreground(theme.foregroundMuted)
            }
            RoutePanel.summary(trip, theme: theme)
            HStack(spacing: 1) {
                Button("Navigate") { MainActor.assumeIsolated { maps.trip.startNavigation() } }
                Button("Clear") { MainActor.assumeIsolated { maps.trip.clearPlan() } }
            }
            Divider()
            TextInput("GPX ", text: Binding(get: { trip.fileText }, set: { maps.trip.fileText = $0 }),
                      placeholder: "route.gpx")
            HStack(spacing: 1) {
                Button("Save") { MainActor.assumeIsolated { maps.trip.savePlan() } }
                Button("Load") { MainActor.assumeIsolated { maps.trip.loadPlanFile() } }
            }
            if let notice = trip.fileNotice {
                Text(notice).foreground(theme.foregroundSubtle)
            }
        }
    }

    private static func stopKey(_ event: KeyEvent) -> KeyEventResult {
        guard let id = maps.trip.stopSelection else { return .ignored }
        let shifted = event.modifiers == [.shift]
        MainActor.assumeIsolated {
            switch event.key {
            case .character("["): maps.trip.moveStop(id, by: -1)
            case .character("]"): maps.trip.moveStop(id, by: 1)
            case .up where shifted: maps.trip.moveStop(id, by: -1)
            case .down where shifted: maps.trip.moveStop(id, by: 1)
            case .character("x"), .delete, .backspace: maps.trip.removeStop(id)
            case .character("v"): maps.trip.reversePlan()
            default: break
            }
        }
        switch event.key {
        case .character("["), .character("]"), .character("x"), .character("v"), .delete, .backspace: return .handled
        case .up, .down: return shifted ? .handled : .ignored
        default: return .ignored
        }
    }

    private static func summary(_ trip: TripModel, theme: any Theme) -> some TerminalView {
        let line: (String, Color) = switch trip.routeProgress {
        case .working: ("finding a route…", theme.busy)
        case .failed(let reason): (reason, theme.error)
        case .idle, .done:
            trip.route.map { route in
                ("\(NavigationWording.distance(route.distance)) · \(NavigationWording.duration(route.duration)) "
                    + TravelProfile(mode: trip.plan.mode).travelPhrase, theme.accent)
            } ?? (trip.plan.isRoutable ? "" : "two stops make a route", theme.foregroundMuted)
        }
        let carsOnly = TripModel.routesCarsOnly(maps.backend.preset, mode: trip.plan.mode)
        return VStack(alignment: .leading, spacing: 0) {
            Text(line.0).bold().foreground(line.1)
            if carsOnly {
                Text("OSRM's demo server routes cars only").foreground(theme.warning)
            }
        }
    }
}

/// Where the position comes from, chosen from a list.
struct LocationPanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let trip = model.trip
        let current = trip.location
        VStack(alignment: .leading, spacing: 0) {
            Text("Location").bold().foreground(theme.foregroundEmphasis)
            List(trip.choices, selection: Binding(get: { trip.locationSelection },
                                                  set: { maps.trip.locationSelection = $0 })) { choice in
                VStack(alignment: .leading, spacing: 0) {
                    Text(choice.spec == current ? "\(choice.title) ✓" : choice.title)
                        .foreground(choice.spec == current ? theme.accent : theme.foreground)
                    Text(choice.summary).foreground(theme.foregroundMuted)
                }
            }
            .onKeyPress { event in
                guard event.key == .enter, let id = maps.trip.locationSelection,
                      let choice = maps.trip.choices.first(where: { $0.id == id }) else { return .ignored }
                MainActor.assumeIsolated {
                    maps.trip.startLocation(choice.spec)
                    maps.panel = nil
                }
                return .handled
            }
            if let error = trip.locationError {
                Text(error).foreground(theme.error)
            } else if let fix = trip.lastFix {
                Text(LocationPanel.describe(fix)).foreground(theme.foregroundSubtle)
            }
            Text("Enter use · --location on the command line").foreground(theme.foregroundMuted)
            Text(" ")
            Text("Camera").bold().foreground(theme.foregroundEmphasis)
            Button("Profile: \(trip.profile.title)  (w)") { MainActor.assumeIsolated { maps.trip.cycleProfile() } }
            if TripModel.routesCarsOnly(maps.backend.preset, mode: trip.profile.travelMode) {
                Text("OSRM's demo server routes cars only").foreground(theme.warning)
            }
            Button("Facing: \(TripModel.describe(trip.follow.configuration.orientation, bearing: trip.follow.configuration.lockedBearing))  (u)") {
                MainActor.assumeIsolated { maps.trip.cycleOrientation() }
            }
            Toggle("Zoom for junctions  (z)", isOn: Binding(
                get: { trip.follow.configuration.zoomsForJunctions },
                set: { _ in MainActor.assumeIsolated { maps.trip.toggleJunctionZoom() } }))
            Toggle("Compass  (C)", isOn: Binding(
                get: { trip.showsCompass },
                set: { _ in MainActor.assumeIsolated { maps.trip.toggleCompass() } }))
            Toggle("Smooth camera  (e)", isOn: Binding(
                get: { trip.motionConfiguration.isSmooth },
                set: { _ in MainActor.assumeIsolated { maps.trip.toggleEasing() } }))
        }
    }

    static func describe(_ fix: LocationFix) -> String {
        var parts = [MapsModel.describe(fix.coordinate)]
        if let accuracy = fix.horizontalAccuracy { parts.append("±\(Int(accuracy.rounded())) m") }
        if let speed = fix.speed { parts.append("\(Int((speed * TripWords.kilometresPerHourPerMetrePerSecond).rounded())) km/h") }
        return parts.joined(separator: " · ")
    }
}

enum TripWords {
    /// 3.6 km/h is a metre a second.
    static let kilometresPerHourPerMetrePerSecond = 3.6
}

/// The frames that carry the traveller and ease the camera between fixes,
/// and nothing to see: a timeline that runs only while something moves,
/// so a parked map leaves the app idle.
struct TripMotion: TerminalView {
    let trip: TripModel

    var body: some TerminalView {
        TimelineView(.animation(paused: !trip.isAnimating)) { context in
            EmptyView().onChange(of: context.date) { _, date in
                MainActor.assumeIsolated { maps.trip.advance(to: date) }
            }
        }
    }
}

/// The navigation banner over the top of the map, while navigating.
struct TripBanner: TerminalView {
    let model: MapsModel

    var body: some TerminalView {
        let state = MainActor.assumeIsolated {
            (session: maps.trip.navigation.session, status: maps.trip.navigation.status, ends: maps.trip.routeEnds)
        }
        if let session = state.session, state.status != .idle {
            NavigationBanner(session: session, status: state.status,
                             destination: model.trip.plan.waypoints.last?.name, ends: state.ends)
        }
    }
}

/// The compass in the map's corner, below the banner while navigating; a
/// tap takes a turned map north up, or a north-up one heading up.
struct TripCompass: TerminalView {
    let trip: TripModel
    let bearing: Double

    /// The banner's rows: three lines and its border.
    static let bannerHeight = 5

    var body: some TerminalView {
        let navigating = MainActor.assumeIsolated { maps.trip.isNavigating }
        if trip.showsCompass {
            MapCompass(bearing: bearing) { MainActor.assumeIsolated { maps.trip.compassTapped() } }
                .padding(.top, navigating ? TripCompass.bannerHeight : 0)
        }
    }
}

/// The trip's part of the status bar: the travel profile, where the
/// position comes from, and "re-centre" when the map no longer follows it.
func tripStatus(_ trip: TripModel, theme: any Theme) -> [TextSpan] {
    var spans: [TextSpan] = [TextSpan("  \(trip.profile.title)", foreground: theme.foregroundSubtle)]
    if let name = trip.locationName {
        spans.append(TextSpan("  ◉ \(name)", foreground: trip.locationError == nil ? theme.info : theme.error))
        if trip.lastFix != nil, !trip.follow.isFollowing {
            spans.append(TextSpan("  r re-centre", foreground: theme.accent, bold: true))
        }
    }
    return spans
}
