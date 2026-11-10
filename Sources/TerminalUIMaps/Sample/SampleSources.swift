/// The sample town as vector tiles, cut and encoded on request at every
/// zoom: no network, the tests' data and a first launch's.
public struct SampleTileSource: EncodedTileSource {
    /// The zooms it serves: all a camera can take.
    static let zoomRange = 0...22

    /// The units around a tile its features are kept to, as tile servers
    /// keep a buffer so strokes join across tile edges. OpenMapTiles' tools
    /// default to 4 pixels of a 256-pixel tile: 64 units of 4096.
    static let buffer = 64

    private let gzipped: Bool

    public init() {
        self.init(gzipped: false)
    }

    /// - Parameter gzipped: whether to serve each tile gzip-compressed, as
    ///   OpenFreeMap's server does.
    init(gzipped: Bool) {
        self.gzipped = gzipped
    }

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: "Sample", attribution: SampleTown.attribution,
                       zoomRange: SampleTileSource.zoomRange, bounds: SampleTown.bounds)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard let tile = SampleTileSource.tile(for: id) else { return nil }
        let bytes = VectorTileEncoder.encode(tile)
        return gzipped ? GZip.compress(bytes) : bytes
    }

    /// The town's features cut to a tile, or nil for a tile the town does
    /// not reach.
    static func tile(for id: TileID) -> VectorTile? {
        guard id.isValid, zoomRange.contains(id.zoom), id.bounds.intersects(SampleTown.bounds) else { return nil }
        let extent = VectorLayer.defaultExtent
        let clipper = TileClipper(extent: extent, buffer: buffer)
        var layerOrder: [String] = []
        var layers: [String: [VectorFeature]] = [:]
        var pointsOfInterest: [(feature: VectorFeature, priority: Int)] = []
        for (index, feature) in SampleTown.features.enumerated() where id.zoom >= feature.minimumZoom {
            guard let cut = cut(feature, to: id, extent: extent, clipper: clipper, id: UInt64(index + 1)) else {
                continue
            }
            if layers[feature.layer] == nil { layerOrder.append(feature.layer) }
            if feature.layer == pointOfInterestLayer {
                pointsOfInterest.append((cut, feature.priority))
            } else {
                layers[feature.layer, default: []].append(cut)
            }
        }
        guard !layerOrder.isEmpty else { return nil }
        layers[pointOfInterestLayer] = ranked(pointsOfInterest, extent: extent)
        return VectorTile(layers: layerOrder.map { name in
            VectorLayer(name: name, extent: extent, features: layers[name] ?? [])
        })
    }

    private static let pointOfInterestLayer = "poi"

    /// The cells across a tile of OpenMapTiles' `poi` ranking grid.
    static let rankGridSide = 6

    /// Points of interest given OpenMapTiles' `rank`: 1 for the most
    /// important point in each cell of a 6 × 6 grid over the tile, 2 for
    /// the next, and so on (``PointOfInterestDensity``).
    private static func ranked(_ points: [(feature: VectorFeature, priority: Int)], extent: Int) -> [VectorFeature] {
        func gridCell(_ feature: VectorFeature) -> Int {
            guard let point = feature.rings.first?.first else { return 0 }
            func index(_ unit: Int32) -> Int {
                min(max(Int(unit) * rankGridSide / max(extent, 1), 0), rankGridSide - 1)
            }
            return index(point.y) * rankGridSide + index(point.x)
        }
        var taken: [Int: Int] = [:]
        return points.sorted { $0.priority < $1.priority }.map { point in
            let cell = gridCell(point.feature)
            let rank = taken[cell, default: 0] + 1
            taken[cell] = rank
            var feature = point.feature
            feature.properties["rank"] = .int(Int64(rank))
            return feature
        }
    }

    private static func cut(_ feature: SampleTown.Feature, to tile: TileID, extent: Int, clipper: TileClipper,
                            id: UInt64) -> VectorFeature? {
        let project = { (coordinate: GeoCoordinate) -> TileSpacePoint in
            let world = WebMercator.project(coordinate)
            let count = Double(TileID.tilesPerSide(atZoom: tile.zoom))
            return TileSpacePoint(x: (world.x * count - Double(tile.x)) * Double(extent),
                                  y: (world.y * count - Double(tile.y)) * Double(extent))
        }
        switch feature.shape {
        case .point(let coordinate):
            let point = project(coordinate)
            guard (0...Double(extent)).contains(point.x), (0...Double(extent)).contains(point.y) else { return nil }
            return .point(id: id, rounded([point])[0], properties: feature.properties)
        case .line(let coordinates):
            let lines = clipper.clip(line: coordinates.map(project)).map { rounded($0) }.filter { $0.count >= 2 }
            guard !lines.isEmpty else { return nil }
            return .line(id: id, lines, properties: feature.properties)
        case .polygon(let exterior, let holes):
            let outer = rounded(clipper.clip(ring: exterior.map(project)), closed: true)
            guard VectorFeature.doubledSignedArea(of: outer) != 0 else { return nil }
            let interiors = holes.map { rounded(clipper.clip(ring: $0.map(project)), closed: true) }
                .filter { VectorFeature.doubledSignedArea(of: $0) != 0 }
            return VectorFeature(id: id, polygons: [VectorPolygon(exterior: outer, interiors: interiors)],
                                 properties: feature.properties)
        }
    }

    /// Points rounded to the tile grid, a point that rounds onto the one
    /// before it dropped.
    private static func rounded(_ points: [TileSpacePoint], closed: Bool = false) -> [TilePoint] {
        var result: [TilePoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            let tilePoint = TilePoint(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()))
            if result.last != tilePoint { result.append(tilePoint) }
        }
        if closed, result.count > 1, result.first == result.last { result.removeLast() }
        return result
    }
}

/// Search over the sample town's places and streets.
public struct SampleSearch: PlaceSearch {
    private let matcher = PlaceMatcher(places: SampleTown.places)

    public init() {}

    public func search(_ query: String, near region: GeoRect?) async throws -> [Place] {
        matcher.search(query, near: region)
    }
}
