#if canImport(MapKit)
import CoreLocation
import Foundation
import MapKit

/// A place's details from Apple's `MKMapItem`: its phone, its website, its
/// point-of-interest category and its address, and its time zone. macOS
/// only.
///
/// Apple's public MapKit gives no opening hours, ratings, cuisine or
/// accessibility, so ``fields`` leaves them out and a card says so. A place
/// Apple's search found carries its `MKMapItem.Identifier` and is fetched
/// by it (`MKMapItemRequest`, macOS 15); any other is looked for by name
/// near where it is, and the nearest result within ``matchRadius`` taken.
public struct MapKitPlaceDetails: PlaceDetails {
    public let sourceName = "Apple Maps"
    public let fields: Set<PlaceDetailField> = [.category, .address, .phone, .website]

    /// How far, in metres, a search result may be from the place it is
    /// taken for: a shop's entrance and its map pin differ by a few tens.
    public static let matchRadius = 150.0

    /// The span a by-name search looks across, in degrees of latitude and
    /// longitude: a neighbourhood.
    static let searchSpan = 0.01

    public init() {}

    public func details(for place: Place) async throws -> PlaceInformation? {
        try await Self.lookUp(place)
    }

    @MainActor
    private static func lookUp(_ place: Place) async throws -> PlaceInformation? {
        if case .mapKit(let raw) = place.identifier, let identifier = MKMapItem.Identifier(rawValue: raw) {
            let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
            return information(item, fallbackName: place.name)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place.name
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
            span: MKCoordinateSpan(latitudeDelta: searchSpan, longitudeDelta: searchSpan))
        let response = try await MKLocalSearch(request: request).start()
        let target = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        let nearest = response.mapItems
            .map { item in (item: item, distance: location(of: item).distance(from: target)) }
            .filter { $0.distance <= matchRadius }
            .min { $0.distance < $1.distance }
        return nearest.map { information($0.item, fallbackName: place.name) }
    }

    @MainActor
    private static func location(of item: MKMapItem) -> CLLocation {
        if #available(macOS 26, *) { return item.location }
        let coordinate = item.placemark.coordinate
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    @MainActor
    static func information(_ item: MKMapItem, fallbackName: String) -> PlaceInformation {
        var address: PostalAddress?
        if #available(macOS 26, *) {
            let line = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                ?? item.address?.shortAddress ?? item.address?.fullAddress
            address = line.map { PostalAddress(formatted: $0) }
        } else if let title = item.placemark.title {
            address = PostalAddress(formatted: title)
        }
        return PlaceInformation(
            name: item.name ?? fallbackName,
            category: item.pointOfInterestCategory.map(categoryName),
            address: address,
            phone: item.phoneNumber,
            website: item.url,
            timeZone: item.timeZone)
    }

    /// `MKPOICategoryCafe` as "cafe", `MKPOICategoryNationalPark` as
    /// "national park".
    static func categoryName(_ category: MKPointOfInterestCategory) -> String {
        let prefix = "MKPOICategory"
        let raw = category.rawValue
        let name = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words.lowercased()
    }
}
#endif
