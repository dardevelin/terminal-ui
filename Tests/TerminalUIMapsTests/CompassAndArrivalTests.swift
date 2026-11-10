import Foundation
import Testing
@testable import TerminalUI
@testable import TerminalUIMaps

/// A view drawn into `width` × `height` cells, as text.
@MainActor
func renderView(_ view: some TerminalView, width: Int, height: Int) -> String {
    let graph = AttributeGraph()
    let engine = FocusEngine()
    var environment = EnvironmentValues()
    environment.theme = MapTestTheme()
    environment.terminalSize = TerminalSize(cols: width, rows: height)
    var buffer = CellBuffer(width: width, height: height)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(environment) {
            graph.update(from: view)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
    }
    return buffer.text
}

@Suite("The map's compass")
@MainActor
struct MapCompassTests {
    // A ring drawn in braille a few cells across came out a lumpy octagon:
    // fonts leave uneven gaps between braille cells, which no circle that
    // small survives. The rose is a frame of box-drawing lines instead,
    // crisp in any font, with the "N" set on the frame where north lies and
    // an arrow in the middle pointing to it.

    @Test("North up: the N on the top edge, the arrow pointing up")
    func northUp() {
        #expect(MapCompass.rows(MapCompassReading(bearing: 0)) == ["╭──N──╮", "│  ↑  │", "╰─────╯"])
    }

    @Test("Turned, the N moves round the frame to where north lies on the screen, and the arrow follows")
    func turned() {
        // East up: north is to the left.
        #expect(MapCompass.rows(MapCompassReading(bearing: 90)) == ["╭─────╮", "N  ←  │", "╰─────╯"])
        #expect(MapCompass.rows(MapCompassReading(bearing: 180)) == ["╭─────╮", "│  ↓  │", "╰──N──╯"])
        #expect(MapCompass.rows(MapCompassReading(bearing: 270)) == ["╭─────╮", "│  →  N", "╰─────╯"])
        // North-east up: north is up and to the left.
        #expect(MapCompass.rows(MapCompassReading(bearing: 45)) == ["N─────╮", "│  ↖  │", "╰─────╯"])
    }

    @Test("Bearings between the eight points go to the nearest")
    func nearestPoint() {
        #expect(MapCompass.rows(MapCompassReading(bearing: 20)) == MapCompass.rows(MapCompassReading(bearing: 0)))
        #expect(MapCompass.rows(MapCompassReading(bearing: 25)) == MapCompass.rows(MapCompassReading(bearing: 45)))
        #expect(MapCompass.rows(MapCompassReading(bearing: 350)) == MapCompass.rows(MapCompassReading(bearing: 0)))
    }

    @Test("Every row is the compass's width, so the rose is a solid block over the map")
    func solid() {
        for bearing in stride(from: 0.0, to: 360, by: 15) {
            for row in MapCompass.rows(MapCompassReading(bearing: bearing)) {
                #expect(row.count == MapCompass.width)
            }
        }
    }

    @Test("The reading gives whole degrees, and only a turned map is rotated")
    func reading() {
        #expect(!MapCompassReading(bearing: 0.2).isRotated)
        #expect(!MapCompassReading(bearing: 359.8).isRotated)
        #expect(MapCompassReading(bearing: 44.6).degrees == 45)
        #expect(MapCompassReading(bearing: -90).degrees == 270)
    }
}

@Suite("The following map's orientation")
struct OrientationTests {
    @Test("u cycles heading up, north up, locked at the bearing the map has, and back")
    func cycle() {
        var follow = FollowCamera()
        #expect(follow.configuration.orientation == .headingUp)
        #expect(follow.cycleOrientation(currentBearing: 120) == .northUp)
        #expect(follow.cycleOrientation(currentBearing: 33) == .locked)
        #expect(follow.configuration.lockedBearing == 33)
        #expect(follow.cycleOrientation(currentBearing: 33) == .headingUp)
    }

    @Test("Locked, the map keeps its bearing whatever the course")
    func lockedHolds() {
        var follow = FollowCamera()
        follow.configuration.orientation = .locked
        follow.configuration.lockedBearing = 200
        let here = GeoCoordinate(latitude: 0.02, longitude: 0.02)
        #expect(follow.pose(for: here, course: 10, speed: 12, bearing: 10).bearing == 200)
        #expect(follow.pose(for: here, course: 300, speed: 12, bearing: 10).bearing == 200)
    }

    @Test("Turning a following map by hand locks it there, as Apple Maps does")
    func rotateLocks() {
        var follow = FollowCamera()
        follow.rotate(by: 15, currentBearing: 350)
        #expect(follow.configuration.orientation == .locked)
        #expect(follow.configuration.lockedBearing == 5)
        follow.rotate(by: -15, currentBearing: 123)
        #expect(follow.configuration.lockedBearing == 350, "a second turn goes on from the lock, not the frame")
    }

    @Test("A tap on the compass: turned goes north up, north up goes heading up")
    func compassTaps() {
        var follow = FollowCamera()
        follow.compassTapped(currentBearing: 75)
        #expect(follow.configuration.orientation == .northUp)
        follow.compassTapped(currentBearing: 0)
        #expect(follow.configuration.orientation == .headingUp)
        follow.configuration.orientation = .locked
        follow.configuration.lockedBearing = 40
        follow.compassTapped(currentBearing: 40)
        #expect(follow.configuration.orientation == .northUp)
    }
}

@Suite("Where a route meets its stops")
@MainActor
struct RouteEndsTests {
    private let ground = Ground()

    @Test("A destination off the road's end is joined by a dashed line, and said to be on the left")
    func destinationOnTheLeft() throws {
        // West along a street, the place 25 m south of its end.
        let route = ground.route([(300, 0), (0, 0)])
        let ends = RouteEnds(route: route, origin: ground.point(300, 0), destination: ground.point(0, -25))
        #expect(ends.side == .left)
        #expect(abs(ends.destinationGap - 25) < 0.1)
        #expect(ends.destinationConnector?.count == 2)
        #expect(ends.originConnector == nil, "the start is on the route")
        #expect(ends.arrivalWords(destination: "Public Library") == "Public Library, 30 m on your left")
        let right = RouteEnds(route: route, origin: nil, destination: ground.point(0, 25))
        #expect(right.side == .right)
        let ahead = RouteEnds(route: route, origin: nil, destination: ground.point(-25, 1))
        #expect(ahead.arrivalWords(destination: "Café") == "Café, 30 m ahead")
    }

    @Test("A place on the route needs no line and no side")
    func onTheRoute() {
        let route = ground.route([(300, 0), (0, 0)])
        let ends = RouteEnds(route: route, origin: ground.point(310, 2), destination: ground.point(1, 1))
        #expect(ends.destinationConnector == nil && ends.side == nil)
        #expect(ends.originConnector != nil, "the traveller set off 10 m from the route's start")
        #expect(ends.arrivalWords(destination: "Home") == "Home")
    }

    @Test("The connector is drawn dashed: braille, a blank cell, braille")
    func connectorIsDashed() {
        let start = GeoCoordinate(latitude: 0.0001, longitude: -0.0006)
        let end = GeoCoordinate(latitude: 0.0001, longitude: 0.0006)
        let polyline = MapPolyline(coordinates: [start, end], lineWidth: 0, style: .connector)
        let camera = MapCamera(center: GeoCoordinate(latitude: 0.0001, longitude: 0), zoom: 17)
        let buffer = drawMap(width: 40, height: 6) { context, size in
            MapRenderer().draw(in: context, camera: camera, size: size, zoomRange: 0...14,
                               content: [.polyline(polyline)]) { _ in nil }
        }
        let rowText = (0..<buffer.height).map(buffer.row).first { $0.contains { ch in
            ch.unicodeScalars.first.map { (0x2801...0x28FF).contains($0.value) } ?? false
        } } ?? ""
        let marks = rowText.map { ch in ch.unicodeScalars.first.map { (0x2801...0x28FF).contains($0.value) } ?? false }
        let first = marks.firstIndex(of: true) ?? 0, last = marks.lastIndex(of: true) ?? 0
        let gaps = marks[first...last].filter { !$0 }.count
        #expect(last - first > 10, "a line across the screen: \(rowText)")
        #expect(gaps >= (last - first) / 5, "dashes and gaps alternate: \(rowText)")
    }

    @Test("The banner says the place, its distance and its side on arriving")
    func bannerWords() throws {
        let route = ground.route([(300, 0), (0, 0)])
        let ends = RouteEnds(route: route, origin: nil, destination: ground.point(0, -25))
        var session = NavigationSession(route: route)
        session.update(LocationFix(coordinate: ground.point(5, 0), horizontalAccuracy: 5, course: 270, speed: 5,
                                   timestamp: Date(timeIntervalSince1970: 0), source: .replay))
        #expect(session.state == .arrived)
        let banner = NavigationBanner(session: session, status: .arrived, destination: "Public Library", ends: ends)
        let host = renderView(banner, width: 90, height: 5)
        #expect(host.contains("You have arrived at Public Library, 30 m on your left"), "\(host)")
    }
}
