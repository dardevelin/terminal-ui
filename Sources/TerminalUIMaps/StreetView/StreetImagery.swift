import Foundation
import TerminalUIIO

/// A photograph taken from a street, as a street-level imagery service
/// lists it.
public struct StreetImage: Sendable, Hashable, Identifiable {
    /// The service's own id for the image.
    public var id: String
    /// Where it was taken.
    public var coordinate: GeoCoordinate
    /// Which way the camera faced, in degrees clockwise from north; nil
    /// where the service does not say (Apple's Look Around).
    public var heading: Double?
    /// When it was taken, where the service says.
    public var captured: Date?
    /// The licence the photo is published under: "CC BY-SA 4.0".
    public var licence: String
    /// The credit the licence requires, as plain text: "© Benoît C, Panoramax".
    public var attribution: String
    /// The sequence it was taken in, a drive or walk along streets, where
    /// the service groups them.
    public var sequence: String?
    /// Where the service serves the photo, sized for a terminal.
    public var photoURL: URL?

    public init(id: String, coordinate: GeoCoordinate, heading: Double? = nil, captured: Date? = nil,
                licence: String, attribution: String, sequence: String? = nil, photoURL: URL? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.heading = heading
        self.captured = captured
        self.licence = licence
        self.attribution = attribution
        self.sequence = sequence
        self.photoURL = photoURL
    }
}

/// The images either side of one along its street.
public struct StreetImageNeighbours: Sendable, Equatable {
    public var previous: StreetImage?
    public var next: StreetImage?

    public init(previous: StreetImage? = nil, next: StreetImage? = nil) {
        self.previous = previous
        self.next = next
    }

    public static let none = StreetImageNeighbours()
}

/// Answers "what does this street look like from the ground?": the
/// street-level photographs near a place, the ones before and after each
/// along its street, and the photo itself.
///
/// ```swift
/// let imagery: any StreetImagery = PanoramaxImagery()
/// if let nearest = try await imagery.images(near: place, within: 50).first {
///     let photo = try await imagery.photo(of: nearest)
/// }
/// ```
public protocol StreetImagery: Sendable {
    /// The service's name, for a picker and a credit.
    var name: String { get }

    /// The images within `metres` of a coordinate, nearest first.
    func images(near coordinate: GeoCoordinate, within metres: Double) async throws -> [StreetImage]

    /// The images before and after `image` along its street. A service
    /// whose images have no sequence steps `bearing` degrees from north
    /// and back — Look Around's scenes — and one with sequences ignores it.
    func neighbours(of image: StreetImage, along bearing: Double) async throws -> StreetImageNeighbours

    /// The photo, decoded in pure Swift.
    func photo(of image: StreetImage) async throws -> ImageBuffer
}

/// Why street imagery could not be had.
public enum StreetImageryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The service needs a key the app was not given.
    case missingToken(String)
    /// The image has no photo the service would serve.
    case noPhoto
    /// Nothing was found near the place.
    case nothingNearby

    public var description: String {
        switch self {
        case .missingToken(let what): "no \(what): set it in the environment"
        case .noPhoto: "the service has no photo for this image"
        case .nothingNearby: "no street imagery near here"
        }
    }
}

extension GeoCoordinate {
    /// The coordinate `metres` away on a compass `bearing`, over the
    /// projected map: exact enough for steps along a street.
    public func moved(metres: Double, bearing: Double) -> GeoCoordinate {
        let radians = bearing * .pi / Degrees.halfTurn
        let world = WebMercator.project(self)
        let units = metres / WebMercator.metresPerWorldUnit(atLatitude: latitude)
        return WebMercator.unproject(WorldPoint(x: world.x + sin(radians) * units, y: world.y - cos(radians) * units))
    }

    /// The distance to another coordinate over the projected map, in
    /// metres at this one's latitude.
    public func metres(to other: GeoCoordinate) -> Double {
        let start = WebMercator.project(self), end = WebMercator.project(other)
        let deltaX = end.x - start.x, deltaY = end.y - start.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot() * WebMercator.metresPerWorldUnit(atLatitude: latitude)
    }

    /// A box `metres` either way of the coordinate.
    func box(metres: Double) -> GeoRect {
        let northEast = moved(metres: metres, bearing: CompassBearing.north).moved(metres: metres,
                                                                                  bearing: CompassBearing.east)
        let southWest = moved(metres: metres, bearing: CompassBearing.south).moved(metres: metres,
                                                                                  bearing: CompassBearing.west)
        return GeoRect(south: southWest.latitude, west: southWest.longitude, north: northEast.latitude,
                       east: northEast.longitude)
    }
}

/// The compass's four points, in degrees clockwise from north.
enum CompassBearing {
    static let north = 0.0
    static let east = 90.0
    static let south = 180.0
    static let west = 270.0
    static let fullTurn = 360.0

    /// A bearing brought into 0 ..< 360.
    static func normalised(_ bearing: Double) -> Double {
        let wrapped = bearing.truncatingRemainder(dividingBy: fullTurn)
        return wrapped < 0 ? wrapped + fullTurn : wrapped
    }
}

extension HTTPTransport {
    /// A photo's bytes, decoded: JPEG or PNG by its signature.
    func photo(at url: URL, userAgent: String) async throws -> ImageBuffer {
        let bytes = try await body(of: HTTPRequest(url: url, headers: [MapUserAgent.headerField: userAgent]))
        return try RasterEncoding.image(bytes)
    }
}
