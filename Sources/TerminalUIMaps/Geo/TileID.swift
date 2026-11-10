/// A tile of the XYZ ("slippy map") scheme OpenStreetMap and OpenMapTiles
/// use: at zoom z the Web Mercator square is cut into 2^z × 2^z tiles, x
/// counted east from 180° W and y south from the northern limit.
public struct TileID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var zoom: Int
    public var x: Int
    public var y: Int

    /// The deepest zoom a tile index can name and still fit an `Int` row
    /// count with room for arithmetic; real sources stop near 22.
    public static let maximumZoom = 30

    public init(zoom: Int, x: Int, y: Int) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    /// The tile at `zoom` that holds `coordinate`.
    public init(containing coordinate: GeoCoordinate, zoom: Int) {
        let point = WebMercator.project(coordinate)
        let count = TileID.tilesPerSide(atZoom: zoom)
        self.init(zoom: zoom,
                  x: TileID.clampedIndex(point.x * Double(count), count: count),
                  y: TileID.clampedIndex(point.y * Double(count), count: count))
    }

    public var description: String { "\(zoom)/\(x)/\(y)" }

    /// Whether the indices name a tile of the scheme.
    public var isValid: Bool {
        guard (0...TileID.maximumZoom).contains(zoom) else { return false }
        let count = TileID.tilesPerSide(atZoom: zoom)
        return (0..<count).contains(x) && (0..<count).contains(y)
    }

    /// The tile one zoom out that holds this one, or nil at zoom 0.
    public var parent: TileID? {
        guard zoom > 0 else { return nil }
        return TileID(zoom: zoom - 1, x: x >> 1, y: y >> 1)
    }

    /// The tile at `targetZoom`, at most this one's zoom, that holds it.
    public func ancestor(atZoom targetZoom: Int) -> TileID {
        let target = max(0, min(targetZoom, zoom))
        let shift = zoom - target
        return TileID(zoom: target, x: x >> shift, y: y >> shift)
    }

    /// The four tiles one zoom in, north-west, north-east, south-west,
    /// south-east.
    public var children: [TileID] {
        let childZoom = zoom + 1
        let left = x << 1
        let top = y << 1
        return [TileID(zoom: childZoom, x: left, y: top), TileID(zoom: childZoom, x: left + 1, y: top),
                TileID(zoom: childZoom, x: left, y: top + 1), TileID(zoom: childZoom, x: left + 1, y: top + 1)]
    }

    /// The tile's corners on the unit world.
    var worldBounds: (minimum: WorldPoint, maximum: WorldPoint) {
        let count = Double(TileID.tilesPerSide(atZoom: zoom))
        return (WorldPoint(x: Double(x) / count, y: Double(y) / count),
                WorldPoint(x: Double(x + 1) / count, y: Double(y + 1) / count))
    }

    /// The latitude/longitude box the tile covers.
    public var bounds: GeoRect {
        let (minimum, maximum) = worldBounds
        let northWest = WebMercator.unproject(minimum)
        let southEast = WebMercator.unproject(maximum)
        return GeoRect(south: southEast.latitude, west: northWest.longitude,
                       north: northWest.latitude, east: southEast.longitude)
    }

    /// The tiles at `zoom` a box overlaps, row by row from the north-west.
    public static func covering(_ rect: GeoRect, zoom: Int) -> [TileID] {
        let (minimum, maximum) = worldSpan(of: rect)
        return covering(minimum: minimum, maximum: maximum, zoom: zoom)
    }

    /// The number of tiles `covering(_:zoom:)` returns, without listing them.
    public static func count(covering rect: GeoRect, zoom: Int) -> Int {
        let (minimum, maximum) = worldSpan(of: rect)
        guard let span = span(minimum: minimum, maximum: maximum, zoom: zoom) else { return 0 }
        return span.columns.count * span.rows.count
    }

    /// The tiles at `zoom` a span of the unit world overlaps. x beyond the
    /// world wraps around it, so a span across the antimeridian keeps going;
    /// y is clamped to the world, which has no tiles past the poles.
    static func covering(minimum: WorldPoint, maximum: WorldPoint, zoom: Int) -> [TileID] {
        guard let span = span(minimum: minimum, maximum: maximum, zoom: zoom) else { return [] }
        let count = tilesPerSide(atZoom: zoom)
        var tiles: [TileID] = []
        tiles.reserveCapacity(span.columns.count * span.rows.count)
        for row in span.rows {
            for column in span.columns {
                let wrapped = ((column % count) + count) % count
                tiles.append(TileID(zoom: zoom, x: wrapped, y: row))
            }
        }
        return tiles
    }

    private static func worldSpan(of rect: GeoRect) -> (WorldPoint, WorldPoint) {
        (WebMercator.project(GeoCoordinate(latitude: rect.north, longitude: rect.west)),
         WebMercator.project(GeoCoordinate(latitude: rect.south, longitude: rect.east)))
    }

    /// How many worlds east or west an unwrapped x is taken to reach at
    /// most: `Int(_:)` traps on a value beyond `Int`'s range, and no view is
    /// a thousand worlds wide.
    private static let unwrappedWorldLimit = 1_000.0

    /// The columns (unwrapped, at most one world wide) and rows a span
    /// touches. A span ending exactly on a tile edge does not reach into the
    /// tile beyond it.
    private static func span(minimum: WorldPoint, maximum: WorldPoint,
                             zoom: Int) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>)? {
        guard minimum.x.isFinite, minimum.y.isFinite, maximum.x.isFinite, maximum.y.isFinite else { return nil }
        let count = tilesPerSide(atZoom: zoom)
        let scale = Double(count)
        let left = min(max(minimum.x, -unwrappedWorldLimit), unwrappedWorldLimit) * scale
        let right = min(max(maximum.x, -unwrappedWorldLimit), unwrappedWorldLimit) * scale
        let firstColumn = Int(left.rounded(.down))
        var lastColumn = Int(right.rounded(.down))
        if Double(lastColumn) == right, lastColumn > firstColumn { lastColumn -= 1 }
        lastColumn = min(lastColumn, firstColumn + count - 1)
        let firstRow = clampedIndex(minimum.y * scale, count: count)
        var lastRow = clampedIndex(maximum.y * scale, count: count)
        if Double(lastRow) == maximum.y * scale, lastRow > firstRow { lastRow -= 1 }
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return nil }
        return (firstColumn...lastColumn, firstRow...lastRow)
    }

    static func tilesPerSide(atZoom zoom: Int) -> Int {
        1 << max(0, min(zoom, maximumZoom))
    }

    static func clampedIndex(_ position: Double, count: Int) -> Int {
        guard position.isFinite else { return 0 }
        return max(0, min(count - 1, Int(position.rounded(.down))))
    }
}
