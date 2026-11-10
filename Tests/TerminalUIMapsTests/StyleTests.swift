import Testing
@testable import TerminalUIMaps

@Suite struct MapRoleTests {
    @Test func everyRoleIsDrawnOnce() {
        #expect(MapRole.drawSequence.count == MapRole.allCases.count)
        #expect(Set(MapRole.drawSequence) == Set(MapRole.allCases))
    }

    @Test func labelsAreRankedAndDrawnLast() {
        let labels = MapRole.allCases.filter { $0.geometry == .label }
        #expect(Set(MapRole.labelPriority) == Set(labels))
        let lastShape = MapRole.allCases.filter { $0.geometry != .label }.map(\.drawOrder).max() ?? 0
        #expect(labels.allSatisfy { $0.drawOrder > lastShape })
        #expect(MapRole.motorway.labelRank == nil)
        #expect(MapRole.cityLabel.labelRank! < MapRole.townLabel.labelRank!)
        #expect(MapRole.poiLabel.labelRank! < MapRole.roadLabel.labelRank!)
    }

    @Test func biggerRoadsAreDrawnOverSmallerOnesAndAppearSooner() {
        let roads: [MapRole] = [.path, .serviceRoad, .minorRoad, .tertiary, .secondary, .primary, .trunk, .motorway]
        #expect(roads.map(\.drawOrder) == roads.map(\.drawOrder).sorted())
        let zooms = roads.map(\.minimumZoom)
        #expect(zooms == zooms.sorted(by: >))
        #expect(MapRole.water.drawOrder < MapRole.building.drawOrder)
        #expect(MapRole.landcover.drawOrder < MapRole.water.drawOrder)
    }

    @Test(arguments: [
        ("water", "lake", MapRole.water), ("waterway", "stream", .waterway), ("park", "nature_reserve", .park),
        ("landcover", "wood", .landcover), ("landuse", "residential", .landuse), ("building", "", .building),
        ("transportation", "motorway", .motorway), ("transportation", "trunk", .trunk),
        ("transportation", "primary", .primary), ("transportation", "secondary_construction", .secondary),
        ("transportation", "tertiary", .tertiary), ("transportation", "minor", .minorRoad),
        ("transportation", "service", .serviceRoad), ("transportation", "track", .serviceRoad),
        ("transportation", "path", .path), ("transportation", "rail", .rail), ("transportation", "transit", .rail),
        ("boundary", "", .boundary), ("transportation_name", "minor", .roadLabel),
        ("water_name", "lake", .lakeLabel), ("water_name", "sea", .waterLabel), ("housenumber", "", .houseNumberLabel), ("poi", "cafe", .poiLabel), ("place", "city", .cityLabel),
        ("place", "town", .townLabel), ("place", "hamlet", .villageLabel), ("place", "suburb", .suburbLabel),
        ("place", "country", .countryLabel), ("place", "state", .regionLabel),
    ])
    func openMapTilesClassesMapToRoles(layer: String, featureClass: String, role: MapRole) {
        #expect(MapRole(layer: layer, properties: ["class": .string(featureClass)]) == role)
    }

    @Test func whatTheMapDoesNotDrawHasNoRole() {
        #expect(MapRole(layer: "aeroway", properties: ["class": "runway"]) == nil)
        #expect(MapRole(layer: "transportation", properties: ["class": "ferry"]) == nil)
        #expect(MapRole(layer: "place", properties: ["class": "continent_label"]) == nil)
    }

    @Test func theRealTilesRoadsAllHaveRoles() throws {
        let tile = try VectorTileDecoder.decode(RealTileTests.fixture())
        let roads = try #require(tile[layer: "transportation"]).features.filter { $0.kind == .lineString }
        let unmapped = roads.filter { MapRole(layer: "transportation", properties: $0.properties) == nil }
        #expect(unmapped.isEmpty, "unmapped classes: \(unmapped.compactMap { $0.properties["class"] })")
    }
}

