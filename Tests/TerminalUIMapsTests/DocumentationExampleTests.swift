import Foundation
import Observation
import Testing
@testable import TerminalUI
import TerminalUIMaps

// The examples of TerminalUIMaps.docc's articles, as written there: each
// must build, and the ones that draw must draw something.

private struct TownMap: TerminalView {
    let store: MapTileStore
    @TerminalState var camera = MapCamera(center: SampleTown.origin, zoom: 15)

    var body: some TerminalView {
        MapView(camera: $camera, store: store)
    }
}

private struct PinnedMap: TerminalView {
    let store: MapTileStore
    let cafe: GeoCoordinate
    let route: Route?
    @TerminalState var camera = MapCamera(center: SampleTown.origin, zoom: 15)
    @TerminalState var selected: Place?

    var body: some TerminalView {
        let selected = $selected
        MapView(camera: $camera, store: store) {
            Marker("The Copper Kettle", coordinate: cafe)
            if let route {
                MapPolyline(route)
            }
        }
        .onPointOfInterestTap { point in
            selected.wrappedValue = point.place
        }
    }
}

private struct RoutedMap: TerminalView {
    let store: MapTileStore
    let route: Route
    let start: GeoCoordinate
    let cafe: GeoCoordinate
    @TerminalState var camera = MapCamera(center: SampleTown.origin, zoom: 15)

    var body: some TerminalView {
        MapView(camera: $camera, store: store) {
            MapPolyline(route)
            RouteEnds(route: route, origin: start, destination: cafe)
            Marker("The Copper Kettle", coordinate: cafe)
        }
    }
}

@MainActor @Observable
private final class Drive {
    var camera = MapCamera(center: SampleTown.origin, zoom: 16)
    var navigationCamera = NavigationCamera(profile: .car)
    var isAnimating = false
    let navigation = NavigationController()
    let store = MapTileStore(source: SampleTileSource())

    func receive(_ fix: LocationFix) async {
        navigationCamera.receive(fix)
        await navigation.receive(fix)
        isAnimating = true
    }

    func advance(to date: Date) {
        isAnimating = navigationCamera.advance(to: date, camera: &camera, navigation: navigation, store: store)
    }

    var content: MapContentGroup {
        MapContentGroup(navigationCamera.routeLines(for: navigation).mapElements
            + (navigationCamera.traveller?.mapElements ?? []))
    }
}

private struct DriveMap: TerminalView {
    let drive: Drive

    var body: some TerminalView {
        let drive = drive
        let content = MainActor.assumeIsolated { drive.content }
        let camera = Binding(get: { MainActor.assumeIsolated { drive.camera } },
                             set: { camera in MainActor.assumeIsolated { drive.camera = camera } })
        let paused = MainActor.assumeIsolated { !drive.isAnimating }
        ZStack {
            MapView(camera: camera, store: drive.store) {
                content
            }
            TimelineView(.animation(paused: paused)) { context in
                EmptyView().onChange(of: context.date) { _, date in
                    MainActor.assumeIsolated { drive.advance(to: date) }
                }
            }
        }
    }
}

@MainActor
@Suite("The documentation's examples")
struct DocumentationExampleTests {
    @Test func theSampleTownIsDrawnFromItsStore() async throws {
        let store = MapTileStore(source: SampleTileSource())
        let ready = try await settledTown(TownMap(store: store), store: store)
        #expect(ready.contains { (0x2801..<0x2900).contains($0.value) }, "the streets are drawn in braille")
    }

    @Test func markersRoutesAndRouteEndsBuild() async throws {
        let routes: any RouteProvider = SampleRoutes()
        let start = SampleTown.origin
        let cafe = try #require(try await SampleSearch().search("copper", near: nil).first).coordinate
        let route = try await routes.route(from: start, to: cafe, mode: .driving)
        var plan = RoutePlan(mode: .driving)
        plan.append("Home", at: start)
        plan.append("The Copper Kettle", at: cafe)
        let planned = try await routes.route(through: plan.coordinates, mode: plan.mode)
        #expect(!planned.steps.isEmpty)
        let store = MapTileStore(source: SampleTileSource())
        _ = try await settledTown(RoutedMap(store: store, route: route, start: start, cafe: cafe), store: store)
        _ = try await settledTown(PinnedMap(store: store, cafe: cafe, route: route), store: store)
    }

    @Test func searchFliesTheCamera() async throws {
        let store = MapTileStore(source: SampleTileSource())
        var camera = MapCamera(center: SampleTown.origin, zoom: 15)
        let search: any PlaceSearch = SampleSearch()
        let places = try await search.search("market", near: camera.visibleRegion(in: store.viewSize))
        if let first = places.first {
            camera = camera.centred(on: first.coordinate, zoom: 16)
        }
        #expect(camera.zoom == 16)
    }

    @Test func aPlaceCardShowsTheLoadersPlace() async throws {
        let place = try #require(try await SampleSearch().search("copper", near: nil).first)
        let loader = PlaceDetailsLoader(provider: SamplePlaceDetails())
        loader.show(place)
        #expect(await waitUntil { if case .loaded = loader.state { true } else { false } })
        let card = PlaceCardView(PlaceCardContent(state: loader.state, provider: loader.provider, now: .now,
                                                  timeZone: .current))
        #expect(!card.content.lines.isEmpty)
    }

    @Test func theMapTypesOfTheSampleTown() {
        let mapTypes = MapTypeModel(offer: .sample)
        mapTypes.select(.satellite)
        #expect(mapTypes.mapType == .satellite)
        #expect(mapTypes.layers.imagery != nil)
    }

    @Test func aDriveIsFollowed() async throws {
        let drive = Drive()
        let routes: any RouteProvider = SampleRoutes()
        let end = SampleTown.origin.destination(metres: 400)
        let route = try await routes.route(from: SampleTown.origin, to: end, mode: .driving)
        let plan = RoutePlan(places: [Place(name: "Start", kind: "start", coordinate: SampleTown.origin),
                                      Place(name: "End", kind: "end", coordinate: end)])
        drive.navigation.start(route: route, plan: plan, router: routes,
                               configuration: TravelProfile(mode: plan.mode).navigationConfiguration)
        await drive.receive(LocationFix(coordinate: SampleTown.origin, horizontalAccuracy: 5, timestamp: .now,
                                        source: .replay))
        let session = try #require(drive.navigation.session)
        _ = NavigationBanner(session: session, status: drive.navigation.status, destination: "The Copper Kettle")
        _ = try await settledTown(DriveMap(drive: drive), store: drive.store)
        drive.advance(to: .now)
        #expect(drive.navigationCamera.traveller != nil)
    }

    @Test func aRegionIsDownloadedAndReadOffline() async throws {
        let temporary = try TemporaryDirectory()
        let packs = RegionPackStore(directory: temporary.url)
        let store = MapTileStore(source: SampleTileSource())
        let camera = MapCamera(center: SampleTown.origin, zoom: 15)
        let downloader = RegionDownloader(store: packs, source: SampleTileSource())
        let region = camera.visibleRegion(in: CanvasSize(width: 40, height: 12))
        #expect(RegionDownloader.tileCount(for: region, zoomRange: 14...15) <= RegionDownloader.defaultTileLimit)
        let pack = try await downloader.download(RegionDownloadRequest(name: "Millbrook", bounds: region,
                                                                       zoomRange: 14...15)) { progress in
            _ = "\(progress.completed) of \(progress.total)"
        }
        let imagery = RegionLayerDownloader(source: SampleImagerySource(), kind: .imagery, encoding: .picture)
        try await imagery.download(into: pack)
        for pack in try packs.list() {
            let tiles = MapTileStore(source: OfflineTileSource(pack: pack))
            let search = OfflineSearch(pack: pack)
            #expect(!(try await search.search("market", near: nil)).isEmpty)
            _ = tiles
        }
        _ = store
    }

    @Test func aTrackIsReplayed() async throws {
        let document = GPXDocument(name: "drive", routes: [], tracks: [
            GPXTrack(name: "drive", segments: [[GPXPoint(coordinate: SampleTown.origin),
                                                GPXPoint(coordinate: SampleTown.origin.destination(metres: 50))]]),
        ])
        let provider = GPXReplayProvider(track: document.tracks[0].segments[0], speed: 4)
        let navigation = NavigationController()
        var fixes = 0
        for try await fix in provider.fixes() {
            await navigation.receive(fix)
            fixes += 1
            break
        }
        #expect(fixes == 1)
    }

    /// What `view` draws once the store has every tile its first frame
    /// asked for.
    private func settledTown(_ view: some TerminalView, store: MapTileStore) async throws -> [Unicode.Scalar] {
        let graph = AttributeGraph()
        let width = 60, height = 20
        var environment = EnvironmentValues()
        environment.theme = MapTestTheme()
        environment.terminalSize = TerminalSize(cols: width, rows: height)
        func draw() -> [Unicode.Scalar] {
            var buffer = CellBuffer(width: width, height: height)
            let rect = Rect(x: 0, y: 0, width: width, height: height)
            GraphContext.$currentEnvironment.withValue(environment) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
            return (0..<height).flatMap { row in (0..<width).flatMap { buffer[$0, row].character.unicodeScalars } }
        }
        _ = draw()
        #expect(await waitUntil { store.info != nil })
        _ = draw()
        #expect(await waitUntil { store.loadingCount == 0 })
        return draw()
    }
}

extension GeoCoordinate {
    /// A point `metres` east, for a route of the sample town's.
    fileprivate func destination(metres: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude + metres / 111_320)
    }
}
