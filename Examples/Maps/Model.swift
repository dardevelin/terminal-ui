import Foundation
import Observation
import TerminalUI
import TerminalUIMaps

/// A search result, numbered for the list that shows it.
struct SearchResult: Identifiable, Sendable, Equatable {
    let id: Int
    let place: Place
}

/// A downloaded region, named for the list that shows it.
struct PackRow: Identifiable, Sendable, Equatable {
    var id: String { pack.manifest.name }
    let pack: RegionPack
}

/// The side panel open beside the map.
enum Panel: Sendable, Equatable {
    case search
    case directions
    case downloads
    case backends
    case mapTypes
    case streetView
    case route
    case location
}

/// Which end of a route a search fills.
enum SearchTarget: Sendable, Equatable {
    case place
    case origin
    case destination
}

/// Where a request to a backend has got to.
enum Progress: Sendable, Equatable {
    case idle
    case working
    case done
    case failed(String)
}

/// The app's state. `@Observable` and not `@MainActor`, as Coder's and
/// Chat's are: the `@main` entry needs it as a top-level value. Everything
/// that reaches the tile store, which is `@MainActor`, is marked so, and
/// the views reach it through `MainActor.assumeIsolated` — the runtime
/// calls every body and handler on the main actor.
@Observable
final class MapsModel {
    var camera: MapCamera
    private(set) var backend: Backend
    let store: MapTileStore
    let packStore: RegionPackStore
    /// The route being marked, the position and navigation (Trip.swift).
    let trip: TripModel
    /// The location `--location` named, started once the app is drawn.
    let launchLocation: LocationSpec?
    var panel: Panel?
    var isDark = true
    /// A line for the status bar about the last thing that went wrong or
    /// changed.
    var notice: String?

    var theme: MapsTheme { isDark ? .dark : .light }

    // Search.
    var query = ""
    var results: [SearchResult] = []
    var resultSelection: Int?
    var searchProgress = Progress.idle
    /// The query and target the results answer, so a second Enter on the
    /// same text goes to the result rather than searching again.
    private(set) var answered: (query: String, target: SearchTarget)?
    var selected: Place?
    /// The place card's details of `selected`, asked for wherever a place
    /// is pinned (PlaceDetailsViews.swift).
    let placeDetails: PlaceDetailsLoader
    /// Where OpenStreetMap places' details come from, as launched.
    let detailsSource: PlaceDetailsSource
    /// Whether the legend of the map's glyphs is open.
    var showsLegend = false

    // Directions.
    var originText = ""
    var destinationText = ""
    var origin: Place?
    var destination: Place?
    var route: Route?
    var routeProgress = Progress.idle

    /// The backend the picker has selected, by its id.
    var backendSelection: String?

    /// The map type shown and the layers it takes (MapTypes.swift).
    let mapTypes: MapTypeModel
    /// The map type the picker has selected, by its id.
    var mapTypeSelection: String?

    /// Street view and which of the backend's services it uses
    /// (StreetView.swift).
    let street: StreetViewModel
    var streetImageryIndex = 0

    // Downloads.
    var packs: [PackRow] = []
    var packSelection: String?
    var downloadMinimumZoom = 12
    var downloadMaximumZoom = 15
    var download: DownloadProgress?
    var downloadProgress = Progress.idle

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// The zoom a place found is shown at, unless the map is closer: a
    /// street and its neighbours.
    static let placeZoom = 16.0
    /// The zoom the app opens at: the whole sample town in a terminal.
    static let openingZoom = 15.0
    /// The pitch `3` tips the map to: steep enough that the street ahead
    /// reads as ahead, short of the most, where the far ground is a strip.
    static let tiltedPitch = 45.0
    /// How many zooms a download spans by default either side of the view.
    static let downloadSpan = 2

    init(launch: LaunchOptions) {
        trip = TripModel(replaySpeed: launch.replaySpeed)
        launchLocation = launch.location
        packStore = RegionPackStore(directory: launch.packsDirectory ?? RegionPackStore.defaultDirectory())
        let packs = ((try? packStore.list()) ?? []).map(PackRow.init)
        let chosen = (try? Backend.make(launch.backend, pack: packs.first?.pack, details: launch.details))
            ?? (try? Backend.make(.sample, pack: nil))
        let backend = chosen ?? Backend(preset: .sample, tiles: SampleTileSource(), search: SampleSearch(),
                                        routes: SampleRoutes(), downloads: SampleTileSource(), pack: nil)
        self.backend = backend
        self.packs = packs
        placeDetails = PlaceDetailsLoader(provider: backend.details)
        detailsSource = launch.details
        store = MapTileStore(source: backend.tiles)
        // The runtime makes the model on the main thread, the first time
        // `content()` reads it.
        mapTypes = MainActor.assumeIsolated { MapTypeModel(offer: backend.mapTypeOffer) }
        street = MainActor.assumeIsolated {
            StreetViewModel(imagery: backend.streetImagery.first ?? SampleStreetImagery())
        }
        camera = MapCamera(center: MapsModel.home(for: backend), zoom: MapsModel.openingZoom)
        if backend.preset != launch.backend {
            notice = "\(launch.backend.title) is not available; showing \(backend.preset.title)"
        }
    }

    /// Where a backend opens: a pack's middle, else the sample town.
    static func home(for backend: Backend) -> GeoCoordinate {
        backend.pack?.manifest.bounds.center ?? SampleTown.origin
    }

    // MARK: - Panels and keys

    func open(_ newPanel: Panel) {
        panel = newPanel
        notice = nil
    }

    /// Escape: the panel first, then the place card.
    func escape() {
        if panel != nil {
            panel = nil
        } else if selected != nil {
            selected = nil
        }
    }

    /// The map seen at an angle, or straight down again; Shift with ↑ and
    /// ↓ tips it by steps in between.
    @MainActor
    func toggleTilt() {
        camera.pitch = camera.pitch > 0 ? 0 : MapsModel.tiltedPitch
        notice = camera.pitch > 0 ? "tilted view" : "flat view"
    }

    /// A key that reached the app with the map focused.
    @MainActor
    func handleMapKey(_ event: KeyEvent) -> KeyEventResult {
        guard panel == nil, event.modifiers.isEmpty || event.modifiers == [.shift] else { return .ignored }
        switch event.key {
        case .character("/"):
            open(.search)
        case .character("d"):
            openDirections()
        case .character("o"):
            refreshPacks()
            fitDownloadZooms()
            open(.downloads)
        case .character("m"):
            openMapTypes()
        case .character("v"):
            openStreetView()
        case .character("b"):
            backendSelection = backend.preset.id
            open(.backends)
        case .character("t"):
            isDark.toggle()
        case .character("3"):
            toggleTilt()
        case .character("?"):
            showsLegend.toggle()
        case .character("c"):
            selected = nil
            route = nil
            origin = nil
            destination = nil
        default:
            return trip.handleKey(event)
        }
        return .handled
    }

    // MARK: - Search

    /// The region in view, which a search prefers results near.
    @MainActor
    var visibleRegion: GeoRect {
        camera.visibleRegion(in: store.viewSize)
    }

    /// Enter in a search field: search for its text, or, when the results
    /// already answer it, go to the one selected.
    @MainActor
    func submit(_ target: SearchTarget) {
        let text = self.text(for: target).trimmingCharacters(in: .whitespacesAndNewlines)
        if let answered, answered.query == text, answered.target == target, !results.isEmpty {
            choose(resultSelection ?? results[0].id)
        } else {
            search(text, for: target)
        }
    }

    private func text(for target: SearchTarget) -> String {
        switch target {
        case .place: query
        case .origin: originText
        case .destination: destinationText
        }
    }

    /// Move the selection among the results, from the search field.
    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == resultSelection } ?? 0
        resultSelection = results[min(max(current + offset, 0), results.count - 1)].id
    }

    @MainActor
    func search(_ text: String, for target: SearchTarget) {
        searchTask?.cancel()
        guard !text.isEmpty else {
            results = []
            answered = nil
            return
        }
        searchProgress = .working
        let search = backend.search, region = visibleRegion
        searchTask = Task { @MainActor in
            do {
                let places = try await search.search(text, near: region)
                guard !Task.isCancelled else { return }
                maps.results = places.enumerated().map { SearchResult(id: $0.offset, place: $0.element) }
                maps.resultSelection = maps.results.first?.id
                maps.answered = (text, target)
                maps.searchProgress = places.isEmpty ? .failed("Nothing found for “\(text)”") : .done
            } catch {
                guard !Task.isCancelled else { return }
                maps.searchProgress = .failed(String(describing: error))
            }
        }
    }

    /// Go to a result: for a place search, fly there, pin it and close the
    /// panel; for directions, take it as that end of the route.
    @MainActor
    func choose(_ id: Int) {
        guard let result = results.first(where: { $0.id == id }), let target = answered?.target else { return }
        let place = result.place
        results = []
        answered = nil
        searchProgress = .idle
        switch target {
        case .place:
            selected = place
            placeDetails.show(place)
            query = ""
            route = nil
            fly(to: place.coordinate)
            panel = nil
        case .origin:
            origin = place
            originText = place.name
            computeRoute()
        case .destination:
            destination = place
            destinationText = place.name
            computeRoute()
        }
    }

    func fly(to coordinate: GeoCoordinate) {
        camera = MapCamera(center: coordinate, zoom: max(camera.zoom, MapsModel.placeZoom),
                           zoomRange: camera.zoomRange)
    }

    // MARK: - Directions

    /// Directions open from here — the map's middle — to the place pinned,
    /// routed at once when one is, and otherwise to a place to search for.
    @MainActor
    func openDirections() {
        origin = nil
        originText = ""
        results = []
        answered = nil
        if let selected {
            destination = selected
            destinationText = selected.name
            computeRoute()
        }
        open(.directions)
    }

    @MainActor
    func computeRoute() {
        routeTask?.cancel()
        guard let destination else { return }
        guard let routes = backend.routes else {
            routeProgress = .failed("\(backend.preset.title) gives no directions")
            return
        }
        let from = origin?.coordinate ?? camera.center
        guard MapsModel.metres(from, destination.coordinate) >= MapsModel.alreadyThere else {
            route = nil
            routeProgress = .failed("The map is at \(destination.name): move it, or search for a start")
            return
        }
        routeProgress = .working
        let viewSize = store.viewSize
        routeTask = Task { @MainActor in
            do {
                let route = try await routes.route(from: from, to: destination.coordinate, mode: .driving)
                guard !Task.isCancelled else { return }
                maps.route = route
                maps.routeProgress = .done
                maps.frame(route, in: viewSize)
            } catch {
                guard !Task.isCancelled else { return }
                maps.routeProgress = .failed(String(describing: error))
            }
        }
    }

    /// Bring the whole route into view, a little way in from the edges, and
    /// no closer than a place is shown: a route of a few metres fits at a
    /// zoom where its streets have gone.
    private func frame(_ route: Route, in viewSize: CanvasSize) {
        guard let box = GeoRect(covering: route.coordinates), viewSize.width > 0, viewSize.height > 0 else { return }
        let fitted = MapCamera.fitting(box, in: viewSize, zoomRange: camera.zoomRange)
        var framed = fitted.zoomed(by: -MapsModel.routeMargin)
        framed.zoom = min(framed.zoom, MapsModel.placeZoom)
        camera = framed
    }

    /// Zoom levels taken off a camera that just fits the route, so it does
    /// not run to the edges.
    static let routeMargin = 0.5

    /// Closer than this, in metres, the start is the destination: a step
    /// along a street, not a route.
    static let alreadyThere = 10.0

    /// The distance between two coordinates, in metres.
    static func metres(_ first: GeoCoordinate, _ second: GeoCoordinate) -> Double {
        first.distance(to: second)
    }

    // MARK: - Backends

    @MainActor
    func switchBackend(to preset: BackendPreset, pack: RegionPack? = nil) {
        do {
            let next = try Backend.make(preset, pack: pack ?? packs.first?.pack, details: detailsSource)
            searchTask?.cancel()
            routeTask?.cancel()
            backend = next
            store.replaceSource(next.tiles)
            placeDetails.replaceProvider(next.details)
            mapTypes.setOffer(next.mapTypeOffer)
            resetStreetImagery()
            results = []
            answered = nil
            route = nil
            selected = nil
            if let pack = next.pack {
                camera = MapCamera(center: pack.manifest.bounds.center,
                                   zoom: Double(pack.manifest.zoomRange.upperBound))
            }
            notice = nil
            panel = nil
        } catch {
            notice = String(describing: error)
        }
    }

    // MARK: - Downloads

    func refreshPacks() {
        do {
            packs = try packStore.list().map(PackRow.init)
            if packSelection == nil || !packs.contains(where: { $0.id == packSelection }) {
                packSelection = packs.first?.id
            }
        } catch {
            notice = "could not read the downloaded regions: \(error)"
        }
    }

    /// The zooms a download offers first: from a little out from the view
    /// to a little in, within what the source has.
    @MainActor
    func fitDownloadZooms() {
        let current = Int(camera.zoom.rounded(.down))
        let available = store.info?.zoomRange ?? 0...TileID.maximumZoom
        downloadMinimumZoom = min(max(current - MapsModel.downloadSpan, available.lowerBound), available.upperBound)
        downloadMaximumZoom = min(max(current + MapsModel.downloadSpan, downloadMinimumZoom), available.upperBound)
    }

    /// Move either end of the download's zooms, the two kept in order: the
    /// end not moved gives way.
    func adjustDownload(minimum: Int = 0, maximum: Int = 0) {
        downloadMinimumZoom = min(max(downloadMinimumZoom + minimum, 0), TileID.maximumZoom)
        downloadMaximumZoom = min(max(downloadMaximumZoom + maximum, 0), TileID.maximumZoom)
        if minimum != 0 {
            downloadMaximumZoom = max(downloadMaximumZoom, downloadMinimumZoom)
        } else {
            downloadMinimumZoom = min(downloadMinimumZoom, downloadMaximumZoom)
        }
    }

    /// How many tiles a download of the view would fetch.
    @MainActor
    var downloadTileCount: Int {
        RegionDownloader.tileCount(for: visibleRegion, zoomRange: downloadMinimumZoom...downloadMaximumZoom)
    }

    @MainActor
    func startDownload() {
        guard downloadProgress != .working else { return }
        guard let source = backend.downloads else {
            downloadProgress = .failed("\(backend.preset.title) cannot be downloaded")
            return
        }
        let region = visibleRegion
        let zooms = downloadMinimumZoom...downloadMaximumZoom
        let name = "\(backend.preset.title) \(MapsModel.describe(region.center)) z\(zooms.lowerBound)-\(zooms.upperBound)"
        let downloader = RegionDownloader(store: packStore, source: source)
        let total = RegionDownloader.tileCount(for: region, zoomRange: zooms)
        download = DownloadProgress(total: total)
        downloadProgress = .working
        downloadTask = Task { @MainActor in
            do {
                try await downloader.download(RegionDownloadRequest(name: name, bounds: region, zoomRange: zooms)) {
                    progress in
                    Task { @MainActor in maps.noteDownload(progress) }
                }
                try await maps.downloadLayers(named: name)
                maps.downloadProgress = .done
                maps.refreshPacks()
                maps.packSelection = name
            } catch {
                maps.downloadProgress = .failed(String(describing: error))
            }
        }
    }

    /// A download's progress, sent a tile at a time as tasks that may land
    /// out of order: only one further on than what is shown is taken.
    func noteDownload(_ progress: DownloadProgress) {
        if let download, download.total == progress.total, download.completed >= progress.completed { return }
        download = progress
    }

    func delete(_ name: String) {
        guard let row = packs.first(where: { $0.id == name }) else { return }
        do {
            try packStore.delete(row.pack)
        } catch {
            notice = "could not delete \(name): \(error)"
        }
        refreshPacks()
    }

    // MARK: - Words

    static func describe(_ coordinate: GeoCoordinate) -> String {
        let latitude = String(format: "%.4f°%@", abs(coordinate.latitude), coordinate.latitude >= 0 ? "N" : "S")
        let longitude = String(format: "%.4f°%@", abs(coordinate.longitude), coordinate.longitude >= 0 ? "E" : "W")
        return "\(latitude) \(longitude)"
    }

    static func describe(distance metres: Double) -> String {
        metres < Units.metresPerKilometre
            ? "\(Int(metres.rounded())) m"
            : String(format: "%.1f km", metres / Units.metresPerKilometre)
    }

    static func describe(duration seconds: Double) -> String {
        let minutes = Int((seconds / Units.secondsPerMinute).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < Units.minutesPerHour { return "\(minutes) min" }
        return "\(minutes / Units.minutesPerHour) h \(minutes % Units.minutesPerHour) min"
    }

    static func describe(bytes: Int) -> String {
        let kilobytes = Double(bytes) / Units.bytesPerKilobyte
        return kilobytes < Units.bytesPerKilobyte
            ? String(format: "%.0f KB", kilobytes)
            : String(format: "%.1f MB", kilobytes / Units.bytesPerKilobyte)
    }

    private enum Units {
        static let metresPerKilometre = 1_000.0
        static let secondsPerMinute = 60.0
        static let minutesPerHour = 60
        static let bytesPerKilobyte = 1_024.0
    }
}
