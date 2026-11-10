import Foundation

/// The details of Millbrook's businesses: hours, phones, websites,
/// cuisines and access, all made up, for a card with no network.
///
/// Phone numbers are in Ofcom's range kept for drama (01632 960000 to
/// 960999), so none rings anyone; websites are under `example`, a name
/// RFC 2606 keeps from ever being registered. Some places leave a field
/// out, as real ones do, so a card shows what is missing. The town is on
/// Null Island, and its hours are in UTC.
public struct SamplePlaceDetails: PlaceDetails {
    /// "Sample".
    public let sourceName = "Sample"
    /// Every field: the sample town makes up all of them.
    public let fields = Set(PlaceDetailField.allCases)

    /// The sample town's details.
    public init() {}

    /// The town's clock.
    static let timeZone = TimeZone(identifier: "UTC") ?? .current

    /// The made-up details of the business named like `place`, or nil for a
    /// place the town has none for.
    public func details(for place: Place) async throws -> PlaceInformation? {
        Self.details(named: place.name)
    }

    static func details(named name: String) -> PlaceInformation? {
        guard let entry = entries[name] else { return nil }
        let landmark = SampleTown.places.first { $0.name == name }
        return PlaceInformation(
            name: name, category: OSMTags.readable(landmark?.kind ?? entry.category),
            address: landmark?.address.map { PostalAddress(formatted: $0) },
            openingHours: entry.hours.map(OpeningHours.init),
            phone: entry.phone,
            website: entry.website.flatMap { URL(string: "https://\($0).millbrook.example/") },
            cuisine: entry.cuisine,
            wheelchair: entry.wheelchair,
            timeZone: timeZone)
    }

    private struct Entry {
        var category: String
        var hours: String?
        var phone: String?
        var website: String?
        var cuisine: [String] = []
        var wheelchair: WheelchairAccess?
    }

    private static let entries: [String: Entry] = [
        "The Copper Kettle": Entry(category: "cafe", hours: "Mo-Fr 07:30-18:00; Sa 08:00-17:00; Su 09:00-14:00",
                                   phone: "01632 960 112", website: "copperkettle", cuisine: ["coffee shop", "cake"],
                                   wheelchair: .yes),
        "Mill Bakery": Entry(category: "bakery", hours: "Mo-Sa 06:30-15:00; Su off", phone: "01632 960 145",
                             wheelchair: .limited),
        "Town Hall": Entry(category: "townhall", hours: "Mo-Fr 09:00-17:00; PH off", phone: "01632 960 100",
                           website: "council", wheelchair: .yes),
        "Public Library": Entry(category: "library", hours: "Tu-Sa 10:00-18:00; Th 10:00-20:00",
                                phone: "01632 960 130", website: "library", wheelchair: .yes),
        "Riverside Pharmacy": Entry(category: "pharmacy", hours: "Mo-Sa 08:30-19:00", phone: "01632 960 177",
                                    wheelchair: .yes),
        "St Anne's Church": Entry(category: "place of worship", website: "stannes", wheelchair: .limited),
        "Millbrook Station": Entry(category: "station", hours: "05:00-24:00", wheelchair: .yes),
        "Millbrook Bank": Entry(category: "bank", hours: "Mo-Fr 09:30-16:30", phone: "01632 960 150",
                                website: "bank", wheelchair: .yes),
        "Post Office": Entry(category: "post office", hours: "Mo-Fr 09:00-17:30; Sa 09:00-12:30",
                             phone: "01632 960 155"),
        "Police Station": Entry(category: "police", hours: "24/7", phone: "01632 960 999", wheelchair: .yes),
        "Station Hotel": Entry(category: "hotel", hours: "24/7", phone: "01632 960 200", website: "stationhotel",
                               wheelchair: .limited),
        "Dr Patel's Surgery": Entry(category: "doctors", hours: "Mo-Fr 08:00-12:30,14:00-18:30",
                                    phone: "01632 960 180", wheelchair: .yes),
        "The Riverside Inn": Entry(category: "pub", hours: "Mo-Th 12:00-23:00; Fr-Sa 12:00-01:00; Su 12:00-22:30",
                                   phone: "01632 960 210", website: "riversideinn", cuisine: ["british"],
                                   wheelchair: .no),
        "Golden Dragon": Entry(category: "restaurant", hours: "Tu-Su 17:00-23:00", phone: "01632 960 220",
                               cuisine: ["chinese"], wheelchair: .yes),
        "Pizza Mill": Entry(category: "restaurant", hours: "Mo-Su 11:30-22:00", phone: "01632 960 230",
                            website: "pizzamill", cuisine: ["pizza", "italian"]),
        "Fryer Tuck": Entry(category: "fast food", hours: "Mo-Sa 11:00-14:00,17:00-22:00", cuisine: ["fish and chips"],
                            wheelchair: .limited),
        "Bean There": Entry(category: "cafe", hours: "Mo-Fr 07:00-16:00", website: "beanthere",
                            cuisine: ["coffee shop"]),
        "Harper's Butchers": Entry(category: "butcher", hours: "Tu-Sa 08:00-17:00", phone: "01632 960 240"),
        "Corner Shop": Entry(category: "convenience", hours: "06:00-23:00", phone: "01632 960 250"),
        "Millbrook Books": Entry(category: "books", hours: "Mo-Sa 09:30-17:30; Su 11:00-16:00",
                                 phone: "01632 960 260", website: "books", wheelchair: .yes),
        "Millbrook Museum": Entry(category: "museum", hours: "We-Su 10:00-16:00; PH off", website: "museum",
                                  wheelchair: .yes),
        "Millbrook Primary School": Entry(category: "school", phone: "01632 960 270"),
        "Millbrook Garage": Entry(category: "fuel", hours: "Mo-Sa 07:00-21:00; Su 08:00-20:00",
                                  phone: "01632 960 280"),
    ]
}
