import Foundation
import TerminalUI
import TerminalUIMaps

/// Where an OpenStreetMap place's details come from: Nominatim's copy of
/// its tags, or the tags themselves from Overpass (`--details overpass`).
enum PlaceDetailsSource: String, Sendable {
    case nominatim
    case overpass

    /// The details a preset's place card asks: the sample town's own,
    /// Apple's for Apple's, OpenStreetMap's for its tiles and for a pack
    /// downloaded from them.
    func provider(for preset: BackendPreset, userAgent: String) -> (any PlaceDetails)? {
        switch preset {
        case .sample:
            return SamplePlaceDetails()
        case .apple:
            #if canImport(MapKit)
            return MapKitPlaceDetails()
            #else
            return nil
            #endif
        case .openStreetMap, .offline:
            switch self {
            case .nominatim: return NominatimPlaceDetails(userAgent: userAgent)
            case .overpass: return OverpassPlaceDetails(userAgent: userAgent)
            }
        }
    }
}

extension MapsModel {
    /// A point of interest clicked on the map: pinned, its card opened.
    @MainActor
    func select(_ point: MapPointOfInterest) {
        guard panel == nil else { return }
        let place = point.place
        route = nil
        selected = place
        placeDetails.show(place)
    }
}

/// The pinned place's card, in the map's corner: its details as the
/// backend gives them, and what it does not give.
struct PlaceDetailsCard: TerminalView {
    let model: MapsModel

    var body: some TerminalView {
        let loader = model.placeDetails
        let content = MainActor.assumeIsolated {
            PlaceCardContent(state: loader.state, provider: loader.provider, now: Date(), timeZone: .current)
        }
        PlaceCardView(content, hint: "d directions · c clear")
    }
}
