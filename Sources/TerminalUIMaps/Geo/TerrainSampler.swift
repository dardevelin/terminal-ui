import Foundation

/// The ground's height anywhere on the world, from the terrain tiles at
/// hand: what the pointer meets on a realistic map with terrain, read for
/// whatever camera a drag or the wheel is trying, not only the one a frame
/// was drawn through.
struct TerrainSampler {
    /// The zooms the terrain source has.
    let zoomRange: ClosedRange<Int>
    /// The tile at hand for an id, or nil.
    let tile: (TileID) -> ElevationTile?

    /// The height above sea level, in metres, of the ground at a point of
    /// the unit world, from the finest tile at hand that holds it; nil where
    /// none does.
    func metres(at world: WorldPoint) -> Double? {
        let x = world.x - world.x.rounded(.down)
        guard world.y >= 0, world.y < 1 else { return nil }
        for zoom in zoomRange.reversed() {
            let count = Double(TileID.tilesPerSide(atZoom: zoom))
            let column = Int(x * count), row = Int(world.y * count)
            guard let tile = tile(TileID(zoom: zoom, x: column, y: row)) else { continue }
            return tile.elevation(atUnitX: x * count - Double(column), y: world.y * count - Double(row))
        }
        return nil
    }
}
