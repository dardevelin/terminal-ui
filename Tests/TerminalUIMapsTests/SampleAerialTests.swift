import Testing
@testable import TerminalUIMaps

// The sample's aerial picture asked every shape of every pixel: zoomed
// out, a tile held the whole town's buildings and took seconds to paint —
// Satellite on the sample town drew nothing for six seconds. The shapes are
// now drawn once onto the tile; what lies on each pixel must be exactly
// what asking each shape would say.

@Suite("The sample's aerial picture")
struct SampleAerialTests {
    private static let samples = 96

    private func expectSameCovers(_ id: TileID) {
        let drawn = SampleAerial.covers(of: id, pixels: Self.samples)
        var differing = 0
        SampleGeometry.forEachSample(of: id, samples: Self.samples) { index, east, north in
            if drawn[index] != SampleAerial.cover(of: id, east: east, north: north) { differing += 1 }
        }
        #expect(differing == 0, "\(differing) of \(drawn.count) samples of \(id) differ")
        #expect(Set(drawn.map { "\($0)" }).count > 2, "the tile \(id) shows the town, not only fields")
    }

    @Test("Zoomed out, a tile holding the whole town is drawn as asking each shape would")
    func wholeTown() {
        expectSameCovers(TileID(containing: SampleTown.origin, zoom: 13))
    }

    @Test("At street level, roads over houses and buildings are drawn as asking each shape would")
    func streetLevel() {
        expectSameCovers(TileID(containing: SampleTown.origin, zoom: 17))
    }

    @Test("Five Ways, its roundabout and its buildings, are drawn as asking each shape would")
    func fiveWays() {
        let fiveWays = SampleTown.coordinate(east: 600, north: 0)
        expectSameCovers(TileID(containing: fiveWays, zoom: 16))
    }
}
