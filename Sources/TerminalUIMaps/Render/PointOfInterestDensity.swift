import Foundation

/// How many points of interest a frame offers the label placer, by zoom.
///
/// OpenMapTiles' `poi` layer does not rank its points by importance across
/// a tile. Its `rank` is an ordinal within a grid of 6 × 6 cells laid over
/// each tile: 1 for the most important point of each cell, 2 for the
/// next, and so on, the order set by the class (a station before a shop)
/// and a name before none (openmaptiles/openmaptiles, `layers/poi`, the
/// `rank` field; OpenFreeMap's planetiler build computes it the same way).
/// So keeping the points of rank up to N keeps at most 36 · N a tile,
/// spread over the tile rather than heaped where the city is busiest.
///
/// A tile drawn deeper than its own zoom is drawn larger: each zoom past it
/// doubles its side and shows a quarter of it, so the cut admits four times
/// the ranks a zoom to keep the points on screen about as many. That is
/// ``ranksAtTileZoom`` at the tile's own zoom and four times as many each
/// zoom deeper, fractional zooms included.
struct PointOfInterestDensity: Sendable, Hashable {
    /// The ranks a tile shows when drawn at its own zoom.
    var ranksAtTileZoom: Double

    /// The deepest rank ever cut at: OpenFreeMap's busiest tiles, central
    /// Paris among them, run to about 400 a grid cell.
    static let unlimited = Int(Int16.max)

    /// The share of a tile one zoom deeper shows: half its side each way.
    static let areaGrowthPerZoom = 4.0

    /// About a hundred points offered to a 200 × 60 frame, a tile and a
    /// half: as many as its labels have room for beside the roads' and
    /// places' names, at any zoom.
    static let standard = PointOfInterestDensity(ranksAtTileZoom: 2)

    init(ranksAtTileZoom: Double) {
        self.ranksAtTileZoom = max(0, ranksAtTileZoom)
    }

    /// The highest rank drawn from a tile of `tileZoom` with the camera at
    /// `zoom`.
    func maximumRank(atZoom zoom: Double, tileZoom: Int) -> Int {
        let deeper = max(0, zoom - Double(tileZoom))
        let ranks = ranksAtTileZoom * Foundation.pow(Self.areaGrowthPerZoom, deeper)
        guard ranks.isFinite, ranks < Double(Self.unlimited) else { return Self.unlimited }
        return Int(ranks.rounded(.down))
    }
}
