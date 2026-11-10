import Foundation

/// Answers "what is this place like?": its hours, its phone, its website,
/// what it serves — what a place card shows beyond a name and a pin.
///
/// Backends know different things. OpenStreetMap's tags hold opening
/// hours, cuisine and wheelchair access where a mapper added them; Apple's
/// `MKMapItem` has a phone, a website, a category and an address, and no
/// hours. A backend says which it can ever give in ``fields``, so a card
/// tells "this backend does not say" apart from "nobody has said for this
/// place".
public protocol PlaceDetails: Sendable {
    /// Whose details these are, for a card: "OpenStreetMap", "Apple Maps".
    var sourceName: String { get }

    /// What the backend can give for some place. A field outside this set
    /// it never gives.
    var fields: Set<PlaceDetailField> { get }

    /// The details of `place`, or nil where the backend does not know it.
    func details(for place: Place) async throws -> PlaceInformation?
}

/// One kind of thing a ``PlaceDetails`` backend can say about a place.
public enum PlaceDetailField: String, Sendable, Hashable, CaseIterable, Codable {
    case category
    case address
    case openingHours
    case phone
    case website
    case cuisine
    case wheelchair

    /// What a card calls it, in a sentence.
    public var title: String {
        switch self {
        case .category: "category"
        case .address: "address"
        case .openingHours: "opening hours"
        case .phone: "phone"
        case .website: "website"
        case .cuisine: "cuisine"
        case .wheelchair: "wheelchair access"
        }
    }
}

/// What a backend knows of a place. A field is nil, or empty, where the
/// backend has nothing for this place.
public struct PlaceInformation: Sendable, Hashable {
    public var name: String
    /// What it is, in plain words: "restaurant", "pharmacy".
    public var category: String?
    public var address: PostalAddress?
    public var openingHours: OpeningHours?
    public var phone: String?
    public var website: URL?
    /// What it serves, as OpenStreetMap's `cuisine` lists it: "french",
    /// "coffee shop".
    public var cuisine: [String]
    public var wheelchair: WheelchairAccess?
    /// The place's own time zone, which its hours are in, where the
    /// backend gives one.
    public var timeZone: TimeZone?

    public init(name: String, category: String? = nil, address: PostalAddress? = nil,
                openingHours: OpeningHours? = nil, phone: String? = nil, website: URL? = nil,
                cuisine: [String] = [], wheelchair: WheelchairAccess? = nil, timeZone: TimeZone? = nil) {
        self.name = name
        self.category = category
        self.address = address
        self.openingHours = openingHours
        self.phone = phone
        self.website = website
        self.cuisine = cuisine
        self.wheelchair = wheelchair
        self.timeZone = timeZone
    }

    /// Whether the information has `field` for this place.
    public func has(_ field: PlaceDetailField) -> Bool {
        switch field {
        case .category: category != nil
        case .address: address != nil
        case .openingHours: openingHours != nil
        case .phone: phone != nil
        case .website: website != nil
        case .cuisine: !cuisine.isEmpty
        case .wheelchair: wheelchair != nil
        }
    }
}

/// A street address, as much of it as the source has.
public struct PostalAddress: Sendable, Hashable, Codable {
    public var houseNumber: String?
    public var street: String?
    public var postcode: String?
    public var city: String?
    public var country: String?
    /// The whole address on one line as the source formats it, where it
    /// gives one and not its parts (Apple's `MKAddress`).
    public var formatted: String?

    public init(houseNumber: String? = nil, street: String? = nil, postcode: String? = nil, city: String? = nil,
                country: String? = nil, formatted: String? = nil) {
        self.houseNumber = houseNumber
        self.street = street
        self.postcode = postcode
        self.city = city
        self.country = country
        self.formatted = formatted
    }

    /// The address on one line: "9 Rue du Mail, 75002 Paris". Nil where
    /// there is nothing to write.
    public var line: String? {
        if let formatted, !formatted.isEmpty { return formatted }
        let street = [houseNumber, street].compactMap { $0 }.joined(separator: " ")
        let town = [postcode, city].compactMap { $0 }.joined(separator: " ")
        let parts = [street, town].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Whether a wheelchair gets in, as OpenStreetMap's `wheelchair` tag says
/// (wiki.openstreetmap.org/wiki/Key:wheelchair).
public enum WheelchairAccess: String, Sendable, Hashable, Codable {
    /// Every room a visitor uses, without steps.
    case yes
    /// The entrance or some rooms need help.
    case limited
    case no
    /// Built for wheelchair users.
    case designated

    /// A card's words for it.
    public var summary: String {
        switch self {
        case .yes, .designated: "Wheelchair accessible"
        case .limited: "Limited wheelchair access"
        case .no: "Not wheelchair accessible"
        }
    }
}

/// An OpenStreetMap element: a node, a way or a relation, and its number.
public struct OSMElement: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, Codable {
        case node
        case way
        case relation

        /// Nominatim's one-letter prefix for an `osm_ids` entry.
        var letter: String {
            switch self {
            case .node: "N"
            case .way: "W"
            case .relation: "R"
            }
        }
    }

    public var kind: Kind
    public var number: UInt64

    public init(_ kind: Kind, _ number: UInt64) {
        self.kind = kind
        self.number = number
    }

    /// The element a vector tile feature stands for, where the tile was
    /// built by planetiler's OpenMapTiles profile, as OpenFreeMap's are: a
    /// feature's id is the element's number times ten, plus 1 for a node,
    /// 2 for a way and 3 for a relation
    /// (onthegomap/planetiler, `SourceFeature.vectorTileFeatureId`).
    init?(openMapTilesFeatureID id: UInt64) {
        let number = id / Self.idMultiplier
        guard number > 0 else { return nil }
        switch id % Self.idMultiplier {
        case 1: self.init(.node, number)
        case 2: self.init(.way, number)
        case 3: self.init(.relation, number)
        default: return nil
        }
    }

    private static let idMultiplier: UInt64 = 10

    /// `N1528685379`, as Nominatim's `lookup` takes it.
    var nominatimID: String { "\(kind.letter)\(number)" }

    /// `node(1528685379)`, as an Overpass QL query selects it.
    var overpassSelector: String { "\(kind.rawValue)(\(number))" }

    public var description: String { "\(kind.rawValue)/\(number)" }
}

/// What identifies a place to the backend it came from, beyond its name and
/// position.
public enum PlaceIdentifier: Sendable, Hashable, Codable {
    case openStreetMap(OSMElement)
    /// Apple's `MKMapItem.Identifier`, as its raw string.
    case mapKit(String)

    public var osmElement: OSMElement? {
        if case .openStreetMap(let element) = self { return element }
        return nil
    }
}

/// How a tile source's feature ids name the map data's own elements, as
/// its ``TileSourceInfo`` says: what lets a tap on a point of interest ask
/// a ``PlaceDetails`` backend after it.
public enum FeatureIdentifiers: String, Sendable, Hashable, Codable {
    /// planetiler's OpenMapTiles ids, as OpenFreeMap and a pack downloaded
    /// from it have (``OSMElement/init(openMapTilesFeatureID:)``).
    case openMapTiles
    /// Ids that mean nothing outside the tile.
    case opaque
}

extension MapPointOfInterest {
    /// The place a tap on the point picks: its name, kind and position,
    /// and, where the source's ids say, the OpenStreetMap element.
    public var place: Place {
        var identifier: PlaceIdentifier?
        if featureIdentifiers == .openMapTiles, let featureID, let element = OSMElement(openMapTilesFeatureID: featureID) {
            identifier = .openStreetMap(element)
        }
        return Place(name: name, kind: subclass ?? featureClass, coordinate: coordinate, identifier: identifier)
    }
}
