import Testing
import TerminalUI
@testable import TerminalUIMaps

@Suite("Label placement")
struct LabelPlacerTests {
    private let screen = Size(width: 40, height: 10)

    @Test("A place name is centred on its anchor")
    func centred() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Millbrook", anchor: CanvasPoint(x: 20, y: 5), rank: 0)], in: screen)
        #expect(placed == [PlacedLabel(text: "Millbrook", column: 16, row: 5, width: 9, rank: 0)])
    }

    @Test("A marked point's label sits beside the marker, not on it")
    func besideMarker() {
        var placer = LabelPlacer()
        let request = LabelRequest(text: "Café", anchor: CanvasPoint(x: 10, y: 3), rank: 0, style: .besideMarker)
        let placed = placer.place([request], in: screen)
        #expect(placed.map(\.column) == [12])
        #expect(placed.map(\.row) == [3])
    }

    @Test("Of two labels that would overlap, the higher ranked keeps its place and the other moves")
    func collisionMoves() {
        var placer = LabelPlacer()
        let city = LabelRequest(text: "Millbrook", anchor: CanvasPoint(x: 20, y: 5), rank: 0)
        let poi = LabelRequest(text: "Mill", anchor: CanvasPoint(x: 21, y: 5), rank: 5)
        let placed = placer.place([poi, city], in: screen)
        #expect(placed.first == PlacedLabel(text: "Millbrook", column: 16, row: 5, width: 9, rank: 0, request: 1))
        #expect(placed.count == 2)
        #expect(placed.last?.row != 5)
    }

    @Test("A label with nowhere free to go is dropped")
    func dropped() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Millbrook", anchor: CanvasPoint(x: 4.5, y: 0), rank: 0),
             LabelRequest(text: "Mill", anchor: CanvasPoint(x: 4, y: 0), rank: 1)],
            in: Size(width: 9, height: 1))
        #expect(placed.map(\.text) == ["Millbrook"])
    }

    @Test("A label that would hang off the screen is not drawn cut off")
    func offscreen() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Riverside", anchor: CanvasPoint(x: 1, y: 5), rank: 0)], in: screen)
        #expect(placed.allSatisfy { $0.column >= 0 && $0.column + $0.width <= screen.width })
    }

    @Test("Labels keep a column of space between them on a row")
    func gap() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Aaaa", anchor: CanvasPoint(x: 10, y: 0), rank: 0),
             LabelRequest(text: "Bbbb", anchor: CanvasPoint(x: 14, y: 0), rank: 1)],
            in: Size(width: 40, height: 1))
        #expect(placed.map(\.text) == ["Aaaa"])
    }

    @Test("A road's name repeated by neighbouring tiles is drawn once nearby")
    func repeatsNearby() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Mill Lane", anchor: CanvasPoint(x: 10, y: 2), rank: 8),
             LabelRequest(text: "Mill Lane", anchor: CanvasPoint(x: 12, y: 7), rank: 8)],
            in: screen)
        #expect(placed.count == 1)
    }

    @Test("Wide characters count two columns")
    func wide() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "東京", anchor: CanvasPoint(x: 20, y: 5), rank: 0)], in: screen)
        #expect(placed.map(\.width) == [4])
        #expect(placed.map(\.column) == [18])
    }

    @Test("A text is measured once, however many frames place it")
    func measuredOnce() {
        var placer = LabelPlacer()
        let request = LabelRequest(text: "Millbrook", anchor: CanvasPoint(x: 20, y: 5), rank: 0)
        _ = placer.place([request], in: screen)
        _ = placer.place([request], in: screen)
        #expect(placer.measurements == 1)
    }

    @Test("An empty screen places nothing")
    func emptyScreen() {
        var placer = LabelPlacer()
        let placed = placer.place(
            [LabelRequest(text: "Millbrook", anchor: CanvasPoint(x: 0, y: 0), rank: 0)],
            in: Size(width: 0, height: 0))
        #expect(placed.isEmpty)
    }

    @Test("A point of interest's glyph claims its cell, and an earlier name there drops the point")
    func pointOfInterestGlyphCollides() {
        var placer = LabelPlacer()
        let placed = placer.place([
            LabelRequest(text: "High Street", anchor: CanvasPoint(x: 20, y: 5), rank: 0),
            LabelRequest(text: "Café", anchor: CanvasPoint(x: 18, y: 5), rank: 1, style: .pointOfInterest),
        ], in: screen)
        #expect(placed.map(\.text) == ["High Street"])
    }

    @Test("A point of interest whose name finds no room keeps its glyph alone")
    func pointOfInterestGlyphAlone() {
        var placer = LabelPlacer()
        let narrow = Size(width: 6, height: 1)
        let placed = placer.place([
            LabelRequest(text: "The Copper Kettle", anchor: CanvasPoint(x: 2, y: 0), rank: 0, style: .pointOfInterest),
        ], in: narrow)
        #expect(placed.count == 1)
        #expect(placed.first?.showsText == false)
        #expect(placed.first?.column == 2)
        // And the glyph's cell is taken: a second point there is dropped.
        let crowded = placer.place([
            LabelRequest(text: "The Copper Kettle", anchor: CanvasPoint(x: 2, y: 0), rank: 0, style: .pointOfInterest),
            LabelRequest(text: "Bank", anchor: CanvasPoint(x: 2.5, y: 0), rank: 1, style: .pointOfInterest),
        ], in: narrow)
        #expect(crowded.count == 1)
    }

    @Test("A point of interest's name goes beside its glyph")
    func pointOfInterestNameBeside() {
        var placer = LabelPlacer()
        let placed = placer.place([
            LabelRequest(text: "Bank", anchor: CanvasPoint(x: 10, y: 5), rank: 0, style: .pointOfInterest),
        ], in: screen)
        #expect(placed.first?.column == 12)
        #expect(placed.first?.showsText == true)
    }
}
