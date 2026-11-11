import Observation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

// A MapView in a graph, driven as the runtime drives it: pointer presses
// and drags through the focus engine, the wheel through its routing, keys
// to the focused view.

@MainActor
@Observable
private final class Model {
    var camera = MapCamera(center: SampleTown.origin, zoom: 15)
    var markers: [Marker] = []
}

@MainActor
private final class MapScreen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let model: Model
    let store: MapTileStore
    let width: Int
    let height: Int
    private(set) var buffer: CellBuffer
    private let environment: EnvironmentValues

    init(store: MapTileStore, model: Model = Model(), width: Int = 40, height: Int = 12) {
        self.store = store
        self.model = model
        self.width = width
        self.height = height
        buffer = CellBuffer(width: width, height: height)
        var environment = EnvironmentValues()
        environment.theme = MapTestTheme()
        environment.terminalSize = TerminalSize(cols: width, rows: height)
        self.environment = environment
        frame()
    }

    func frame() {
        engine.clearHandlers()
        let model = model, store = store
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(environment) {
                graph.update(from: MapView(camera: Binding(get: { model.camera }, set: { model.camera = $0 }),
                                           store: store) {
                    for marker in model.markers { marker }
                })
            }
        }
        draw()
    }

    func draw() {
        buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(environment) {
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)
    }

    @discardableResult
    func key(_ key: Key, modifiers: KeyModifiers = []) -> Bool {
        engine.routeKeyEvent(KeyEvent(key: key, modifiers: modifiers), root: graph.root)
    }

    @discardableResult
    func wheel(_ key: Key, at x: Int, _ y: Int, steps: Int = 3) -> Bool {
        engine.routeWheel(KeyEvent(key: key), root: graph.root!, x: x, y: y, policy: .clickToLock, steps: steps)
    }

    func text(row: Int) -> String { String((0..<width).map { buffer[$0, row].character }) }
}

@MainActor
private func sampleStore() async -> MapTileStore {
    let store = MapTileStore(source: SampleTileSource())
    _ = await waitUntil { store.info != nil }
    return store
}

private func close(_ first: GeoCoordinate, _ second: GeoCoordinate) -> Bool {
    let tolerance = 1e-9
    return abs(first.latitude - second.latitude) < tolerance && abs(first.longitude - second.longitude) < tolerance
}

@Suite("MapView")
@MainActor
struct MapViewTests {

    @Test func aDragPansTheMapWithThePointer() async {
        let screen = MapScreen(store: await sampleStore())
        let start = screen.model.camera
        screen.engine.handlePress(PointerPress(x: 20, y: 6), root: screen.graph.root)
        screen.frame()
        screen.engine.continueDrag(x: 25, y: 6)
        #expect(close(screen.model.camera.center, start.panned(byDotsX: 10, y: 0).center))
        screen.frame()
        screen.engine.continueDrag(x: 25, y: 8)
        #expect(close(screen.model.camera.center, start.panned(byDotsX: 10, y: 8).center),
                "each move pans by what it moved since the last")
        screen.engine.endDrag(x: 25, y: 8)
        #expect(screen.model.camera.zoom == start.zoom)
    }

    @Test func theWheelZoomsAboutThePointer() async {
        let screen = MapScreen(store: await sampleStore())
        let start = screen.model.camera
        let viewport = DotSize(columns: 40, rows: 12)
        let pointer = DotPoint(x: 5 * 2 + 1, y: 2 * 4 + 2)
        let under = start.coordinate(at: pointer, in: viewport)
        #expect(screen.wheel(.up, at: 5, 2))
        #expect(abs(screen.model.camera.zoom - (start.zoom + 1)) < 1e-9, "a notch is a zoom level")
        #expect(close(screen.model.camera.coordinate(at: pointer, in: viewport), under),
                "what was under the pointer is under it still")
        screen.frame()
        #expect(screen.wheel(.down, at: 5, 2, steps: 3))
        #expect(abs(screen.model.camera.zoom - start.zoom) < 1e-9)
    }

    @Test func aFocusedMapPansAndZoomsFromTheKeyboard() async {
        let screen = MapScreen(store: await sampleStore())
        screen.engine.focusNext()
        let start = screen.model.camera
        #expect(screen.key(.character("+")))
        #expect(screen.model.camera.zoom == start.zoom + 1)
        #expect(screen.key(.character("-")))
        #expect(screen.model.camera.zoom == start.zoom)
        #expect(screen.key(.left))
        #expect(screen.model.camera.center.longitude < start.center.longitude, "left looks west")
        #expect(screen.key(.character("l")))
        #expect(close(screen.model.camera.center, start.center), "and l comes back")
        #expect(screen.key(.character("j")))
        #expect(screen.model.camera.center.latitude < start.center.latitude, "j looks south")
        #expect(!screen.key(.character("x")), "a key the map has no use for passes on")
    }

    @Test func shiftAndTheArrowsTipTheMap() async {
        let screen = MapScreen(store: await sampleStore())
        screen.engine.focusNext()
        let start = screen.model.camera
        #expect(screen.key(.up, modifiers: .shift))
        #expect(screen.model.camera.pitch == MapView.Steps.pitch, "Shift-up tips the map away")
        #expect(screen.model.camera.center == start.center, "and does not pan it")
        for _ in 0..<10 { screen.key(.up, modifiers: .shift) }
        #expect(screen.model.camera.pitch == MapCamera.maximumPitch)
        #expect(!screen.key(.up, modifiers: .shift), "at the most, the key passes on")
        #expect(screen.key(.down, modifiers: .shift))
        #expect(screen.model.camera.pitch == MapCamera.maximumPitch - MapView.Steps.pitch)
        for _ in 0..<10 { screen.key(.down, modifiers: .shift) }
        #expect(screen.model.camera.pitch == 0)
        #expect(!screen.key(.down, modifiers: .shift), "straight down, the key passes on")
    }

    @Test func aDragOnAPitchedMapKeepsTheGroundUnderThePointer() async {
        let model = Model()
        model.camera.pitch = 50
        let screen = MapScreen(store: await sampleStore(), model: model)
        let viewport = DotSize(columns: 40, rows: 12)
        let middleOf = { (column: Int, row: Int) in DotPoint(x: Double(column * 2 + 1), y: Double(row * 4 + 2)) }
        let grabbed = model.camera.coordinate(at: middleOf(20, 3), in: viewport)
        screen.engine.handlePress(PointerPress(x: 20, y: 3), root: screen.graph.root)
        screen.frame()
        screen.engine.continueDrag(x: 24, y: 9)
        screen.frame()
        let landed = model.camera.screenPoint(for: grabbed, in: viewport)
        #expect(landed.map { abs($0.x - middleOf(24, 9).x) < 1e-6 && abs($0.y - middleOf(24, 9).y) < 1e-6 } == true)
        screen.engine.endDrag(x: 24, y: 9)
    }

    @Test func theSourcesCreditIsInTheBottomRightCorner() async {
        let screen = MapScreen(store: await sampleStore(), width: 60)
        #expect(screen.text(row: 11).hasSuffix(" \(SampleTown.attribution) "))
    }

    @Test func aMarkerInTheContentIsDrawnAtItsCoordinate() async {
        let model = Model()
        model.markers = [Marker("Town Hall", coordinate: model.camera.center)]
        let screen = MapScreen(store: await sampleStore(), model: model)
        #expect(screen.buffer[20, 6].character == "●")
        #expect(screen.text(row: 6).contains("● Town Hall"))
    }

    @Test func aTileLandingDrawsTheMapAgain() async {
        let source = GatedSource(zoomRange: 0...15)
        let store = MapTileStore(source: source)
        #expect(await waitUntil { store.info != nil })
        let model = Model()
        let screen = MapScreen(store: store, model: model)
        let wanted = MapRenderer.tiles(for: model.camera, size: CanvasSize(width: 40, height: 12), zoomRange: 0...15)
        #expect(await waitUntil { source.waiting == Set(wanted) }, "the frame asked for what it covers")
        #expect(!screen.graph.hasDirtyNodes)
        for tile in wanted {
            source.release(tile, with: SampleTileSource.tile(for: tile).map(MapTile.vector))
        }
        #expect(await waitUntil { screen.graph.hasDirtyNodes })
        #expect(screen.graph.drain())
        screen.draw()
        let residential = MapTestTheme().backgroundRaised
        #expect((0..<40).contains { screen.buffer[$0, 6].style.background == residential },
                "the town's ground is drawn")
    }
}
