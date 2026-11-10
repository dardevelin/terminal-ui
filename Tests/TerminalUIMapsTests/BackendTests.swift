import Foundation
import Testing
@testable import TerminalUIMaps

/// OpenFreeMap's TileJSON as it was served, trimmed of its layer list.
private let planetTileJSON = """
{"tilejson":"3.0.0","tiles":["https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf"],
"attribution":"<a href=\\"https://openfreemap.org\\" target=\\"_blank\\">OpenFreeMap</a> \
<a href=\\"https://www.openmaptiles.org/\\" target=\\"_blank\\">&copy; OpenMapTiles</a> \
Data from <a href=\\"https://www.openstreetmap.org/copyright\\" target=\\"_blank\\">OpenStreetMap</a>",
"bounds":[-180,-85.05113,180,85.05113],"center":[0,0,1],"maxzoom":14,"minzoom":0,"name":"OpenFreeMap"}
"""

@Suite struct OpenFreeMapTileSourceTests {
    private func source(_ transport: StubTransport) -> OpenFreeMapTileSource {
        OpenFreeMapTileSource(transport: transport, userAgent: "MapsTests/1")
    }

    private func stub() throws -> StubTransport {
        let tile = try RealTileTests.fixture()
        return StubTransport { request in
            switch request.url.absoluteString {
            case OpenFreeMapTileSource.planetURL.absoluteString:
                return .json(planetTileJSON)
            case "https://tiles.openfreemap.org/planet/20261101_080013_pt/14/7812/6233.pbf":
                return HTTPResponse(statusCode: 200, body: tile)
            default:
                return HTTPResponse(statusCode: 404, body: [])
            }
        }
    }

    @Test func readsTheTileJSON() async throws {
        let info = try await source(stub()).info()
        #expect(info.name == "OpenFreeMap")
        #expect(info.zoomRange == 0...14)
        #expect(info.attribution == "OpenFreeMap © OpenMapTiles Data from OpenStreetMap")
        #expect(info.bounds.north == 85.05113)
    }

    @Test func fetchesTilesFromTheTemplate() async throws {
        let transport = try stub()
        let tile = try await source(transport).tile(TileID(zoom: 14, x: 7812, y: 6233))
        guard case .vector(let vector) = tile else {
            Issue.record("expected a vector tile, got \(String(describing: tile))")
            return
        }
        #expect(vector[layer: "place"]?.features.contains { $0.properties["name"] == "Constância" } == true)
        #expect(transport.requests.allSatisfy { $0.headers["User-Agent"] == "MapsTests/1" })
    }

    @Test func fetchesTheTileJSONOnceForManyTiles() async throws {
        let transport = try stub()
        let openFreeMap = source(transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for column in 0..<6 {
                group.addTask { _ = try await openFreeMap.tileData(TileID(zoom: 14, x: 7812 + column, y: 6233)) }
            }
            try await group.waitForAll()
        }
        let tileJSONRequests = transport.requests.filter { $0.url == OpenFreeMapTileSource.planetURL }
        #expect(tileJSONRequests.count == 1)
        #expect(transport.requests.count == 7)
    }

    @Test func aMissingTileIsNilAndBeyondMaxZoomIsNotRequested() async throws {
        let transport = try stub()
        let openFreeMap = source(transport)
        #expect(try await openFreeMap.tileData(TileID(zoom: 14, x: 0, y: 0)) == nil)
        #expect(try await openFreeMap.tileData(TileID(zoom: 15, x: 0, y: 0)) == nil)
        #expect(transport.requests.count == 2)
    }

    @Test func aServerErrorThrowsAndAFailedTileJSONIsRetried() async throws {
        let transport = StubTransport { _ in HTTPResponse(statusCode: 503, body: []) }
        let openFreeMap = source(transport)
        await #expect(throws: MapServiceError.httpStatus(503, url: OpenFreeMapTileSource.planetURL)) {
            try await openFreeMap.info()
        }
        _ = try? await openFreeMap.info()
        #expect(transport.requests.count == 2)
    }
}

@Suite struct RequestLimiterTests {
    @Test func spacesRequestsOneIntervalApart() async throws {
        let clock = ManualClock()
        let limiter = RequestLimiter(interval: .seconds(1), clock: clock)
        try await limiter.waitForTurn()
        try await limiter.waitForTurn()
        try await limiter.waitForTurn()
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test func callersArrivingTogetherAreGivenSuccessiveSlots() async throws {
        let clock = ManualClock()
        let limiter = RequestLimiter(interval: .seconds(1), clock: clock)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await limiter.waitForTurn() } }
            try await group.waitForAll()
        }
        #expect(Set(clock.sleeps) == [.seconds(1), .seconds(2), .seconds(3)])
        #expect(clock.sleeps.count == 3)
    }
}

@Suite struct NominatimSearchTests {
    private let response = """
    [{"place_id":1,"lat":"39.4758","lon":"-8.3357","category":"boundary","type":"administrative",
      "name":"Constância","display_name":"Constância, Santarém, Portugal"},
     {"place_id":2,"lat":"39.47","lon":"-8.33","category":"amenity","type":"cafe","name":"",
      "display_name":"Café Vanda, Rua Luís de Camões, Constância, Portugal"},
     {"place_id":3,"lat":"not a number","lon":"0","name":"Broken"}]
    """

    @Test func searchesWithAUserAgentAndParsesPlaces() async throws {
        let body = response
        let transport = StubTransport { _ in .json(body) }
        let pacing = CountingPacing()
        let search = NominatimSearch(userAgent: "MapsTests/1 (test@example.org)", transport: transport,
                                     pacing: pacing)
        let region = GeoRect(south: 39.4, west: -8.4, north: 39.5, east: -8.3)
        let places = try await search.search("Constância", near: region)
        #expect(places == [
            Place(name: "Constância", kind: "administrative",
                  coordinate: GeoCoordinate(latitude: 39.4758, longitude: -8.3357),
                  address: "Constância, Santarém, Portugal"),
            Place(name: "Café Vanda", kind: "cafe", coordinate: GeoCoordinate(latitude: 39.47, longitude: -8.33),
                  address: "Café Vanda, Rua Luís de Camões, Constância, Portugal"),
        ])
        #expect(pacing.turns == 1)
        let request = try #require(transport.requests.first)
        #expect(request.headers["User-Agent"] == "MapsTests/1 (test@example.org)")
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "nominatim.openstreetmap.org")
        #expect(components.path == "/search")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["q"] == "Constância")
        #expect(items["format"] == "jsonv2")
        #expect(items["viewbox"] == "-8.4,39.5,-8.3,39.4")
    }

    @Test func anEmptyQueryAsksNothing() async throws {
        let transport = StubTransport { _ in .json("[]") }
        let search = NominatimSearch(userAgent: "MapsTests/1", transport: transport, pacing: CountingPacing())
        #expect(try await search.search("   ", near: nil).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func everySearchWaitsItsTurn() async throws {
        let clock = ManualClock()
        let search = NominatimSearch(userAgent: "MapsTests/1", transport: StubTransport { _ in .json("[]") },
                                     pacing: RequestLimiter(interval: NominatimSearch.minimumInterval, clock: clock))
        for query in ["a", "b", "c"] { _ = try await search.search(query, near: nil) }
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test func aBodyThatIsNotJSONThrows() async {
        let search = NominatimSearch(userAgent: "MapsTests/1", transport: StubTransport { _ in .json("<html>") },
                                     pacing: CountingPacing())
        await #expect(throws: MapServiceError.self) { try await search.search("x", near: nil) }
    }
}

@Suite struct OSRMRoutesTests {
    private let response = """
    {"code":"Ok","routes":[{"distance":1234.5,"duration":150.2,
      "geometry":{"type":"LineString","coordinates":[[-8.34,39.47],[-8.335,39.475],[-8.33,39.48]]},
      "legs":[{"steps":[
        {"distance":600,"duration":70,"name":"Rua Direita","maneuver":{"type":"depart","location":[-8.34,39.47]}},
        {"distance":634.5,"duration":80.2,"name":"Avenida das Forças Armadas",
         "maneuver":{"type":"turn","modifier":"left","location":[-8.335,39.475]}},
        {"distance":0,"duration":0,"name":"","maneuver":{"type":"arrive","location":[-8.33,39.48]}}]}]}]}
    """

    @Test func routesAndParsesSteps() async throws {
        let body = response
        let transport = StubTransport { _ in .json(body) }
        let routes = OSRMRoutes(transport: transport, userAgent: "MapsTests/1")
        let route = try await routes.route(from: GeoCoordinate(latitude: 39.47, longitude: -8.34),
                                           to: GeoCoordinate(latitude: 39.48, longitude: -8.33), mode: .driving)
        #expect(route.distance == 1234.5)
        #expect(route.duration == 150.2)
        #expect(route.coordinates.first == GeoCoordinate(latitude: 39.47, longitude: -8.34))
        #expect(route.coordinates.count == 3)
        #expect(route.steps.map(\.instruction) == ["Head along Rua Direita",
                                                   "Turn left onto Avenida das Forças Armadas",
                                                   "Arrive at your destination"])
        #expect(route.steps[1].coordinate == GeoCoordinate(latitude: 39.475, longitude: -8.335))
        let url = try #require(transport.requests.first?.url.absoluteString)
        #expect(url.hasPrefix("https://router.project-osrm.org/route/v1/driving/-8.34,39.47;-8.33,39.48?"))
        #expect(url.contains("steps=true"))
        #expect(url.contains("geometries=geojson"))
    }

    @Test func noRouteThrows() async {
        let routes = OSRMRoutes(transport: StubTransport { _ in
            .json(#"{"code":"NoRoute","message":"Impossible route between points"}"#)
        })
        await #expect(throws: MapServiceError.noRoute("Impossible route between points")) {
            try await routes.route(from: GeoCoordinate(latitude: 0, longitude: 0),
                                   to: GeoCoordinate(latitude: 1, longitude: 1), mode: .driving)
        }
    }

    @Test func theDemoServerDoesNotWalk() async {
        let transport = StubTransport { _ in .json("{}") }
        let routes = OSRMRoutes(transport: transport)
        await #expect(throws: MapServiceError.self) {
            try await routes.route(from: GeoCoordinate(latitude: 0, longitude: 0),
                                   to: GeoCoordinate(latitude: 1, longitude: 1), mode: .walking)
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct SampleSourceTests {
    @Test(arguments: [0, 6, 12, 14, 16, 19])
    func servesTheTownAtEveryZoom(zoom: Int) async throws {
        let source = SampleTileSource()
        let tile = TileID(containing: SampleTown.coordinate(east: -300, north: 200), zoom: zoom)
        let bytes = try #require(try await source.tileData(tile))
        let decoded = try VectorTileDecoder.decode(bytes)
        #expect(!decoded.layers.isEmpty)
        let limit = Int32(VectorLayer.defaultExtent + SampleTileSource.buffer)
        for layer in decoded.layers {
            for feature in layer.features {
                for point in feature.rings.flatMap({ $0 }) {
                    #expect((-Int32(SampleTileSource.buffer)...limit).contains(point.x))
                    #expect((-Int32(SampleTileSource.buffer)...limit).contains(point.y))
                }
            }
        }
    }

    @Test func aStreetTileHasItsLayers() async throws {
        let tile = try #require(SampleTileSource.tile(for: TileID(containing: SampleTown.origin, zoom: 13)))
        let names = Set(tile.layers.map(\.name))
        #expect(names.isSuperset(of: ["landuse", "park", "water", "waterway", "transportation",
                                      "transportation_name", "building", "poi"]))
        let park = try #require(tile[layer: "park"]?.features.first)
        #expect(park.polygons.first?.interiors.count == 1)
    }

    @Test func nothingIsServedAwayFromTheTown() async throws {
        #expect(try await SampleTileSource().tileData(TileID(zoom: 14, x: 7812, y: 6233)) == nil)
    }

    @Test func servesGzippedTilesWhenAsked() async throws {
        let tile = TileID(zoom: 13, x: 4096, y: 4095)
        let bytes = try #require(try await SampleTileSource(gzipped: true).tileData(tile))
        #expect(GZip.isCompressed(bytes))
        #expect(try VectorTileDecoder.decode(bytes) == SampleTileSource.tile(for: tile))
    }

    @Test func searchFindsPlacesAndStreets() async throws {
        let search = SampleSearch()
        #expect(try await search.search("copper", near: nil).first?.name == "The Copper Kettle")
        #expect(try await search.search("kettle", near: nil).first?.name == "The Copper Kettle")
        let streets = try await search.search("street", near: nil)
        #expect(streets.contains { $0.name == "High Street" })
        #expect(try await search.search("HIGH", near: nil).first?.name == "High Street")
        #expect(try await search.search("", near: nil).isEmpty)
        #expect(try await search.search("zzz", near: nil).isEmpty)
    }

    @Test func nearerPlacesRankFirst() async throws {
        let search = SampleSearch()
        let nearStation = GeoRect(covering: [SampleTown.coordinate(east: 0, north: -900)])
        let results = try await search.search("mill", near: nearStation)
        #expect(results.first?.name == "Millbrook Station")
    }
}
