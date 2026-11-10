import Foundation
import Synchronization
import Testing
@testable import TerminalUIMaps

private func fixture(_ name: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return Array(try Data(contentsOf: url))
}

/// Le Paradis du fruit, a restaurant in the Paris fixture tile.
private let restaurant = Place(name: "Le Paradis du fruit", kind: "restaurant",
                               coordinate: GeoCoordinate(latitude: 48.8538548, longitude: 2.3436878),
                               identifier: .openStreetMap(OSMElement(.node, 1_528_685_379)))

@Suite("Place details")
struct PlaceDetailsTests {
    @Test func aPlanetilerFeatureIDNamesItsElement() {
        #expect(OSMElement(openMapTilesFeatureID: 14_427_318_282) == OSMElement(.way, 1_442_731_828))
        #expect(OSMElement(openMapTilesFeatureID: 15_286_853_791) == OSMElement(.node, 1_528_685_379))
        #expect(OSMElement(openMapTilesFeatureID: 453) == OSMElement(.relation, 45))
        #expect(OSMElement(openMapTilesFeatureID: 1_234_560) == nil, "no kind ends in 0")
        #expect(OSMElement(openMapTilesFeatureID: 2) == nil)
        #expect(OSMElement(.node, 7).nominatimID == "N7")
        #expect(OSMElement(.way, 7).overpassSelector == "way(7)")
    }

    @Test func aClickedPointBecomesAPlaceItsSourceCanLookUp() {
        var point = MapPointOfInterest(name: "Institut Arthur Vernes", category: .health, featureClass: "hospital",
                                       subclass: "clinic", featureID: 14_427_318_282,
                                       coordinate: GeoCoordinate(latitude: 48.8475, longitude: 2.3296), column: 3, row: 4)
        #expect(point.place.identifier == nil, "a source's ids mean nothing until it says what they name")
        point.featureIdentifiers = .openMapTiles
        #expect(point.place.kind == "clinic")
        #expect(point.place.identifier == .openStreetMap(OSMElement(.way, 1_442_731_828)))
    }

    // MARK: - Nominatim

    @Test func nominatimLooksUpAnElementWithItsExtraTagsAndSharesThePacing() async throws {
        let body = try fixture("nominatim-lookup-paris.json")
        let transport = StubTransport { _ in HTTPResponse(statusCode: 200, body: body) }
        let pacing = CountingPacing()
        let details = NominatimPlaceDetails(userAgent: "Tests/1.0", transport: transport, pacing: pacing)
        let information = try #require(try await details.details(for: restaurant))
        #expect(information.name == "Le Paradis du fruit")
        #expect(information.category == "restaurant")
        #expect(information.cuisine == ["brunch", "salad"])
        #expect(information.wheelchair == .limited)
        #expect(information.phone == "+33 9 79 71 80 79")
        #expect(information.website?.host() == "www.leparadisdufruit.fr")
        #expect(information.address?.line == "2 Place Saint-Michel, 75006 Paris")
        #expect(information.openingHours?.schedule?.spans[.friday] == [600..<1_500])
        #expect(pacing.turns == 1)
        let request = try #require(transport.requests.first)
        #expect(request.headers["User-Agent"] == "Tests/1.0")
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(request.url.path() == "/lookup")
        #expect(query.contains(URLQueryItem(name: "osm_ids", value: "N1528685379")))
        #expect(query.contains(URLQueryItem(name: "extratags", value: "1")))
        #expect(query.contains(URLQueryItem(name: "namedetails", value: "1")))
    }

    @Test func nominatimSharesThePacingOfItsSearchByDefault() {
        // The default argument is the one object every search paces with.
        #expect(NominatimSearch.sharedPacing as AnyObject === NominatimSearch.sharedPacing as AnyObject)
    }

    @Test func aPlaceWithNoElementIsNotLookedUp() async throws {
        let transport = StubTransport { _ in .json("[]") }
        let details = NominatimPlaceDetails(userAgent: "Tests/1.0", transport: transport, pacing: CountingPacing())
        let place = Place(name: "Somewhere", kind: "cafe", coordinate: GeoCoordinate(latitude: 0, longitude: 0))
        #expect(try await details.details(for: place) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func nominatimSearchResultsCarryTheirElement() async throws {
        let transport = StubTransport { _ in
            .json(#"[{"lat":"48.85","lon":"2.34","name":"Le Paradis du fruit","type":"restaurant","osm_type":"node","osm_id":1528685379}]"#)
        }
        let search = NominatimSearch(userAgent: "Tests/1.0", transport: transport, pacing: CountingPacing())
        let place = try #require(try await search.search("paradis", near: nil).first)
        #expect(place.identifier == .openStreetMap(OSMElement(.node, 1_528_685_379)))
    }

    // MARK: - Overpass

    @Test func overpassAsksForTheElementsTags() async throws {
        let body = try fixture("overpass-paris.json")
        let transport = StubTransport { _ in HTTPResponse(statusCode: 200, body: body) }
        let details = OverpassPlaceDetails(userAgent: "Tests/1.0", transport: transport, pacing: CountingPacing())
        let information = try #require(try await details.details(for: restaurant))
        #expect(information.name == "Le Paradis du fruit")
        #expect(information.address?.line == "2 Place Saint-Michel, 75006 Paris")
        #expect(information.cuisine == ["brunch", "salad"])
        let request = try #require(transport.requests.first)
        let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        #expect(query == "[out:json][timeout:25];node(1528685379);out tags center;")
        #expect(request.url.host() == "overpass-api.de")
    }

    @Test func overpassBacksOffWhenBusyAndTriesAgain() async throws {
        let body = try fixture("overpass-paris.json")
        let answers = Mutex([429, 504, 200])
        let transport = StubTransport { _ in
            let status = answers.withLock { $0.removeFirst() }
            return HTTPResponse(statusCode: status, body: status == 200 ? body : [])
        }
        let waits = Mutex<[Duration]>([])
        let details = OverpassPlaceDetails(userAgent: "Tests/1.0", transport: transport, pacing: CountingPacing(),
                                           sleep: { duration in waits.withLock { $0.append(duration) } })
        #expect(try await details.details(for: restaurant)?.name == "Le Paradis du fruit")
        #expect(waits.withLock { $0 } == [.seconds(1), .seconds(2)], "each wait twice the last")
        #expect(transport.requests.count == 3)
    }

    @Test func overpassGivesUpOnceTheWaitsRunOut() async throws {
        let transport = StubTransport { _ in HTTPResponse(statusCode: 429, body: []) }
        let details = OverpassPlaceDetails(userAgent: "Tests/1.0", transport: transport, pacing: CountingPacing(),
                                           backoff: [.seconds(1)], sleep: { _ in })
        await #expect(throws: MapServiceError.self) { try await details.details(for: restaurant) }
        #expect(transport.requests.count == 2)
    }

    // MARK: - Sample

    @Test func theSampleTownsBusinessesHaveHours() async throws {
        let details = SamplePlaceDetails()
        let kettle = try #require(SampleTown.places.first { $0.name == "The Copper Kettle" })
        let information = try #require(try await details.details(for: kettle))
        #expect(information.openingHours?.lines.first == "Mo-Fr 07:30-18:00")
        #expect(information.phone?.hasPrefix("01632 960") == true)
        #expect(information.website?.host()?.hasSuffix(".example") == true)
        #expect(information.timeZone == SamplePlaceDetails.timeZone)
        let street = try #require(SampleTown.places.first { $0.name == "High Street" })
        #expect(try await details.details(for: street) == nil)
        for business in SampleTown.places where business.kind != "suburb" && business.kind != "town" {
            if let found = SamplePlaceDetails.details(named: business.name), let hours = found.openingHours {
                #expect(hours.schedule != nil, "\(business.name)'s hours read: \(hours.text)")
            }
        }
    }
}

/// A details backend that answers when the test says, and can fail.
final class GatedDetails: PlaceDetails {
    let sourceName = "Gated"
    let fields: Set<PlaceDetailField>
    private let waiting = Mutex<[String: CheckedContinuation<PlaceInformation?, any Error>]>([:])
    private let asked = Mutex<[String]>([])

    init(fields: Set<PlaceDetailField> = Set(PlaceDetailField.allCases)) {
        self.fields = fields
    }

    var requests: [String] { asked.withLock { $0 } }
    var pending: Set<String> { waiting.withLock { Set($0.keys) } }

    func details(for place: Place) async throws -> PlaceInformation? {
        try await withCheckedThrowingContinuation { continuation in
            asked.withLock { $0.append(place.name) }
            waiting.withLock { $0[place.name] = continuation }
        }
    }

    func answer(_ name: String, with result: Result<PlaceInformation?, any Error>) {
        waiting.withLock { $0.removeValue(forKey: name) }?.resume(with: result)
    }
}

@Suite("The place details loader")
@MainActor
struct PlaceDetailsLoaderTests {
    private let cafe = Place(name: "Café", kind: "cafe", coordinate: GeoCoordinate(latitude: 0, longitude: 0))
    private let bank = Place(name: "Bank", kind: "bank", coordinate: GeoCoordinate(latitude: 0, longitude: 0.001))

    struct Down: Error {}

    @Test func showingAPlaceLoadsItsDetails() async {
        let backend = GatedDetails()
        let loader = PlaceDetailsLoader(provider: backend)
        loader.show(cafe)
        #expect(loader.state == .loading(cafe))
        #expect(await waitUntil { backend.pending.contains("Café") })
        backend.answer("Café", with: .success(PlaceInformation(name: "Café", phone: "01632 960 000")))
        #expect(await waitUntil { loader.state == .loaded(cafe, PlaceInformation(name: "Café", phone: "01632 960 000")) })
    }

    @Test func anotherPlaceSupersedesTheFirstsAnswer() async {
        let backend = GatedDetails()
        let loader = PlaceDetailsLoader(provider: backend)
        loader.show(cafe)
        #expect(await waitUntil { backend.pending.contains("Café") })
        loader.show(bank)
        #expect(await waitUntil { backend.pending.contains("Bank") })
        backend.answer("Café", with: .success(PlaceInformation(name: "Café")))
        backend.answer("Bank", with: .success(nil))
        #expect(await waitUntil { loader.state == .notFound(bank) })
    }

    @Test func aPlaceSeenBeforeIsShownAtOnceAndAFailureIsAskedAgain() async {
        let backend = GatedDetails()
        let loader = PlaceDetailsLoader(provider: backend)
        loader.show(cafe)
        #expect(await waitUntil { backend.pending.contains("Café") })
        backend.answer("Café", with: .success(PlaceInformation(name: "Café")))
        #expect(await waitUntil { if case .loaded = loader.state { true } else { false } })
        loader.show(bank)
        #expect(await waitUntil { backend.pending.contains("Bank") })
        backend.answer("Bank", with: .failure(Down()))
        #expect(await waitUntil { if case .failed = loader.state { true } else { false } })
        loader.show(cafe)
        #expect(loader.state == .loaded(cafe, PlaceInformation(name: "Café")), "kept from the first time")
        #expect(backend.requests == ["Café", "Bank"])
        loader.show(bank)
        #expect(await waitUntil { backend.requests == ["Café", "Bank", "Bank"] }, "a failure is asked again")
        backend.answer("Bank", with: .success(nil))
    }

    @Test func noBackendIsSaidAtOnce() {
        let loader = PlaceDetailsLoader(provider: nil)
        loader.show(cafe)
        #expect(loader.state == .notFound(cafe))
        loader.clear()
        #expect(loader.state == .idle)
    }
}

@Suite("A place card's content")
struct PlaceCardContentTests {
    private let kettle = Place(name: "The Copper Kettle", kind: "cafe",
                               coordinate: GeoCoordinate(latitude: 0, longitude: 0), address: "12 High Street")
    private let hours = OpeningHours("Mo-Fr 07:30-18:00; Sa 08:00-17:00")

    /// A backend that offers only what Apple's does.
    struct AppleLike: PlaceDetails {
        let sourceName = "Apple Maps"
        let fields: Set<PlaceDetailField> = [.category, .address, .phone, .website]
        func details(for place: Place) async throws -> PlaceInformation? { nil }
    }

    private func text(_ content: PlaceCardContent) -> [String] { content.lines.map(\.text) }

    @Test func aLoadedPlaceShowsItsHoursOpenNowAndWhatIsNotKnown() {
        let information = PlaceInformation(name: "The Copper Kettle", category: "cafe", openingHours: hours,
                                           phone: "01632 960 112", cuisine: ["coffee shop"])
        let content = PlaceCardContent(state: .loaded(kettle, information), provider: SamplePlaceDetails(),
                                       now: instant(10, 9), timeZone: utc)
        let lines = text(content)
        #expect(lines.first == "The Copper Kettle")
        #expect(lines.contains("cafe · coffee shop"))
        #expect(lines.contains("Open now · closes 18:00"))
        #expect(lines.contains("Mo-Fr 07:30-18:00"))
        #expect(lines.contains("01632 960 112"))
        #expect(lines.contains("Not known: website, wheelchair access"))
        #expect(content.lines.first { $0.text.hasPrefix("Open now") }?.tone == .positive)
    }

    @Test func closedSaysWhenItOpensAndOnWhatDay() {
        let information = PlaceInformation(name: "The Copper Kettle", openingHours: hours)
        let saturdayEvening = PlaceCardContent(state: .loaded(kettle, information), provider: SamplePlaceDetails(),
                                               now: instant(14, 19), timeZone: utc)
        #expect(text(saturdayEvening).contains("Closed · opens Mon 07:30"))
        let early = PlaceCardContent(state: .loaded(kettle, information), provider: SamplePlaceDetails(),
                                     now: instant(10, 6), timeZone: utc)
        #expect(text(early).contains("Closed · opens 07:30"))
    }

    @Test func whatTheBackendNeverGivesIsNamedOnce() {
        let information = PlaceInformation(name: "The Copper Kettle", category: "cafe", phone: "+44 1632 960112")
        let lines = text(PlaceCardContent(state: .loaded(kettle, information), provider: AppleLike(),
                                          now: instant(10, 9), timeZone: utc))
        #expect(lines.contains("Apple Maps gives no opening hours, cuisine and wheelchair access"))
        #expect(lines.contains("Not known: website"))
        #expect(!lines.contains { $0.hasPrefix("Open") || $0.hasPrefix("Closed") })
    }

    @Test func hoursItCannotReadAreShownAsGiven() {
        let information = PlaceInformation(name: "The Copper Kettle", openingHours: OpeningHours("Jan-Mar 10:00-12:00"))
        let lines = text(PlaceCardContent(state: .loaded(kettle, information), provider: SamplePlaceDetails(),
                                          now: instant(10, 9), timeZone: utc))
        #expect(lines.contains("Hours as given; cannot tell if open now"))
        #expect(lines.contains("Jan-Mar 10:00-12:00"))
    }

    @Test func aBankIsNotAskedItsCuisine() {
        let bank = Place(name: "Millbrook Bank", kind: "bank", coordinate: GeoCoordinate(latitude: 0, longitude: 0))
        let information = PlaceInformation(name: "Millbrook Bank", openingHours: hours, phone: "01632 960 150",
                                           website: URL(string: "https://bank.millbrook.example/"), wheelchair: .yes)
        let lines = text(PlaceCardContent(state: .loaded(bank, information), provider: SamplePlaceDetails(),
                                          now: instant(10, 9), timeZone: utc))
        #expect(!lines.contains { $0.hasPrefix("Not known") })
        #expect(lines.contains("Wheelchair accessible"))
    }

    @Test func loadingFailingAndUnknownSaySo() {
        #expect(text(PlaceCardContent(state: .loading(kettle), provider: SamplePlaceDetails(), now: .now,
                                      timeZone: utc)).contains("Asking Sample…"))
        #expect(text(PlaceCardContent(state: .notFound(kettle), provider: AppleLike(), now: .now, timeZone: utc))
            .contains("Apple Maps has no details of this place"))
        #expect(text(PlaceCardContent(state: .notFound(kettle), provider: nil, now: .now, timeZone: utc))
            .contains("This map has no details of places"))
        let failed = PlaceCardContent(state: .failed(kettle, "offline"), provider: SamplePlaceDetails(), now: .now,
                                      timeZone: utc)
        #expect(failed.lines.last == .init("Sample did not answer: offline", .negative))
        #expect(PlaceCardContent(state: .idle, provider: nil, now: .now, timeZone: utc).lines.isEmpty)
    }

    @Test func thePlacesOwnTimeZoneWinsOverTheViewers() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let information = PlaceInformation(name: "The Copper Kettle", openingHours: OpeningHours("Mo-Fr 09:00-17:00"),
                                           timeZone: paris)
        // 08:30 UTC on a Tuesday: half past nine in Paris.
        let lines = text(PlaceCardContent(state: .loaded(kettle, information), provider: SamplePlaceDetails(),
                                          now: instant(10, 8, 30), timeZone: utc))
        #expect(lines.contains("Open now · closes 17:00"))
    }
}
