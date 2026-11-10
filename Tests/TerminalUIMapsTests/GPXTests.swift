import Foundation
import Testing
@testable import TerminalUIMaps

@Suite("XML")
struct XMLTests {
    @Test func readsElementsAttributesTextAndReferences() throws {
        let root = try XMLReader.parse("""
        \u{FEFF}<?xml version="1.0"?>
        <!DOCTYPE note [ <!ELEMENT note ANY> ]>
        <!-- a comment -->
        <a:note xmlns:a="urn:x" kind='quoted "inside"' amp="x &amp; y">
          <to>Ann &lt;ann@example.com&gt;</to>
          <body><![CDATA[1 < 2 & <b>bold</b>]]> &#233;&#x00E9;</body>
          <empty/>
        </a:note>
        """)
        #expect(root.name == "note")
        #expect(root.attributes == ["kind": "quoted \"inside\"", "amp": "x & y"], "xmlns is not an attribute")
        #expect(root.childText("to") == "Ann <ann@example.com>")
        #expect(root.childText("body") == "1 < 2 & <b>bold</b> éé")
        #expect(root.child("empty") == XMLNode(name: "empty"))
        #expect(root.children.map(\.name) == ["to", "body", "empty"])
    }

    @Test(arguments: ["<a><b></a></b>", "<a>", "<a x=1/>", "<a>&nope;</a>", "", "text", "<a/><b/>"])
    func refusesWhatIsNotWellFormed(text: String) {
        #expect(throws: XMLReadError.self) { try XMLReader.parse(text) }
    }

    @Test func theWriterEscapesWhatWouldEndItsText() throws {
        var writer = XMLWriter()
        writer.start("root", [("note", "a \"b\" & <c>")])
        writer.element("text", text: "x < y & ]]> z")
        writer.end()
        let root = try XMLReader.parse(writer.output)
        #expect(root.attributes["note"] == "a \"b\" & <c>")
        #expect(root.childText("text") == "x < y & ]]> z")
    }
}

@Suite("xsd:dateTime")
struct XSDDateTimeTests {
    @Test func readsUTCOffsetsAndFractions() throws {
        #expect(XSDDateTime.parse("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(XSDDateTime.parse("2026-11-10T09:00:00Z") == Date(timeIntervalSince1970: 1_794_301_200))
        #expect(XSDDateTime.parse("2026-11-10T10:30:00+01:30") == Date(timeIntervalSince1970: 1_794_301_200))
        #expect(XSDDateTime.parse("2000-02-29T12:00:00.250") == Date(timeIntervalSince1970: 951_825_600.25))
        #expect(XSDDateTime.parse("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
        #expect(XSDDateTime.parse("2026-13-01T00:00:00Z") == nil)
        #expect(XSDDateTime.parse("2026-11-10 09:00:00Z") == nil)
        #expect(XSDDateTime.parse("2026-11-10T09:00:00Zjunk") == nil)
    }

    @Test(arguments: [0.0, 951_825_600.25, 1_794_301_200, -86_400 * 365.0, 4_102_444_799.5])
    func writesWhatItReads(seconds: Double) throws {
        let date = Date(timeIntervalSince1970: seconds)
        let text = XSDDateTime.format(date)
        #expect(text.hasSuffix("Z"))
        let read = try #require(XSDDateTime.parse(text))
        #expect(abs(read.timeIntervalSince1970 - seconds) < 0.001, "\(text)")
    }

    @Test func civilDatesRoundTripAcrossLeapYears() {
        for days in stride(from: -800_000, through: 800_000, by: 997) {
            let civil = XSDDateTime.civilFromDays(days)
            #expect(XSDDateTime.daysFromCivil(year: civil.year, month: civil.month, day: civil.day) == days)
        }
        #expect(XSDDateTime.civilFromDays(0) == (1970, 1, 1))
    }
}

@Suite("GPX")
struct GPXTests {
    @Test func aDocumentRoundTripsThroughItsText() throws {
        let start = Date(timeIntervalSince1970: 1_794_301_200)
        let document = GPXDocument(
            name: "A & B",
            waypoints: [GPXPoint(coordinate: GeoCoordinate(latitude: 51.5, longitude: -0.1), elevation: 12.5,
                                 name: "Café <1>", description: "the \"good\" one")],
            routes: [GPXRoute(name: "Errand", points: [
                GPXPoint(coordinate: GeoCoordinate(latitude: 0.0001234, longitude: -179.9999999), name: "Start"),
                GPXPoint(coordinate: GeoCoordinate(latitude: -45, longitude: 170)),
            ])],
            tracks: [GPXTrack(name: "Drive", segments: [
                [GPXPoint(coordinate: GeoCoordinate(latitude: 1, longitude: 2), time: start, horizontalDilution: 1.2),
                 GPXPoint(coordinate: GeoCoordinate(latitude: 1.0001, longitude: 2), time: start.addingTimeInterval(1.5))],
                [GPXPoint(coordinate: GeoCoordinate(latitude: 1.001, longitude: 2))],
            ])])
        let text = document.xml
        #expect(text.contains("<gpx version=\"1.1\" creator=\"TerminalUIMaps\" xmlns=\"http://www.topografix.com/GPX/1/1\">"))
        #expect(text.contains("<rtept lat=\"0.0001234\" lon=\"-179.9999999\">"), "decimals, not exponents")
        #expect(text.contains("<time>2026-11-10T09:00:01.500Z</time>"))
        let read = try GPXDocument(xml: text)
        #expect(read == document)
    }

    @Test func theSchemasElementOrderIsKeptInAPoint() {
        let point = GPXPoint(coordinate: GeoCoordinate(latitude: 1, longitude: 2), elevation: 3,
                             time: Date(timeIntervalSince1970: 0), name: "n", description: "d", horizontalDilution: 4)
        let text = GPXDocument(waypoints: [point]).xml
        let order = ["<ele>", "<time>", "<name>", "<desc>", "<hdop>"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 5 && order == order.sorted())
    }

    @Test func readsAFileOtherProgramsWrite() throws {
        // As Garmin and Strava write them: a prefixed extension namespace,
        // a metadata block, a track of one segment.
        let document = try GPXDocument(xml: """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="StravaGPX" version="1.1" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
         <metadata><name>Morning Ride</name><time>2026-11-10T07:00:00Z</time></metadata>
         <trk><name>Morning Ride</name><type>cycling</type>
          <trkseg>
           <trkpt lat="38.5000000" lon="-8.2000000"><ele>40.2</ele><time>2026-11-10T07:00:00Z</time>
            <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>120</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
           </trkpt>
           <trkpt lat="38.5001" lon="-8.2"><time>2026-11-10T07:00:05Z</time></trkpt>
          </trkseg>
         </trk>
        </gpx>
        """)
        #expect(document.name == "Morning Ride" && document.creator == "StravaGPX")
        let points = try #require(document.tracks.first?.points)
        #expect(points.count == 2 && points[0].elevation == 40.2)
        #expect(points[1].time == XSDDateTime.parse("2026-11-10T07:00:05Z"))
    }

    @Test func refusesWhatIsNotGPX() {
        #expect(throws: GPXError.notGPX("kml")) { try GPXDocument(xml: "<kml/>") }
        #expect(throws: GPXError.self) { try GPXDocument(xml: "<gpx><wpt lat=\"91\" lon=\"0\"/></gpx>") }
    }

    @Test func aPlanIsSavedAsARouteAndLoadedBack() throws {
        var plan = RoutePlan()
        plan.append("Home", at: GeoCoordinate(latitude: 1, longitude: 2))
        plan.append("Work", at: GeoCoordinate(latitude: 1.01, longitude: 2.02))
        let text = GPXDocument(routes: [GPXRoute(plan, name: "Commute")]).xml
        let loaded = RoutePlan(gpx: try #require(try GPXDocument(xml: text).routes.first))
        #expect(loaded.waypoints.map(\.name) == ["Home", "Work"])
        #expect(loaded.coordinates == plan.coordinates)
    }

    /// The demo track shipped with the app is the one the code makes, so
    /// changing the sample town or its directions changes both together.
    /// `TERMINALUI_UPDATE_GOLDENS=1` writes it anew.
    /// The demo misses a turn and then does what the app tells it: the
    /// reroute leaves along the way the car is going, so the drive goes on
    /// round the block. A scripted U-turn in the track read as the app
    /// turning the driver back.
    @Test func theDemoDriveFollowsItsRerouteRatherThanTurningBack() async throws {
        let points = try await SampleDrive.document().tracks[0].segments[0]
        var previousCourse: Double?
        for (from, to) in zip(points, points.dropFirst())
        where GeoMeasure.distance(from.coordinate, to.coordinate) > Self.minimumStepForCourse {
            let course = GeoMeasure.bearing(from.coordinate, to.coordinate)
            if let previousCourse {
                let turn = abs(CameraMotion.signedTurn(from: previousCourse, to: course))
                #expect(turn < Self.reversal, "the drive turns \(turn)° in a second at \(to.time)")
            }
            previousCourse = course
        }
    }

    /// Below this, in metres a second, a step is too short to have a course.
    private static let minimumStepForCourse = 0.5
    /// A turn this sharp in a second is the car going back the way it came.
    private static let reversal = 150.0

    @Test func theShippedDemoTrackIsTheSampleDrive() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/Maps/Tracks/millbrook-drive.gpx")
        let made = try await SampleDrive.document().xml
        if ProcessInfo.processInfo.environment["TERMINALUI_UPDATE_GOLDENS"] == "1" {
            try Data(made.utf8).write(to: url)
        }
        let shipped = try String(contentsOf: url, encoding: .utf8)
        #expect(shipped == made)
    }
}
