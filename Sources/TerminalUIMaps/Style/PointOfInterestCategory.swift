import TerminalUI

/// What kind of place a point of interest is, as the map marks it: one
/// glyph and one theme colour a kind, so a dense street reads by its
/// marks before its names, and a legend (``PointOfInterestLegend``) says
/// what each mark means.
///
/// The kinds gather OpenMapTiles' `poi` classes (openmaptiles.org/schema,
/// layer `poi`), and the subclasses filed under them, into the groups a
/// reader looks for. A class the schema files under a wider one is told
/// apart by its subclass: `library` holds bookshops (`books`) as well as
/// libraries, `art_gallery` public artworks as well as galleries.
///
/// The glyphs are ASCII or shapes `GlyphGeometry` draws, so a recording of
/// the map draws them the same with any font.
public enum PointOfInterestCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case food
    case cafe
    case bar
    case groceries
    case shop
    case lodging
    case transit
    case health
    case money
    case culture
    case sight
    case worship
    case education
    case leisure
    case civic
    case vehicle

    public var id: Self { self }

    /// The mark drawn at the place: one cell wide.
    public var glyph: String {
        switch self {
        case .food: "◆"
        case .cafe: "▼"
        case .bar: "Y"
        case .groceries: "▪"
        case .shop: "•"
        case .lodging: "⌂"
        case .transit: "■"
        case .health: "✚"
        case .money: "$"
        case .culture: "▲"
        case .sight: "★"
        case .worship: "+"
        case .education: "▸"
        case .leisure: "*"
        case .civic: "#"
        case .vehicle: "P"
        }
    }

    /// What the legend calls it.
    public var title: String {
        switch self {
        case .food: "Restaurants and fast food"
        case .cafe: "Cafés and bakeries"
        case .bar: "Bars and pubs"
        case .groceries: "Groceries"
        case .shop: "Shops and services"
        case .lodging: "Hotels"
        case .transit: "Transit"
        case .health: "Health"
        case .money: "Banks and cash"
        case .culture: "Museums, theatres, libraries"
        case .sight: "Sights"
        case .worship: "Places of worship"
        case .education: "Schools and universities"
        case .leisure: "Parks and sport"
        case .civic: "Town hall, police, post"
        case .vehicle: "Parking, fuel, bikes"
        }
    }

    /// The mark's colour under `theme`: a status hue for the kinds a reader
    /// scans for (food in `attention`, health in `error`, transit in
    /// `info`), quieter steps of the foreground for the many shops.
    public func colour(in theme: any Theme) -> Color {
        switch self {
        case .food, .bar: theme.attention
        case .cafe, .sight: theme.warning
        case .groceries, .money, .leisure: theme.success
        case .shop: theme.foregroundMuted
        case .lodging, .transit, .vehicle: theme.info
        case .health: theme.error
        case .culture: theme.secondary
        case .worship, .education, .civic: theme.foregroundSubtle
        }
    }

    /// The kind of an OpenMapTiles `poi` feature from its `class` and
    /// `subclass`, or nil for street furniture and the like that a map of
    /// a dense city is better without (``noiseSubclasses``,
    /// ``noiseClasses``).
    public init?(class featureClass: String, subclass: String?) {
        let subclass = subclass ?? featureClass
        if PointOfInterestCategory.noiseClasses.contains(featureClass)
            || PointOfInterestCategory.noiseSubclasses.contains(subclass) {
            return nil
        }
        if let bySubclass = PointOfInterestCategory.bySubclass[subclass] {
            self = bySubclass
        } else if let byClass = PointOfInterestCategory.byClass[featureClass] {
            self = byClass
        } else {
            self = .shop
        }
    }

    /// Classes dropped whatever their subclass: street furniture, barriers,
    /// and offices, which name a company and not a place to go.
    public static let noiseClasses: Set<String> = [
        "bicycle_parking", "motorcycle_parking", "waste_basket", "bollard", "gate", "lift_gate", "cycle_barrier",
        "recycling", "shelter", "bench", "vending_machine", "drinking_water", "toilets", "picnic_site",
        "sally_port", "basin", "brownfield", "office", "information", "entrance_barrier", "kissing_gate",
        "stile", "block", "turnstile",
    ]

    /// Subclasses dropped from classes otherwise kept.
    public static let noiseSubclasses: Set<String> = [
        "post_box", "parcel_locker", "waste_disposal", "bicycle_repair_station", "atm_kiosk",
    ]

    private static let byClass: [String: PointOfInterestCategory] = [
        "restaurant": .food, "fast_food": .food, "ice_cream": .food,
        "cafe": .cafe, "bakery": .cafe,
        "bar": .bar, "beer": .bar,
        "grocery": .groceries, "alcohol_shop": .groceries, "butcher": .groceries,
        "lodging": .lodging, "campsite": .lodging,
        "bus": .transit, "railway": .transit, "entrance": .transit, "ferry_terminal": .transit,
        "aerialway": .transit, "harbor": .transit, "airport": .transit, "aerodrome_label": .transit,
        "pharmacy": .health, "hospital": .health, "doctors": .health, "dentist": .health, "veterinary": .health,
        "bank": .money, "atm": .money,
        "museum": .culture, "art_gallery": .culture, "theatre": .culture, "cinema": .culture,
        "music": .culture, "library": .culture,
        "attraction": .sight, "monument": .sight, "castle": .sight, "mountain_peak": .sight,
        "place_of_worship": .worship,
        "school": .education, "college": .education,
        "park": .leisure, "garden": .leisure, "playground": .leisure, "pitch": .leisure,
        "sports_centre": .leisure, "swimming": .leisure, "golf": .leisure, "stadium": .leisure,
        "dog_park": .leisure, "water_park": .leisure, "zoo": .leisure,
        "town_hall": .civic, "police": .civic, "fire_station": .civic, "post": .civic,
        "parking": .vehicle, "fuel": .vehicle, "car": .vehicle, "bicycle_rental": .vehicle,
        "bicycle": .vehicle,
    ]

    /// Subclasses the schema files under a class of another kind.
    private static let bySubclass: [String: PointOfInterestCategory] = [
        "books": .shop, "artwork": .sight, "viewpoint": .sight, "convenience": .groceries,
        "supermarket": .groceries, "deli": .groceries, "greengrocer": .groceries, "marketplace": .groceries,
        "department_store": .shop, "chemist": .health, "food_court": .food, "nightclub": .bar,
        "pub": .bar, "coffee": .cafe, "clinic": .health,
    ]
}
