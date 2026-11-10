import TerminalUI
import TerminalUIMaps

/// The whole screen: the map, a side panel when one is open, the status bar.
struct MapsApp: TerminalView {
    let model: MapsModel

    /// The side panel's columns, its border included.
    static let panelWidth = 40
    /// Street view's panel, wider for its photo.
    static let streetViewWidth = 64

    var body: some TerminalView {
        let theme = model.theme
        let types = model.mapTypes
        let layers = MainActor.assumeIsolated { types.layers }
        let street = model.street
        let streetImage = MainActor.assumeIsolated { street.image }
        VStack(spacing: 0) {
            MapView(camera: Binding(get: { model.camera }, set: { maps.camera = $0; maps.trip.userMovedCamera() }),
                    store: model.store) {
                MainActor.assumeIsolated { maps.trip.mapContent }
                if let route = model.route {
                    MapPolyline(route)
                    RouteEnds(route: route, origin: model.origin?.coordinate,
                              destination: model.destination?.coordinate)
                    if let destination = model.destination {
                        Marker(destination.name, coordinate: destination.coordinate)
                    }
                }
                if let selected = model.selected, model.route == nil {
                    Marker(selected.name, coordinate: selected.coordinate)
                }
                if model.panel == .streetView, let photo = streetImage {
                    Marker("street view", coordinate: photo.coordinate)
                }
            }
            .onPointOfInterestTap { point in MainActor.assumeIsolated { maps.select(point) } }
            .mapLayers(layers)
            .gesture(SpatialTapGesture().modifiers(.ctrl).onEnded { tap in
                MainActor.assumeIsolated { maps.trip.addStop(atCell: tap.location) }
            })
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.panel == nil, model.selected != nil {
                        PlaceDetailsCard(model: model)
                    }
                    if model.showsLegend { PointOfInterestLegend() }
                }
            }
            .overlay(alignment: .top) { TripBanner(model: model) }
            .overlay(alignment: .topTrailing) { TripCompass(trip: model.trip, bearing: model.camera.bearing) }
            .overlay(alignment: .bottomTrailing) { TripMotion(trip: model.trip) }
            .inspector(isPresented: Binding(get: { model.panel != nil }, set: { if !$0 { maps.panel = nil } })) {
                SidePanel(model: model, theme: theme)
                    .frame(width: model.panel == .streetView ? MapsApp.streetViewWidth : MapsApp.panelWidth)
                    .background(theme.backgroundRaised)
                    .border(.halfBlock, edges: .leading)
            }
            MapsStatusBar(model: model, theme: theme)
        }
        .onKeyPress { event in MainActor.assumeIsolated { maps.handleMapKey(event) } }
        .task { await maps.trip.launch(maps.launchLocation) }
        .background(theme.background)
        .environment(\.theme, theme as any Theme)
    }
}

/// Backend, zoom, centre and loading on the left; what keys do on the
/// right.
struct MapsStatusBar: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let store = model.store
        let types = model.mapTypes
        let status = MainActor.assumeIsolated {
            let layers = types.layers
            let layerStores = [layers.imagery, layers.terrain].compactMap { $0 }
            return (loading: store.loadingCount + layerStores.reduce(0) { $0 + $1.loadingCount },
                    waiting: store.isLoading, error: store.lastError ?? layerStores.lazy.compactMap(\.lastError).first)
        }
        let camera = model.camera
        let navigating = MainActor.assumeIsolated { maps.trip.isNavigating }
        StatusBar {
            StatusBarSection(.left, spans: [
                TextSpan(" \(model.backend.preset.title) ", foreground: theme.onPrimary, background: theme.primary,
                         bold: true),
                TextSpan(" \(MainActor.assumeIsolated { types.mapType.title }) ",
                         foreground: theme.foregroundEmphasis, background: theme.backgroundSelected),
                TextSpan(String(format: "  z%.1f  ", camera.zoom), foreground: theme.foregroundEmphasis),
                TextSpan(MapsModel.describe(camera.center), foreground: theme.foregroundSubtle),
                MapsStatusBar.state(status, notice: model.notice, theme: theme),
            ] + tripStatus(model.trip, theme: theme))
            StatusBarSection(.right, spans: MapsStatusBar.hints(model.panel, navigating: navigating, theme: theme))
        }
    }

    private static func state(_ status: (loading: Int, waiting: Bool, error: String?), notice: String?,
                              theme: any Theme) -> TextSpan {
        if let notice { return TextSpan("  \(notice)", foreground: theme.warning) }
        if let error = status.error { return TextSpan("  \(error)", foreground: theme.error) }
        if status.loading > 0 {
            return TextSpan("  loading \(status.loading) tile\(status.loading == 1 ? "" : "s")…",
                            foreground: theme.busy)
        }
        if status.waiting { return TextSpan("  connecting…", foreground: theme.busy) }
        return TextSpan("")
    }

    private static func hints(_ panel: Panel?, navigating: Bool, theme: any Theme) -> [TextSpan] {
        let pairs: [(String, String)] = panel == nil && navigating
            ? [("n", "end"), ("Space", "pause"), ("r", "re-centre"), ("u", "heading/north/locked"), ("<>", "rotate"),
               ("z", "junction zoom"), ("w", "car/bike/foot"), ("C", "compass"), ("e", "smooth"), ("p", "route"),
               ("q", "quit")]
            : panel == nil
            ? [("/", "search"), ("d", "directions"), ("p", "route"), ("g", "location"), ("n", "navigate"),
               ("m", "map type"), ("v", "street"), ("o", "offline"), ("b", "backend"), ("?", "legend"), ("q", "quit")]
            : [("Tab", "next"), ("Enter", "choose"), ("Esc", "close")]
        var spans: [TextSpan] = []
        for (key, action) in pairs {
            spans.append(TextSpan(key, foreground: theme.accent, bold: true))
            spans.append(TextSpan(" \(action)  ", foreground: theme.foregroundMuted))
        }
        return spans
    }
}

/// The panel open beside the map.
struct SidePanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        Group {
            switch model.panel {
            case .search: SearchPanel(model: model, theme: theme)
            case .directions: DirectionsPanel(model: model, theme: theme)
            case .downloads: DownloadsPanel(model: model, theme: theme)
            case .backends: BackendPanel(model: model, theme: theme)
            case .mapTypes: MapTypePanel(model: model, theme: theme)
            case .streetView: StreetViewSidePanel(model: model, theme: theme)
            case .route: RoutePanel(model: model, theme: theme)
            case .location: LocationPanel(model: model, theme: theme)
            case nil: Text("")
            }
        }
        .padding(.horizontal, 1)
    }
}

/// A heading for a panel.
private func heading(_ title: String, _ theme: any Theme) -> some TerminalView {
    Text(title).bold().foreground(theme.foregroundEmphasis)
}

/// A search field: Enter searches, or goes to the result selected once the
/// results answer the text; ↑ and ↓ move the selection.
private func searchField(_ prompt: String, text: Binding<String>, placeholder: String,
                         target: SearchTarget) -> some TerminalView {
    TextInput(prompt, text: text, placeholder: placeholder)
        .onKeyPress { event in
            switch event.key {
            case .enter: MainActor.assumeIsolated { maps.submit(target) }
            case .down: maps.moveSelection(by: 1)
            case .up: maps.moveSelection(by: -1)
            default: return .ignored
            }
            return .handled
        }
}

/// What a backend request is doing, as a line.
private func progressLine(_ progress: Progress, working: String, theme: any Theme) -> some TerminalView {
    let line: (text: String, colour: Color) = switch progress {
    case .idle, .done: ("", theme.foreground)
    case .working: (working, theme.busy)
    case .failed(let reason): (reason, theme.error)
    }
    return Text(line.text).foreground(line.colour)
}

/// The results of the last search, Enter going to the one selected.
private func resultList(_ model: MapsModel, theme: any Theme) -> some TerminalView {
    List(model.results, selection: Binding(get: { model.resultSelection }, set: { maps.resultSelection = $0 })) {
        result in
        VStack(alignment: .leading, spacing: 0) {
            Text(result.place.name).foreground(theme.foreground)
            Text([result.place.kind, result.place.address].compactMap { $0 }.joined(separator: " · "))
                .foreground(theme.foregroundMuted)
        }
    }
    .onKeyPress { event in
        guard let id = maps.resultSelection else { return .ignored }
        switch event.key {
        case .enter: MainActor.assumeIsolated { maps.choose(id) }
        case .character("a"):
            guard let place = maps.results.first(where: { $0.id == id })?.place else { return .ignored }
            MainActor.assumeIsolated { maps.trip.addStop(place.name, at: place.coordinate) }
        default: return .ignored
        }
        return .handled
    }
}

struct SearchPanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        VStack(alignment: .leading, spacing: 0) {
            heading("Search", theme)
            searchField("/ ", text: Binding(get: { model.query }, set: { maps.query = $0 }),
                        placeholder: "a place, a street, a café", target: .place)
            progressLine(model.searchProgress, working: "searching…", theme: theme)
            if !model.results.isEmpty {
                resultList(model, theme: theme)
            }
            Text("Enter search, again to go · ↑↓ choose").foreground(theme.foregroundMuted)
            Text("Tab to the list, a adds a stop").foreground(theme.foregroundMuted)
        }
    }
}

struct DirectionsPanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        VStack(alignment: .leading, spacing: 0) {
            heading("Directions", theme)
            searchField("From ", text: Binding(get: { model.originText }, set: { maps.originText = $0 }),
                        placeholder: "here, the map's middle", target: .origin)
            searchField("To   ", text: Binding(get: { model.destinationText }, set: { maps.destinationText = $0 }),
                        placeholder: "search for a place", target: .destination)
            progressLine(model.searchProgress, working: "searching…", theme: theme)
            if !model.results.isEmpty {
                resultList(model, theme: theme)
            } else if let route = model.route {
                Text("\(MapsModel.describe(distance: route.distance)) · \(MapsModel.describe(duration: route.duration)) by car")
                    .bold().foreground(theme.accent)
                List(Array(route.steps.enumerated()).map { RouteStepRow(id: $0.offset, step: $0.element) }) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.step.instruction).foreground(theme.foreground)
                        if row.step.distance > 0 {
                            Text(MapsModel.describe(distance: row.step.distance)).foreground(theme.foregroundMuted)
                        }
                    }
                }
            }
            progressLine(model.routeProgress, working: "finding a route…", theme: theme)
        }
    }
}

/// A step of a route, numbered for the list that shows it.
struct RouteStepRow: Identifiable {
    let id: Int
    let step: RouteStep
}

struct DownloadsPanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let count = MainActor.assumeIsolated { maps.downloadTileCount }
        VStack(alignment: .leading, spacing: 0) {
            heading("Offline maps", theme)
            if model.backend.downloads == nil {
                Text("\(model.backend.preset.title) cannot be downloaded: switch with b")
                    .foreground(theme.foregroundMuted)
            } else {
                Text("Download the area in view").foreground(theme.foregroundSubtle)
                HStack(spacing: 1) {
                    Text("from zoom \(model.downloadMinimumZoom)").frame(width: 13)
                    Button("−") { maps.adjustDownload(minimum: -1) }
                    Button("+") { maps.adjustDownload(minimum: 1) }
                }
                HStack(spacing: 1) {
                    Text("to zoom \(model.downloadMaximumZoom)").frame(width: 13)
                    Button("−") { maps.adjustDownload(maximum: -1) }
                    Button("+") { maps.adjustDownload(maximum: 1) }
                }
                Text("\(count) tiles, at most \(RegionDownloader.defaultTileLimit)")
                    .foreground(count > RegionDownloader.defaultTileLimit ? theme.error : theme.foregroundMuted)
                Button("Download") { MainActor.assumeIsolated { maps.startDownload() } }
                if let download = model.download, model.downloadProgress == .working {
                    ProgressBar(value: download.fractionCompleted, label: "\(download.completed)/\(download.total) ")
                }
                progressLine(model.downloadProgress, working: "", theme: theme)
            }
            Divider()
            heading("Downloaded", theme)
            if model.packs.isEmpty {
                Text("nothing yet").foreground(theme.foregroundMuted)
            } else {
                List(model.packs, selection: Binding(get: { model.packSelection }, set: { maps.packSelection = $0 })) {
                    row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.pack.manifest.name).foreground(theme.foreground)
                        Text("z\(row.pack.manifest.minimumZoom)–\(row.pack.manifest.maximumZoom) · "
                             + "\(row.pack.manifest.tileCount) tiles · \(MapsModel.describe(bytes: row.pack.manifest.byteCount))")
                            .foreground(theme.foregroundMuted)
                    }
                }
                .onKeyPress { event in
                    guard let name = maps.packSelection else { return .ignored }
                    switch event.key {
                    case .enter:
                        let pack = maps.packs.first { $0.id == name }?.pack
                        MainActor.assumeIsolated { maps.switchBackend(to: .offline, pack: pack) }
                    case .character("x"), .delete, .backspace:
                        maps.delete(name)
                    default:
                        return .ignored
                    }
                    return .handled
                }
                Text("Enter use offline · x delete").foreground(theme.foregroundMuted)
            }
        }
    }
}

struct BackendPanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let current = model.backend.preset
        VStack(alignment: .leading, spacing: 0) {
            heading("Backend", theme)
            List(BackendPreset.available, selection: Binding(get: { model.backendSelection },
                                                             set: { maps.backendSelection = $0 })) { preset in
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset == current ? "\(preset.title) ✓" : preset.title)
                        .foreground(preset == current ? theme.accent : theme.foreground)
                    Text(preset.summary).foreground(theme.foregroundMuted)
                }
            }
            .onKeyPress { event in
                guard event.key == .enter, let preset = maps.backendSelection.flatMap(BackendPreset.init) else {
                    return .ignored
                }
                MainActor.assumeIsolated { maps.switchBackend(to: preset) }
                return .handled
            }
            Text("Enter switch").foreground(theme.foregroundMuted)
        }
    }
}

