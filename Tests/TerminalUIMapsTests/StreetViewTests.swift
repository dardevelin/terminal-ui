import Foundation
import Testing
import TerminalUIIO
@testable import TerminalUIMaps

@Suite("Street imagery")
struct StreetImageryTests {
    private static let paris = GeoCoordinate(latitude: 48.857, longitude: 2.3514)

    /// A STAC item as Panoramax serves it, trimmed to what is read.
    private static func item(_ id: String, longitude: Double, latitude: Double, previous: String? = nil,
                             next: String? = nil) -> String {
        var links = [#"{"rel":"license","href":"https://creativecommons.org/licenses/by-sa/4.0/"}"#]
        if let previous { links.append(#"{"rel":"prev","id":"\#(previous)"}"#) }
        if let next { links.append(#"{"rel":"next","id":"\#(next)"}"#) }
        return #"""
        {"id":"\#(id)","collection":"seq-1","geometry":{"type":"Point","coordinates":[\#(longitude),\#(latitude)]},
         "properties":{"datetime":"2025-07-08T07:47:33+00:00","license":"CC-BY-SA-4.0","view:azimuth":216,
                       "geovisio:producer":"Benoît C"},
         "assets":{"thumb":{"href":"https://pano.test/\#(id)/thumb.jpg"},"sd":{"href":"https://pano.test/\#(id)/sd.jpg"}},
         "links":[\#(links.joined(separator: ","))]}
        """#
    }

    @Test func panoramaxFindsTheNearestImageWithItsHeadingDateAndCredit() async throws {
        let transport = StubTransport { request in
            #expect(request.url.path.hasSuffix("/api/search"))
            #expect(request.url.query?.contains("bbox=") == true)
            let near = Self.item("near", longitude: 2.3514, latitude: 48.8570)
            let far = Self.item("far", longitude: 2.3518, latitude: 48.8572)
            return .json(#"{"type":"FeatureCollection","features":[\#(far),\#(near)]}"#)
        }
        let images = try await PanoramaxImagery(transport: transport).images(near: Self.paris, within: 60)
        let nearest = try #require(images.first)
        #expect(images.map(\.id) == ["near", "far"])
        #expect(nearest.heading == 216)
        #expect(nearest.licence == "CC BY-SA 4.0")
        #expect(nearest.attribution == "© Benoît C, Panoramax")
        #expect(nearest.sequence == "seq-1")
        #expect(nearest.photoURL?.absoluteString == "https://pano.test/near/thumb.jpg")
        #expect(nearest.captured != nil)
    }

    @Test func panoramaxStepsAlongItsSequence() async throws {
        let transport = StubTransport { request in
            let id = request.url.lastPathComponent
            #expect(request.url.path.contains("/collections/seq-1/items/"))
            switch id {
            case "b": return .json(Self.item("b", longitude: 2.3514, latitude: 48.8570, previous: "a", next: "c"))
            case "a": return .json(Self.item("a", longitude: 2.3513, latitude: 48.8569, next: "b"))
            default: return .json(Self.item("c", longitude: 2.3515, latitude: 48.8571, previous: "b"))
            }
        }
        let image = StreetImage(id: "b", coordinate: Self.paris, licence: "", attribution: "", sequence: "seq-1")
        let neighbours = try await PanoramaxImagery(transport: transport).neighbours(of: image, along: 0)
        #expect(neighbours.previous?.id == "a")
        #expect(neighbours.next?.id == "c")
    }

    @Test func mapillaryNeedsATokenAndSendsItInAHeader() async throws {
        #expect(throws: StreetImageryError.self) { try MapillaryImagery(environment: [:], userAgent: testUserAgent) }
        let transport = StubTransport { request in
            #expect(request.headers["Authorization"] == "OAuth secret")
            #expect(request.url.query?.contains("secret") == false, "the token never goes in a URL")
            if request.url.path.hasSuffix("image_ids") {
                return .json(#"{"data":[{"id":"1"},{"id":"2"},{"id":"3"}]}"#)
            }
            let id = request.url.lastPathComponent == "images" ? "2" : request.url.lastPathComponent
            let image = #"{"id":"\#(id)","computed_geometry":{"type":"Point","coordinates":[2.3514,48.857]},"#
                + #""captured_at":1751961000000,"compass_angle":90,"thumb_1024_url":"https://m.test/\#(id).jpg","#
                + #""sequence":"s","creator":{"username":"ana"}}"#
            return .json(request.url.lastPathComponent == "images" ? #"{"data":[\#(image)]}"# : image)
        }
        let mapillary = try MapillaryImagery(environment: [MapillaryImagery.tokenVariable: "secret"],
                                             transport: transport, userAgent: testUserAgent)
        let image = try #require(try await mapillary.images(near: Self.paris, within: 60).first)
        #expect(image.attribution == "© ana, Mapillary")
        #expect(image.heading == 90)
        let neighbours = try await mapillary.neighbours(of: image, along: 0)
        #expect(neighbours.previous?.id == "1")
        #expect(neighbours.next?.id == "3")
    }

    @Test func theSampleTownHasPhotosAlongItsStreets() async throws {
        let imagery = SampleStreetImagery()
        let market = SampleTown.coordinate(east: -300, north: 0)
        let nearest = try #require(try await imagery.images(near: market, within: 30).first)
        #expect(nearest.sequence == "Market Street")
        #expect(nearest.heading == 0, "Market Street runs north")
        let photo = try await imagery.photo(of: nearest)
        #expect(photo.width == SampleStreetImagery.photoWidth)
        let neighbours = try await imagery.neighbours(of: nearest, along: 0)
        let next = try #require(neighbours.next)
        #expect(abs(next.coordinate.metres(to: nearest.coordinate) - SampleStreetImagery.spacing) < 1)
    }

    @Test func movingABearingAndBackReturns() {
        let start = GeoCoordinate(latitude: 48.857, longitude: 2.35)
        let moved = start.moved(metres: 100, bearing: 90)
        #expect(abs(start.metres(to: moved) - 100) < 0.01)
        #expect(moved.longitude > start.longitude)
        let back = moved.moved(metres: 100, bearing: 270)
        #expect(abs(back.latitude - start.latitude) < 1e-9 && abs(back.longitude - start.longitude) < 1e-9)
    }
}

@Suite("The street view model")
@MainActor
struct StreetViewModelTests {
    @Test func aLookShowsTheNearestPhotoAndItsNeighbours() async throws {
        let model = StreetViewModel(imagery: SampleStreetImagery())
        await model.look(at: SampleTown.coordinate(east: -300, north: 0)).value
        #expect(model.status == .showing)
        #expect(model.image?.sequence == "Market Street")
        #expect(model.photo != nil)
        #expect(model.neighbours.next != nil && model.neighbours.previous != nil)
        let before = try #require(model.image)
        await model.step(.forward)?.value
        let after = try #require(model.image)
        #expect(after.coordinate.latitude > before.coordinate.latitude, "forward walks north up Market Street")
    }

    @Test func nowhereNearAnyStreetSaysSo() async {
        let model = StreetViewModel(imagery: SampleStreetImagery())
        await model.look(at: GeoCoordinate(latitude: 10, longitude: 10)).value
        #expect(model.status == .nothingNearby)
        #expect(model.image == nil)
        #expect(model.step(.forward) == nil)
    }

    @Test func aLaterLookOvertakesAnEarlierOne() async {
        let model = StreetViewModel(imagery: SampleStreetImagery())
        let first = model.look(at: SampleTown.coordinate(east: -300, north: 0))
        let second = model.look(at: SampleTown.coordinate(east: 0, north: -400))
        await first.value
        await second.value
        #expect(model.image?.sequence != "Market Street")
    }

    @Test func turningRotatesTheWalkingBearing() {
        let model = StreetViewModel(imagery: SampleStreetImagery())
        model.turn(by: -StreetViewModel.turnStep)
        #expect(model.walkingBearing == 315)
    }
}
