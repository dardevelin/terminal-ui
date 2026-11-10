import Foundation

/// A size on screen in braille dots. A terminal cell holds 2 × 4 dots
/// (U+2800 braille patterns) and is about twice as tall as it is wide, so a
/// dot is about square, and the map is projected in dots.
public struct DotSize: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// The dots of a grid of cells.
    public init(columns: Int, rows: Int) {
        self.init(width: Double(columns * BrailleCell.dotColumns), height: Double(rows * BrailleCell.dotRows))
    }
}

/// A point on screen in braille dots, from the viewport's top-left corner.
public struct DotPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The dot grid of one braille pattern cell (Unicode 3.0, U+2800–U+28FF):
/// two columns of four dots.
public enum BrailleCell {
    public static let dotColumns = 2
    public static let dotRows = 4
}

/// Where the map looks: a centre and a zoom, as in SwiftUI's `MapCamera`.
///
/// The zoom is the slippy-map one, fractional: at zoom z the world is
/// `tileSize · 2^z` dots across. Everything else — what a viewport shows,
/// where a coordinate lands on screen — follows from these and the
/// viewport's size, which the camera is given rather than holds, so the same
/// camera stays valid as the terminal resizes.
public struct MapCamera: Sendable, Equatable {
    /// The coordinate at the middle of the viewport.
    public var center: GeoCoordinate {
        didSet { center = MapCamera.constrained(center) }
    }

    /// The fractional zoom, kept within `zoomRange`.
    public var zoom: Double {
        didSet { zoom = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound) }
    }

    /// Which way is up, in degrees clockwise from north, 0 ..< 360 — SwiftUI
    /// MapKit's `heading`, MapLibre's `bearing`. At 90 the map is turned so
    /// east is at the top. The map rotates about the viewport's middle;
    /// names and markers stay upright.
    public var bearing: Double {
        didSet { bearing = GeoMeasure.normalizedBearing(bearing) }
    }

    /// The zooms the camera may take.
    public var zoomRange: ClosedRange<Double>

    /// How many dots one tile spans at its own zoom. The web convention is
    /// 256 pixels; a dot is coarser than a pixel, so a smaller tile shows
    /// more of the map at the same zoom.
    public var tileSize: Double

    /// The zooms a slippy map offers: 0, the whole world in one tile, to 22,
    /// below which no source has data.
    public static let defaultZoomRange: ClosedRange<Double> = 0...22

    /// The web's tile size in pixels, used here as dots.
    public static let defaultTileSize = 256.0

    /// Half the unit world's width: a point further east or west than this
    /// is nearer the other way round.
    private static let halfWorld = 0.5

    /// A tile's middle, in tiles from its corner.
    private static let tileMiddle = 0.5

    public init(center: GeoCoordinate, zoom: Double,
                zoomRange: ClosedRange<Double> = MapCamera.defaultZoomRange,
                tileSize: Double = MapCamera.defaultTileSize, bearing: Double = 0) {
        self.zoomRange = zoomRange
        self.tileSize = tileSize
        self.center = MapCamera.constrained(center)
        self.zoom = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
        self.bearing = GeoMeasure.normalizedBearing(bearing)
    }

    /// The rotation from the north-up map to the screen, as the cosine and
    /// sine of the bearing. With y down the screen, a north-up offset
    /// (x, y) lands at (x·cos θ + y·sin θ, −x·sin θ + y·cos θ): at θ = 90°
    /// east, (1, 0), goes to the top, (0, −1).
    public struct Rotation: Sendable, Equatable {
        public let cosine: Double
        public let sine: Double

        public init(bearing: Double) {
            let radians = GeoMeasure.radians(bearing)
            cosine = cos(radians)
            sine = sin(radians)
        }

        public var isIdentity: Bool { sine == 0 && cosine == 1 }

        /// A north-up offset turned onto the screen.
        public func toScreen(x: Double, y: Double) -> (x: Double, y: Double) {
            (x * cosine + y * sine, -x * sine + y * cosine)
        }

        /// A screen offset turned back to north-up.
        public func toMap(x: Double, y: Double) -> (x: Double, y: Double) {
            (x * cosine - y * sine, x * sine + y * cosine)
        }
    }

    public var rotation: Rotation { Rotation(bearing: bearing) }

    /// How many dots the whole world spans at the camera's zoom.
    public var dotsPerWorld: Double { MapCamera.dotsPerWorld(atZoom: zoom, tileSize: tileSize) }

    public static func dotsPerWorld(atZoom zoom: Double, tileSize: Double = defaultTileSize) -> Double {
        tileSize * exp2(zoom)
    }

    /// Where `coordinate` lands in a viewport. A point east or west of the
    /// centre by more than half the world is taken the short way round, so
    /// a marker across the antimeridian is drawn beside the centre.
    public func screenPoint(for coordinate: GeoCoordinate, in viewport: DotSize) -> DotPoint {
        let centre = WebMercator.project(center)
        let point = WebMercator.project(coordinate)
        var deltaX = point.x - centre.x
        if deltaX > MapCamera.halfWorld { deltaX -= 1 } else if deltaX < -MapCamera.halfWorld { deltaX += 1 }
        let turned = rotation.toScreen(x: deltaX * dotsPerWorld, y: (point.y - centre.y) * dotsPerWorld)
        return DotPoint(x: viewport.width / 2 + turned.x, y: viewport.height / 2 + turned.y)
    }

    /// The coordinate under a point of a viewport.
    public func coordinate(at point: DotPoint, in viewport: DotSize) -> GeoCoordinate {
        WebMercator.unproject(worldPoint(at: point, in: viewport)).normalized
    }

    /// The unit-world position under a point of a viewport, unwrapped: x may
    /// leave 0 ..< 1 when the view crosses the antimeridian.
    public func worldPoint(at point: DotPoint, in viewport: DotSize) -> WorldPoint {
        let centre = WebMercator.project(center)
        let unturned = rotation.toMap(x: point.x - viewport.width / 2, y: point.y - viewport.height / 2)
        return WorldPoint(x: centre.x + unturned.x / dotsPerWorld, y: centre.y + unturned.y / dotsPerWorld)
    }

    /// The unit-world box holding a viewport's four corners: the view
    /// itself north up, and the square around it turned.
    public func worldBounds(in viewport: DotSize) -> (minimum: WorldPoint, maximum: WorldPoint) {
        let corners = [DotPoint(x: 0, y: 0), DotPoint(x: viewport.width, y: 0),
                       DotPoint(x: 0, y: viewport.height), DotPoint(x: viewport.width, y: viewport.height)]
            .map { worldPoint(at: $0, in: viewport) }
        return (WorldPoint(x: corners.map(\.x).min() ?? 0, y: corners.map(\.y).min() ?? 0),
                WorldPoint(x: corners.map(\.x).max() ?? 0, y: corners.map(\.y).max() ?? 0))
    }

    /// The box a viewport shows, its longitudes wrapped into −180 ..< 180
    /// and its latitudes clamped to Web Mercator's limits.
    public func visibleRect(in viewport: DotSize) -> GeoRect {
        let bounds = worldBounds(in: viewport)
        let northWest = WebMercator.unproject(bounds.minimum).normalized
        let southEast = WebMercator.unproject(bounds.maximum).normalized
        let spansWorld = bounds.maximum.x - bounds.minimum.x >= 1
        return GeoRect(south: southEast.latitude,
                       west: spansWorld ? -Degrees.halfTurn : northWest.longitude,
                       north: northWest.latitude,
                       east: spansWorld ? Degrees.halfTurn : southEast.longitude)
    }

    /// The zoom whose tiles a viewport draws: the camera's, rounded down and
    /// kept within what the source has.
    public func tileZoom(sourceZoomRange: ClosedRange<Int>) -> Int {
        min(max(Int(zoom.rounded(.down)), sourceZoomRange.lowerBound), sourceZoomRange.upperBound)
    }

    /// The tiles a viewport needs, nearest the centre first.
    public func coveringTiles(in viewport: DotSize,
                              sourceZoomRange: ClosedRange<Int> = 0...TileID.maximumZoom) -> [TileID] {
        let tileZoom = tileZoom(sourceZoomRange: sourceZoomRange)
        let bounds = worldBounds(in: viewport)
        let tiles = TileID.covering(minimum: bounds.minimum, maximum: bounds.maximum, zoom: tileZoom)
        let centre = WebMercator.project(center)
        let scale = Double(TileID.tilesPerSide(atZoom: tileZoom))
        let column = centre.x * scale
        let row = centre.y * scale
        return tiles.enumerated().sorted { first, second in
            let firstDistance = MapCamera.distanceSquared(first.element, column: column, row: row, count: scale)
            let secondDistance = MapCamera.distanceSquared(second.element, column: column, row: row, count: scale)
            return firstDistance == secondDistance ? first.offset < second.offset : firstDistance < secondDistance
        }.map(\.element)
    }

    /// The camera moved by a drag of `deltaX`, `deltaY` dots: the map follows
    /// the pointer, so the centre moves the other way.
    public func panned(byDotsX deltaX: Double, y deltaY: Double) -> MapCamera {
        var moved = self
        let centre = WebMercator.project(center)
        let unturned = rotation.toMap(x: deltaX, y: deltaY)
        moved.center = WebMercator.unproject(WorldPoint(x: centre.x - unturned.x / dotsPerWorld,
                                                        y: centre.y - unturned.y / dotsPerWorld))
        return moved
    }

    /// The camera zoomed by `delta` levels, keeping the coordinate under
    /// `anchor` where it is on screen — a wheel zooming about the pointer.
    public func zoomed(by delta: Double, about anchor: DotPoint, in viewport: DotSize) -> MapCamera {
        let anchored = worldPoint(at: anchor, in: viewport)
        var zoomedCamera = self
        zoomedCamera.zoom = zoom + delta
        let scale = zoomedCamera.dotsPerWorld
        let unturned = rotation.toMap(x: anchor.x - viewport.width / 2, y: anchor.y - viewport.height / 2)
        let centre = WorldPoint(x: anchored.x - unturned.x / scale, y: anchored.y - unturned.y / scale)
        zoomedCamera.center = WebMercator.unproject(centre)
        return zoomedCamera
    }

    /// The camera zoomed by `delta` levels about the viewport's centre.
    public func zoomed(by delta: Double) -> MapCamera {
        var zoomedCamera = self
        zoomedCamera.zoom = zoom + delta
        return zoomedCamera
    }

    /// The camera moved to look at `coordinate`, at `zoom` when one is
    /// given — where a fly-to lands — and at its own zoom otherwise; the
    /// zoom kept within ``zoomRange``.
    public func centred(on coordinate: GeoCoordinate, zoom targetZoom: Double? = nil) -> MapCamera {
        var moved = self
        moved.center = coordinate
        if let targetZoom { moved.zoom = targetZoom }
        return moved
    }

    /// The deepest camera that shows all of `rect` in a viewport, centred on it.
    public static func fitting(_ rect: GeoRect, in viewport: DotSize,
                               zoomRange: ClosedRange<Double> = defaultZoomRange,
                               tileSize: Double = defaultTileSize) -> MapCamera {
        let northWest = WebMercator.project(GeoCoordinate(latitude: rect.north, longitude: rect.west))
        let southEast = WebMercator.project(GeoCoordinate(latitude: rect.south, longitude: rect.east))
        let worldWidth = max(southEast.x - northWest.x, .ulpOfOne)
        let worldHeight = max(southEast.y - northWest.y, .ulpOfOne)
        let dots = min(viewport.width / worldWidth, viewport.height / worldHeight)
        let zoom = log2(dots / tileSize)
        let centre = WebMercator.unproject(WorldPoint(x: (northWest.x + southEast.x) / 2,
                                                      y: (northWest.y + southEast.y) / 2))
        return MapCamera(center: centre, zoom: zoom, zoomRange: zoomRange, tileSize: tileSize)
    }

    private static func constrained(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        let latitude = min(max(coordinate.latitude, -WebMercator.maximumLatitude), WebMercator.maximumLatitude)
        let normalized = GeoCoordinate(latitude: latitude.isFinite ? latitude : 0,
                                       longitude: coordinate.longitude.isFinite ? coordinate.longitude : 0)
        return normalized.normalized
    }

    private static func distanceSquared(_ tile: TileID, column: Double, row: Double, count: Double) -> Double {
        var deltaX = Double(tile.x) + MapCamera.tileMiddle - column
        if deltaX > count / 2 { deltaX -= count } else if deltaX < -count / 2 { deltaX += count }
        let deltaY = Double(tile.y) + MapCamera.tileMiddle - row
        return deltaX * deltaX + deltaY * deltaY
    }
}

