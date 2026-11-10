/// What a feature is on the map, independent of how it is coloured: the
/// renderer maps each role to a `Theme` colour, so the map follows the app's
/// theme in light and dark alike.
///
/// Roles come from the OpenMapTiles schema 3.x (openmaptiles.org/schema),
/// which OpenFreeMap serves and the sample town imitates: a layer name and,
/// within it, the feature's `class`.
enum MapRole: String, Sendable, Hashable, CaseIterable {
    // Areas.
    case landcover
    case landuse
    case park
    case water
    case building

    // Lines.
    case waterway
    case boundary
    case path
    case serviceRoad
    case minorRoad
    case tertiary
    case secondary
    case primary
    case trunk
    case motorway
    case rail

    // Labels.
    case houseNumberLabel
    case waterLabel
    case lakeLabel
    case roadLabel
    case poiLabel
    case suburbLabel
    case villageLabel
    case townLabel
    case cityLabel
    case regionLabel
    case countryLabel

    /// How a role is drawn.
    enum Geometry: Sendable {
        /// A filled area, drawn on the background plane.
        case area
        /// A stroked line.
        case line
        /// Text at a point, or along a line.
        case label
    }

    var geometry: Geometry {
        switch self {
        case .landcover, .landuse, .park, .water, .building: .area
        case .waterway, .boundary, .path, .serviceRoad, .minorRoad, .tertiary, .secondary, .primary, .trunk,
             .motorway, .rail: .line
        case .houseNumberLabel, .waterLabel, .lakeLabel, .roadLabel, .poiLabel, .suburbLabel, .villageLabel,
             .townLabel, .cityLabel, .regionLabel, .countryLabel: .label
        }
    }

    /// The order roles are drawn in, bottom first: ground cover, then water
    /// over it, buildings, lines from the smallest road up so a motorway
    /// crosses over a lane, rail over roads, and labels last of all.
    static let drawSequence: [MapRole] = [
        .landcover, .landuse, .park, .water, .building,
        .waterway, .boundary, .path, .serviceRoad, .minorRoad, .tertiary, .secondary, .primary, .trunk,
        .motorway, .rail,
        .houseNumberLabel, .waterLabel, .lakeLabel, .roadLabel, .poiLabel, .suburbLabel, .villageLabel,
        .townLabel, .cityLabel, .regionLabel, .countryLabel,
    ]

    /// Where the role sits in `drawSequence`: a lower number is drawn first,
    /// under a higher one.
    var drawOrder: Int {
        MapRole.drawSequence.firstIndex(of: self) ?? MapRole.drawSequence.count
    }

    /// The order labels claim space in, most important first: when two
    /// overlap, the one earlier here is kept.
    static let labelPriority: [MapRole] = [
        .countryLabel, .regionLabel, .cityLabel, .townLabel, .villageLabel, .suburbLabel, .poiLabel,
        .waterLabel, .roadLabel, .lakeLabel, .houseNumberLabel,
    ]

    /// Where a label role sits in `labelPriority`; nil for areas and lines.
    var labelRank: Int? {
        MapRole.labelPriority.firstIndex(of: self)
    }

    /// The lowest zoom the role is worth drawing at. A text map has far
    /// fewer pixels than a web map, so the thresholds sit around where
    /// OpenMapTiles first includes each class in its tiles (the `minzoom`
    /// of each layer and class in the schema's layer definitions), nudged
    /// later where a cell-sized line would be clutter: buildings wait for
    /// zoom 15, where a block is several cells; a lake's or a pond's name
    /// for 14, past the zooms where the town around it is a few cells
    /// wide; house numbers for 17, where a house is a cell or more. The
    /// ladder this makes is written out in design/maps.md.
    var minimumZoom: Int {
        switch self {
        case .countryLabel, .water: 0
        case .regionLabel, .boundary: 3
        case .motorway, .cityLabel: 5
        case .trunk, .landcover: 7
        case .primary, .rail, .townLabel: 8
        case .secondary, .waterway, .waterLabel: 9
        case .tertiary, .park, .landuse, .villageLabel: 10
        case .minorRoad, .suburbLabel: 12
        case .roadLabel, .serviceRoad: 13
        case .path, .poiLabel, .lakeLabel: 14
        case .building: 15
        case .houseNumberLabel: 17
        }
    }

    /// Whether the role is drawn at a camera zoom: from its
    /// ``minimumZoom`` on.
    func isVisible(atZoom zoom: Double) -> Bool {
        zoom >= Double(minimumZoom)
    }

    /// How many braille dots wide a line of this role is drawn at a camera
    /// zoom; 1, the finest line braille has, for every line but the bigger
    /// roads, which thicken as the map comes closer so the network's
    /// hierarchy reads at a glance. Zero for areas and labels.
    func lineWidth(atZoom zoom: Double) -> Double {
        guard geometry == .line else { return 0 }
        let steps: [(zoom: Double, dots: Double)]
        switch self {
        case .motorway: steps = [(LineWidths.wideMotorwayZoom, LineWidths.wide),
                                 (LineWidths.boldMotorwayZoom, LineWidths.bold)]
        case .trunk: steps = [(LineWidths.boldTrunkZoom, LineWidths.bold)]
        case .primary: steps = [(LineWidths.boldPrimaryZoom, LineWidths.bold)]
        case .secondary: steps = [(LineWidths.boldSecondaryZoom, LineWidths.bold)]
        default: steps = []
        }
        return steps.first { zoom >= $0.zoom }?.dots ?? LineWidths.hairline
    }

    /// Line widths in dots, and the zooms the bigger roads widen at: the
    /// order OpenMapTiles' own styles widen them in (motorway first,
    /// secondary last), at the zooms where a road of that class is wide
    /// enough on a web map that a one-dot line would undersell it.
    private enum LineWidths {
        static let hairline = 1.0
        static let bold = 2.0
        static let wide = 3.0
        static let wideMotorwayZoom = 15.0
        static let boldMotorwayZoom = 10.0
        static let boldTrunkZoom = 12.0
        static let boldPrimaryZoom = 14.0
        static let boldSecondaryZoom = 16.0
    }

    /// The role of a feature of an OpenMapTiles layer, or nil for one the
    /// map does not draw (ferries, aeroways).
    init?(layer: String, properties: [String: VectorValue]) {
        let featureClass = properties["class"]?.stringValue ?? ""
        switch layer {
        case "water": self = .water
        case "waterway": self = .waterway
        case "park": self = .park
        case "landcover": self = .landcover
        case "landuse": self = .landuse
        case "building": self = .building
        case "boundary": self = .boundary
        case "transportation":
            guard let role = MapRole.road(class: featureClass) else { return nil }
            self = role
        case "transportation_name": self = .roadLabel
        case "water_name": self = MapRole.lakeClasses.contains(featureClass) ? .lakeLabel : .waterLabel
        case "housenumber": self = .houseNumberLabel
        case "poi", "aerodrome_label", "mountain_peak": self = .poiLabel
        case "place":
            guard let role = MapRole.place(class: featureClass) else { return nil }
            self = role
        default: return nil
        }
    }

    /// OpenMapTiles `water_name` classes of standing water, named later
    /// than seas and bays (`lake` is the schema's class for lakes, ponds
    /// and reservoirs alike).
    static let lakeClasses: Set<String> = ["lake", "pond", "reservoir", "basin"]

    /// OpenMapTiles `transportation` classes. A road under construction is
    /// its class with `_construction` after it; a link road (a slip road)
    /// is its class's role, as the schema files `motorway_link` under
    /// `motorway` with a `ramp` flag.
    private static func road(class featureClass: String) -> MapRole? {
        let constructionSuffix = "_construction"
        let base = featureClass.hasSuffix(constructionSuffix)
            ? String(featureClass.dropLast(constructionSuffix.count)) : featureClass
        switch base {
        case "motorway": return .motorway
        case "trunk": return .trunk
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .tertiary
        case "minor", "busway", "bus_guideway", "raceway": return .minorRoad
        case "service", "track": return .serviceRoad
        case "path", "pier": return .path
        case "rail", "transit": return .rail
        default: return nil
        }
    }

    /// OpenMapTiles `place` classes.
    private static func place(class featureClass: String) -> MapRole? {
        switch featureClass {
        case "continent", "country": return .countryLabel
        case "state", "province": return .regionLabel
        case "city": return .cityLabel
        case "town": return .townLabel
        case "village", "hamlet", "isolated_dwelling", "locality", "island": return .villageLabel
        case "suburb", "quarter", "neighbourhood": return .suburbLabel
        default: return nil
        }
    }
}
