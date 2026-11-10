import Foundation

/// Millbrook, a fictional town built in code: a river with a bridge, a park
/// with a pond, a grid of named streets, a railway and a bypass, buildings,
/// and a few places to look for. It sits beside Null Island (0° N, 0° E),
/// where the real map is open sea, so it is never mistaken for a real
/// place: at the middle of zoom-13 tile 4096/4095, so the whole town is one
/// tile at zoom 13 and below, and only deeper zooms cut it up.
///
/// Its features are laid out in metres east and north of the origin and
/// kept in the OpenMapTiles schema, so the sample source's tiles read like
/// OpenFreeMap's.
public enum SampleTown {
    /// "Millbrook".
    public static let name = "Millbrook"
    /// The town's middle, the point its features are laid out in metres
    /// east and north of.
    public static let origin = GeoCoordinate(latitude: 0.022, longitude: 0.022)
    /// The credit the sample sources give, saying the data is made up.
    public static let attribution = "Sample data: Millbrook is fictional"

    /// The town and a margin around it.
    public static let bounds: GeoRect = {
        let southWest = coordinate(east: -extent, north: -extent)
        let northEast = coordinate(east: extent, north: extent)
        return GeoRect(south: southWest.latitude, west: southWest.longitude,
                       north: northEast.latitude, east: northEast.longitude)
    }()

    /// How far the town reaches from its origin, in metres.
    static let extent = 1_200.0

    /// A feature in geographic coordinates, before it is cut into tiles.
    struct Feature: Sendable {
        enum Shape: Sendable {
            case point(GeoCoordinate)
            case line([GeoCoordinate])
            /// An exterior ring and its holes.
            case polygon([GeoCoordinate], holes: [[GeoCoordinate]])
        }

        var layer: String
        var shape: Shape
        var properties: [String: VectorValue]
        /// The lowest zoom whose tiles carry it, as a tile server leaves the
        /// small things out of its outer zooms (``LayerZoom``).
        var minimumZoom = 0
        /// For a point of interest, its importance, lower first: the order
        /// the source ranks it in within its cell of a tile's grid, as
        /// OpenMapTiles ranks its `poi` layer (``PointOfInterestDensity``).
        var priority = 0
    }

    /// OpenMapTiles' first zooms for the layers the town fills in close up
    /// (openmaptiles.org/schema: `building` from 13, `housenumber` from 14,
    /// `poi` from 12).
    enum LayerZoom {
        static let building = 13
        static let houseNumber = 14
        static let pointOfInterest = 12
    }

    /// How far east and north of the origin a coordinate is, in metres:
    /// the inverse of `coordinate(east:north:)`.
    static func metres(of coordinate: GeoCoordinate) -> (east: Double, north: Double) {
        let origin = WebMercator.project(SampleTown.origin)
        let point = WebMercator.project(coordinate)
        let metres = WebMercator.metresPerWorldUnit(atLatitude: SampleTown.origin.latitude)
        return ((point.x - origin.x) * metres, (origin.y - point.y) * metres)
    }

    /// The coordinate `east` and `north` metres from the origin.
    static func coordinate(east: Double, north: Double) -> GeoCoordinate {
        let origin = WebMercator.project(SampleTown.origin)
        let metres = WebMercator.metresPerWorldUnit(atLatitude: SampleTown.origin.latitude)
        return WebMercator.unproject(WorldPoint(x: origin.x + east / metres, y: origin.y - north / metres))
    }

    private static func points(_ metres: [(Double, Double)]) -> [GeoCoordinate] {
        metres.map { coordinate(east: $0.0, north: $0.1) }
    }

    private static func rectangle(west: Double, south: Double, east: Double, north: Double) -> [GeoCoordinate] {
        points([(west, south), (east, south), (east, north), (west, north)])
    }

    /// The river's centreline, north to south, and its half-width.
    private static let riverCentreline: [(Double, Double)] = [
        (380, 1_200), (420, 700), (380, 250), (440, -200), (400, -650), (430, -1_200),
    ]
    private static let riverHalfWidth = 22.0

    /// Half the side of a building's square footprint, in metres.
    private static let buildingHalfSide = 15.0

    /// A street of the town: its name, its OpenMapTiles class and its path
    /// in metres east and north of the origin.
    struct Street: Sendable {
        var name: String
        var roadClass: String
        var path: [(Double, Double)]
        /// OpenMapTiles' `subclass` of a path: `footway` or `cycleway`.
        var subclass: String?
        /// Travelled only the way its path runs, by those who keep to the
        /// road's rules: drivers and riders, not walkers.
        var isOneWay = false
        /// A roundabout's ring, which directions count the exits of.
        var isRoundabout = false

        init(name: String, roadClass: String, path: [(Double, Double)], subclass: String? = nil,
             isOneWay: Bool = false, isRoundabout: Bool = false) {
            self.name = name
            self.roadClass = roadClass
            self.path = path
            self.subclass = subclass
            self.isOneWay = isOneWay
            self.isRoundabout = isRoundabout
        }

        /// Whether `mode` may use the street: no one walks or rides on the
        /// bypass, no car takes a path, and a bicycle only a cycleway of
        /// them — the access OSRM's car, bicycle and foot profiles give
        /// those classes.
        func allows(_ mode: TravelMode) -> Bool {
            switch mode {
            case .driving: roadClass != Self.pathClass
            case .cycling: roadClass != Self.motorwayClass
                && (roadClass != Self.pathClass || subclass == Self.cyclewaySubclass)
            case .walking: roadClass != Self.motorwayClass
            }
        }

        /// Whether `mode` keeps to its one-way direction.
        func isOneWay(for mode: TravelMode) -> Bool { isOneWay && mode != .walking }

        static let pathClass = "path"
        static let motorwayClass = "motorway"
        static let cyclewaySubclass = "cycleway"
        static let footwaySubclass = "footway"
    }

    /// Five Ways, the town's confusing corner, east of the river: High
    /// Street, Tannery Road south, and Crown Street and Abbey Lane leaving
    /// north 25° apart; Abbey Lane leads to Kiln Circus, a roundabout 24 m
    /// across taken clockwise, as a British one is; its north exit, Eastwood
    /// Drive, meets Charcoal Lane 20 m short of Copse Road, a staggered
    /// crossroads that is a right turn and a left 20 m apart.
    enum FiveWays {
        static let junction = (600.0, 0.0)
        static let circusCentre = (671.0, 123.0)
        static let circusRadius = 12.0
        /// The ring's points every 30°, clockwise from north.
        static let ringStep = 30.0
        static let crownStreetEnd = (626.0, 290.0)

        /// The point of the ring at a bearing from its centre.
        static func ring(_ bearing: Double) -> (Double, Double) {
            let radians = bearing * .pi / Degrees.halfTurn
            return (circusCentre.0 + circusRadius * sin(radians), circusCentre.1 + circusRadius * cos(radians))
        }

        /// The ring, once round from north and back.
        static var circus: [(Double, Double)] {
            stride(from: 0.0, through: Degrees.fullTurn, by: ringStep).map(ring)
        }

        /// The arms' bearings from the circus's centre.
        static let abbeyArm = 210.0
        static let potteryArm = 300.0
        static let eastwoodArm = 0.0
        static let kilnArm = 90.0

        static let staggerNorth = 230.0
        static let copseEast = 691.0
    }

    /// The streets of Five Ways.
    private static let fiveWaysStreets: [Street] = {
        let eastwood = FiveWays.ring(FiveWays.eastwoodArm)
        return [
            Street(name: "Tannery Road", roadClass: "minor", path: [FiveWays.junction, (600, -350)]),
            Street(name: "Crown Street", roadClass: "minor", path: [FiveWays.junction, FiveWays.crownStreetEnd]),
            Street(name: "Abbey Lane", roadClass: "minor", path: [FiveWays.junction, FiveWays.ring(FiveWays.abbeyArm)]),
            Street(name: "Kiln Circus", roadClass: "minor", path: FiveWays.circus, isOneWay: true, isRoundabout: true),
            Street(name: "Pottery Lane", roadClass: "minor", path: [FiveWays.ring(FiveWays.potteryArm), (580, 129)]),
            Street(name: "Kiln Road", roadClass: "minor", path: [FiveWays.ring(FiveWays.kilnArm), (900, 123)]),
            Street(name: "Eastwood Drive", roadClass: "minor", path: [eastwood, (eastwood.0, FiveWays.staggerNorth)]),
            Street(name: "Charcoal Lane", roadClass: "minor", path: [(560, FiveWays.staggerNorth), (800, FiveWays.staggerNorth)]),
            Street(name: "Copse Road", roadClass: "minor", path: [(FiveWays.copseEast, FiveWays.staggerNorth),
                                                                 (FiveWays.copseEast, 400)]),
        ]
    }()

    static let streets: [Street] = [
        Street(name: "Elm Street", roadClass: "minor", path: [(-900, -1_000), (-900, 1_000)]),
        Street(name: "Oak Street", roadClass: "minor", path: [(-600, -1_000), (-600, 1_000)]),
        Street(name: "Market Street", roadClass: "tertiary", path: [(-300, -1_000), (-300, 1_000)]),
        Street(name: "Church Lane", roadClass: "minor", path: [(0, -1_000), (0, 1_000)]),
        Street(name: "Quay Street", roadClass: "minor", path: [(300, -1_000), (300, 1_000)]),
        Street(name: "Station Road", roadClass: "minor", path: [(-1_000, -800), (300, -800)]),
        Street(name: "Mill Road", roadClass: "secondary", path: [(-1_000, -400), (300, -400)]),
        Street(name: "High Street", roadClass: "primary", path: [(-1_000, 0), (1_000, 0)]),
        Street(name: "Park Avenue", roadClass: "minor", path: [(-1_000, 400), (300, 400)]),
        Street(name: "North Road", roadClass: "minor", path: [(-1_000, 800), (300, 800)]),
        Street(name: "Foundry Way", roadClass: "service", path: [(500, -350), (850, -350), (850, -900)]),
        Street(name: "Willow Walk", roadClass: "path", path: [(-500, 100), (-100, 500)], subclass: "footway"),
        Street(name: "Ropewalk", roadClass: "path", path: [(-750, -800), (-750, -400)], subclass: "footway"),
        Street(name: "Weavers Alley", roadClass: "path", path: [(-450, -400), (-450, 0)], subclass: "footway"),
        Street(name: "Chapel Passage", roadClass: "path", path: [(150, 0), (150, 400)], subclass: "footway"),
        Street(name: "Towpath", roadClass: "path", path: [(345, -900), (345, 900)], subclass: "cycleway"),
        Street(name: "Millbrook Bypass", roadClass: "motorway", path: [(950, -1_200), (950, 1_200)]),
        // A cycle path from Park Avenue's end over the river to High
        // Street by Five Ways: the way a rider goes that a car cannot.
        Street(name: "Silver Greenway", roadClass: "path", path: [(300, 400), (520, 0)], subclass: "cycleway"),
    ] + fiveWaysStreets

    private struct Landmark {
        var name: String
        var layer: String
        var featureClass: String
        var subclass: String?
        var position: (Double, Double)
        var address: String?
        /// False for a place search finds but the map names otherwise: a
        /// river is named along its line.
        var onMap = true
    }

    private static let landmarks: [Landmark] = [
        Landmark(name: "Millbrook", layer: "place", featureClass: "town", position: (-200, -200)),
        Landmark(name: "Old Town", layer: "place", featureClass: "suburb", position: (-650, -550)),
        Landmark(name: "Riverside", layer: "place", featureClass: "suburb", position: (680, -620)),
        Landmark(name: "Parkside", layer: "place", featureClass: "suburb", position: (-350, 680)),
        Landmark(name: "Millbrook Station", layer: "poi", featureClass: "railway", subclass: "station",
                 position: (0, -880), address: "Station Road, Millbrook"),
        Landmark(name: "The Copper Kettle", layer: "poi", featureClass: "cafe", subclass: "cafe",
                 position: (-270, 30), address: "12 High Street, Millbrook"),
        Landmark(name: "Town Hall", layer: "poi", featureClass: "town_hall", subclass: "townhall",
                 position: (-150, -40), address: "1 High Street, Millbrook"),
        Landmark(name: "Public Library", layer: "poi", featureClass: "library", subclass: "library",
                 position: (-630, 380), address: "Park Avenue, Millbrook"),
        Landmark(name: "Riverside Pharmacy", layer: "poi", featureClass: "pharmacy", subclass: "pharmacy",
                 position: (520, -30), address: "40 High Street, Millbrook"),
        Landmark(name: "St Anne's Church", layer: "poi", featureClass: "place_of_worship",
                 subclass: "place_of_worship", position: (30, 430), address: "Church Lane, Millbrook"),
        Landmark(name: "Mill Bakery", layer: "poi", featureClass: "bakery", subclass: "bakery",
                 position: (-570, -380), address: "Mill Road, Millbrook"),
        Landmark(name: "Silver River", layer: "water_name", featureClass: "river", position: (420, 520),
                 onMap: false),
        Landmark(name: "Duck Pond", layer: "water_name", featureClass: "lake", position: (-300, 300)),
    ] + businesses

    /// The shops, pubs and services along the town's streets, which close
    /// zooms show: the most important first, as the source ranks them.
    private static let businesses: [Landmark] = [
        Landmark(name: "Millbrook Bank", layer: "poi", featureClass: "bank", subclass: "bank",
                 position: (-200, 20), address: "8 High Street, Millbrook"),
        Landmark(name: "Post Office", layer: "poi", featureClass: "post", subclass: "post_office",
                 position: (-230, -20), address: "5 High Street, Millbrook"),
        Landmark(name: "Police Station", layer: "poi", featureClass: "police", subclass: "police",
                 position: (-880, -20), address: "71 High Street, Millbrook"),
        Landmark(name: "Bridge End Stop", layer: "poi", featureClass: "bus", subclass: "bus_stop",
                 position: (-100, 12), address: "High Street, Millbrook"),
        Landmark(name: "Station Hotel", layer: "poi", featureClass: "lodging", subclass: "hotel",
                 position: (40, -830), address: "2 Station Road, Millbrook"),
        Landmark(name: "Dr Patel's Surgery", layer: "poi", featureClass: "doctors", subclass: "doctors",
                 position: (-280, 420), address: "Park Avenue, Millbrook"),
        Landmark(name: "The Riverside Inn", layer: "poi", featureClass: "beer", subclass: "pub",
                 position: (260, -20), address: "38 High Street, Millbrook"),
        Landmark(name: "Golden Dragon", layer: "poi", featureClass: "restaurant", subclass: "restaurant",
                 position: (-420, 20), address: "22 High Street, Millbrook"),
        Landmark(name: "Pizza Mill", layer: "poi", featureClass: "restaurant", subclass: "restaurant",
                 position: (-330, -385), address: "3 Mill Road, Millbrook"),
        Landmark(name: "Fryer Tuck", layer: "poi", featureClass: "fast_food", subclass: "fast_food",
                 position: (-700, -20), address: "60 High Street, Millbrook"),
        Landmark(name: "Bean There", layer: "poi", featureClass: "cafe", subclass: "cafe",
                 position: (-285, -250), address: "17 Market Street, Millbrook"),
        Landmark(name: "Harper's Butchers", layer: "poi", featureClass: "butcher", subclass: "butcher",
                 position: (-315, 150), address: "9 Market Street, Millbrook"),
        Landmark(name: "Corner Shop", layer: "poi", featureClass: "shop", subclass: "convenience",
                 position: (-15, -385), address: "Mill Road, Millbrook"),
        Landmark(name: "Millbrook Books", layer: "poi", featureClass: "library", subclass: "books",
                 position: (-500, -20), address: "33 High Street, Millbrook"),
        Landmark(name: "Millbrook Museum", layer: "poi", featureClass: "museum", subclass: "museum",
                 position: (-640, -500), address: "Old Town, Millbrook"),
        Landmark(name: "Millbrook Primary School", layer: "poi", featureClass: "school", subclass: "school",
                 position: (-870, 420), address: "Park Avenue, Millbrook"),
        Landmark(name: "Millbrook Garage", layer: "poi", featureClass: "fuel", subclass: "fuel",
                 position: (700, 20), address: "High Street, Millbrook"),
        Landmark(name: "Eastwood Visitor Centre", layer: "poi", featureClass: "attraction", subclass: "attraction",
                 position: (715, 365), address: "Copse Road, Millbrook"),
    ]

    /// A house along a street: its middle, in metres, and its number.
    struct House: Sendable {
        var east: Double
        var north: Double
        var number: Int
        var street: String
    }

    private enum Houses {
        /// Metres between neighbouring houses along a street.
        static let spacing = 32.0
        /// Metres from a street's middle to a house's.
        static let setback = 16.0
        /// Half a house's frontage and depth, in metres.
        static let halfWidth = 6.0
        static let halfDepth = 5.0
        /// Metres a house keeps from another street and from a landmark,
        /// so none stands in a junction or on a landmark.
        static let clearance = 24.0
        /// The road classes lined with houses.
        static let lined: Set<String> = ["minor", "tertiary", "secondary", "primary"]
        /// Where nobody builds, in metres west, south, east and north: the
        /// park and its pond, the river and its towpath, the wood, and the
        /// bypass and beyond.
        static let open: [(west: Double, south: Double, east: Double, north: Double)] = [
            (-500, 100, -100, 500), (330, -1_200, 480, 1_200), (500, 300, 1_200, 1_200),
            (900, -1_200, 1_200, 1_200),
        ]
    }

    /// Houses both sides of every street of ``Houses/lined``, numbered odd
    /// on the left and even on the right walking from its start, as a
    /// British street is.
    static let houses: [House] = {
        var houses: [House] = []
        let landmarkPoints = landmarks.map { $0.position }
        for street in streets where Houses.lined.contains(street.roadClass) {
            guard let start = street.path.first, let end = street.path.last else { continue }
            let deltaX = end.0 - start.0, deltaY = end.1 - start.1
            let length = (deltaX * deltaX + deltaY * deltaY).squareRoot()
            guard length > 0 else { continue }
            let along = (deltaX / length, deltaY / length), left = (-deltaY / length, deltaX / length)
            var odd = 1, even = 2
            var travelled = Houses.spacing / 2
            while travelled < length {
                for side in [1.0, -1.0] {
                    let east = start.0 + along.0 * travelled + left.0 * side * Houses.setback
                    let north = start.1 + along.1 * travelled + left.1 * side * Houses.setback
                    let number: Int
                    if side > 0 {
                        number = odd
                        odd += 2
                    } else {
                        number = even
                        even += 2
                    }
                    let inOpenGround = Houses.open.contains { area in
                        east >= area.west && east <= area.east && north >= area.south && north <= area.north
                    }
                    let nearStreet = streets.contains { other in
                        other.name != street.name && distance(fromEast: east, north: north, to: other.path) < Houses.clearance
                    }
                    let nearLandmark = landmarkPoints.contains { point in
                        abs(point.0 - east) < Houses.clearance && abs(point.1 - north) < Houses.clearance
                    }
                    if !inOpenGround, !nearStreet, !nearLandmark {
                        houses.append(House(east: east, north: north, number: number, street: street.name))
                    }
                }
                travelled += Houses.spacing
            }
        }
        return houses
    }()

    /// The distance in metres from a point to a polyline.
    private static func distance(fromEast east: Double, north: Double, to path: [(Double, Double)]) -> Double {
        var nearest = Double.infinity
        for (start, end) in zip(path, path.dropFirst()) {
            let deltaX = end.0 - start.0, deltaY = end.1 - start.1
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            let along = lengthSquared > 0
                ? min(max(((east - start.0) * deltaX + (north - start.1) * deltaY) / lengthSquared, 0), 1) : 0
            let offsetX = start.0 + along * deltaX - east, offsetY = start.1 + along * deltaY - north
            nearest = min(nearest, (offsetX * offsetX + offsetY * offsetY).squareRoot())
        }
        return nearest
    }

    /// Every feature of the town.
    static let features: [Feature] = {
        var features: [Feature] = []
        features.append(Feature(layer: "landuse",
                                shape: .polygon(rectangle(west: -1_000, south: -1_000, east: 340, north: 1_000),
                                                holes: []),
                                properties: ["class": "residential"]))
        features.append(Feature(layer: "landuse",
                                shape: .polygon(rectangle(west: 470, south: -1_000, east: 900, north: -300),
                                                holes: []),
                                properties: ["class": "industrial"]))
        features.append(Feature(layer: "landcover",
                                shape: .polygon(rectangle(west: 500, south: 300, east: 900, north: 1_000),
                                                holes: []),
                                properties: ["class": "wood", "subclass": "forest", "name": "Eastwood"]))
        features.append(Feature(layer: "park",
                                shape: .polygon(rectangle(west: -500, south: 100, east: -100, north: 500),
                                                holes: [rectangle(west: -350, south: 250, east: -250, north: 350)]),
                                properties: ["class": "park", "name": "Willow Park"]))
        features.append(Feature(layer: "water",
                                shape: .polygon(rectangle(west: -350, south: 250, east: -250, north: 350),
                                                holes: []),
                                properties: ["class": "lake"]))

        let westBank = riverCentreline.map { ($0.0 - riverHalfWidth, $0.1) }
        let eastBank = riverCentreline.reversed().map { ($0.0 + riverHalfWidth, $0.1) }
        features.append(Feature(layer: "water", shape: .polygon(points(westBank + eastBank), holes: []),
                                properties: ["class": "river"]))
        features.append(Feature(layer: "waterway", shape: .line(points(riverCentreline)),
                                properties: ["class": "river", "name": "Silver River"]))

        for street in streets {
            let line = points(street.path)
            var properties: [String: VectorValue] = ["class": .string(street.roadClass)]
            if street.name == "High Street" { properties["brunnel"] = "bridge" }
            if let subclass = street.subclass { properties["subclass"] = .string(subclass) }
            if street.isOneWay { properties["oneway"] = 1 }
            features.append(Feature(layer: "transportation", shape: .line(line), properties: properties))
            features.append(Feature(layer: "transportation_name", shape: .line(line),
                                    properties: ["class": .string(street.roadClass), "name": .string(street.name)]))
        }
        features.append(Feature(layer: "transportation", shape: .line(points([(-1_200, -930), (1_200, -930)])),
                                properties: ["class": "rail"]))

        let buildingCentres: [(Double, Double)] = [
            (-280, 20), (-170, -60), (-640, 360), (10, 410), (-590, -390), (520, -50),
            (-880, -380), (-860, 30), (-40, -870), (650, -500), (700, -700),
        ]
        for (east, north) in buildingCentres {
            let footprint = rectangle(west: east - buildingHalfSide, south: north - buildingHalfSide,
                                      east: east + buildingHalfSide, north: north + buildingHalfSide)
            features.append(Feature(layer: "building", shape: .polygon(footprint, holes: []), properties: [:],
                                    minimumZoom: LayerZoom.building))
        }
        for house in houses {
            let footprint = rectangle(west: house.east - Houses.halfWidth, south: house.north - Houses.halfDepth,
                                      east: house.east + Houses.halfWidth, north: house.north + Houses.halfDepth)
            features.append(Feature(layer: "building", shape: .polygon(footprint, holes: []), properties: [:],
                                    minimumZoom: LayerZoom.building))
            features.append(Feature(layer: "housenumber",
                                    shape: .point(coordinate(east: house.east, north: house.north)),
                                    properties: ["housenumber": .string(String(house.number))],
                                    minimumZoom: LayerZoom.houseNumber))
        }

        for (priority, landmark) in landmarks.enumerated() where landmark.onMap {
            var properties: [String: VectorValue] = ["class": .string(landmark.featureClass),
                                                     "name": .string(landmark.name)]
            if let subclass = landmark.subclass { properties["subclass"] = .string(subclass) }
            let isPointOfInterest = landmark.layer == "poi"
            features.append(Feature(layer: landmark.layer,
                                    shape: .point(coordinate(east: landmark.position.0, north: landmark.position.1)),
                                    properties: properties,
                                    minimumZoom: isPointOfInterest ? LayerZoom.pointOfInterest : 0,
                                    priority: priority))
        }
        return features
    }()

    /// The places a search of the town finds: its named points, and each
    /// street at its middle.
    static let places: [Place] = {
        var places = landmarks.map { landmark in
            Place(name: landmark.name, kind: landmark.subclass ?? landmark.featureClass,
                  coordinate: coordinate(east: landmark.position.0, north: landmark.position.1),
                  address: landmark.address ?? (landmark.layer == "place" ? nil : SampleTown.name))
        }
        for street in streets {
            let line = points(street.path)
            places.append(Place(name: street.name, kind: street.roadClass,
                                coordinate: WebMercator.midpoint(of: line) ?? origin, address: SampleTown.name))
        }
        return places
    }()
}
