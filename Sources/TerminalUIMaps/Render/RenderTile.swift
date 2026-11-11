import TerminalUIIO

/// A tile made ready to draw: its features sorted by role, their points in
/// the tile's unit square, and its names picked out — the per-tile work a
/// frame would otherwise repeat, done once when the tile arrives and off
/// the main actor.
struct RenderTile: Sendable {
    let id: TileID
    let content: Content

    enum Content: Sendable {
        case vector(VectorContent)
        case raster(RasterContent)
        case elevation(ElevationContent)
    }

    /// Prepare a tile of a source for drawing.
    init(id: TileID, tile: MapTile) {
        self.id = id
        switch tile.content {
        case .vector(let vector): content = .vector(VectorContent(vector))
        case .raster(let image): content = .raster(RasterContent(image: image))
        case .elevation(let elevation): content = .elevation(ElevationContent(elevation, id: id))
        }
    }

    /// How many features of each kind the tile draws from: areas and lines,
    /// then labels.
    var featureCount: (shapes: Int, labels: Int) {
        switch content {
        case .vector(let vector):
            (vector.layers.reduce(0) { $0 + $1.features.count }, vector.labels.count + vector.lineLabels.count)
        case .raster, .elevation: (0, 0)
        }
    }
}

/// A tile's areas and lines, a layer per role in draw order, and its names:
/// those at a point, and those along a line.
struct VectorContent: Sendable {
    var layers: [RoleGeometry]
    var labels: [TileLabel]
    var lineLabels: [LineLabel]

    init(_ tile: VectorTile) {
        var byRole: [MapRole: RoleGeometry] = [:]
        var labels: [TileLabel] = []
        var lineLabels: [LineLabel] = []
        for layer in tile.layers {
            let scale = 1 / Double(max(layer.extent, 1))
            for feature in layer.features {
                guard let role = MapRole(layer: layer.name, properties: feature.properties) else { continue }
                switch role.geometry {
                case .area:
                    guard feature.kind == .polygon else { continue }
                    let featuresBefore = byRole[role]?.features.count ?? 0
                    byRole[role, default: RoleGeometry(role: role)].append(feature.rings, scale: scale)
                    // One extrusion a footprint kept: a feature with no
                    // rings adds none.
                    if role == .building, byRole[role]?.features.count ?? 0 > featuresBefore {
                        byRole[role]?.extrusions.append(BuildingExtrusion(feature.properties))
                    }
                case .line:
                    guard feature.kind == .lineString else { continue }
                    byRole[role, default: RoleGeometry(role: role)].append(feature.rings, scale: scale)
                    // OpenMapTiles names rivers on their `waterway` lines,
                    // not in `water_name`.
                    if role == .waterway, let line = LineLabel(feature, role: .waterLabel, scale: scale) {
                        lineLabels.append(line)
                    }
                case .label:
                    if feature.kind == .lineString {
                        if let line = LineLabel(feature, role: role, scale: scale) { lineLabels.append(line) }
                    } else if let label = TileLabel(feature, role: role, layer: layer.name, scale: scale) {
                        labels.append(label)
                    }
                }
            }
        }
        layers = byRole.values.sorted { $0.role.drawOrder < $1.role.drawOrder }
        labels.sort { ($0.role.labelRank ?? 0, $0.importance) < ($1.role.labelRank ?? 0, $1.importance) }
        lineLabels.sort { ($0.role.labelRank ?? 0, $0.importance) < ($1.role.labelRank ?? 0, $1.importance) }
        self.labels = labels
        self.lineLabels = lineLabels
    }
}

/// Every feature of one role in a tile, its points flat in the unit square
/// (0 to 1 across the tile, possibly beyond into the buffer around it).
struct RoleGeometry: Sendable {
    let role: MapRole
    var xs: [Double] = []
    var ys: [Double] = []
    /// One past each ring's last point.
    var ringEnds: [Int] = []
    /// Each ring's bounds, so a frame passes over the rings of a big
    /// feature that lie off screen: a z14 tile's buildings come merged into
    /// a few features of thousands of points.
    var ringBounds: [Bounds] = []
    var features: [FeatureSpan] = []
    /// For the building role, how each feature stands up on a realistic
    /// map, one per feature in order; nil for one that is not raised.
    var extrusions: [BuildingExtrusion?] = []

    struct Bounds: Sendable {
        var minimumX = Double.infinity
        var minimumY = Double.infinity
        var maximumX = -Double.infinity
        var maximumY = -Double.infinity

        mutating func include(x: Double, y: Double) {
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    /// A feature's rings, as indices into `ringEnds`, and its bounds.
    struct FeatureSpan: Sendable {
        var rings: Range<Int>
        var minimumX: Double
        var minimumY: Double
        var maximumX: Double
        var maximumY: Double
    }

    init(role: MapRole) {
        self.role = role
    }

    mutating func append(_ rings: [[TilePoint]], scale: Double) {
        let firstRing = ringEnds.count
        var minimumX = Double.infinity, minimumY = Double.infinity
        var maximumX = -Double.infinity, maximumY = -Double.infinity
        for ring in rings where !ring.isEmpty {
            var bounds = Bounds()
            for point in ring {
                let x = Double(point.x) * scale, y = Double(point.y) * scale
                xs.append(x)
                ys.append(y)
                bounds.include(x: x, y: y)
            }
            minimumX = min(minimumX, bounds.minimumX)
            minimumY = min(minimumY, bounds.minimumY)
            maximumX = max(maximumX, bounds.maximumX)
            maximumY = max(maximumY, bounds.maximumY)
            ringEnds.append(xs.count)
            ringBounds.append(bounds)
        }
        guard ringEnds.count > firstRing else { return }
        features.append(FeatureSpan(rings: firstRing..<ringEnds.count, minimumX: minimumX, minimumY: minimumY,
                                    maximumX: maximumX, maximumY: maximumY))
    }

    /// Where ring `index` starts in `xs` and `ys`.
    func ringStart(_ index: Int) -> Int { index == 0 ? 0 : ringEnds[index - 1] }
}

/// A name a tile carries at the point it names: a place, a point of
/// interest, a lake's name.
struct TileLabel: Sendable {
    var text: String
    var role: MapRole
    /// In the tile's unit square.
    var x: Double
    var y: Double
    /// OpenMapTiles' `rank` where the feature has one, lower first: the
    /// order labels of one role claim space in. For a point of interest it
    /// is the ordinal within its cell of the tile's 6 × 6 grid
    /// (``PointOfInterestDensity``).
    var importance: Int
    /// What a point of interest is; nil for every other name.
    var pointOfInterest: PointOfInterestKind?

    /// The rank a feature without one sorts at: after every ranked one.
    static let unranked = Int(Int16.max)

    /// What the map knows of a point of interest beyond its name.
    struct PointOfInterestKind: Sendable {
        var category: PointOfInterestCategory
        var featureClass: String
        var subclass: String?
        var featureID: UInt64?
    }

    init(text: String, role: MapRole, x: Double, y: Double, importance: Int,
         pointOfInterest: PointOfInterestKind? = nil) {
        self.text = text
        self.role = role
        self.x = x
        self.y = y
        self.importance = importance
        self.pointOfInterest = pointOfInterest
    }

    /// The label of a named point feature, or nil for one without a name
    /// or, among points of interest, of a kind the map leaves out.
    init?(_ feature: VectorFeature, role: MapRole, layer: String, scale: Double) {
        let text = role == .houseNumberLabel
            ? feature.properties[TileLabel.houseNumberKey]?.stringValue : feature.properties["name"]?.stringValue
        guard let name = text, !name.isEmpty, let first = feature.rings.first?.first else { return nil }
        var kind: PointOfInterestKind?
        if role == .poiLabel {
            // The `poi` layer's class says what a point is; an airport's
            // label and a peak are their layers' only kind.
            let featureClass = layer == TileLabel.poiLayer ? feature.properties["class"]?.stringValue ?? "" : layer
            let subclass = feature.properties["subclass"]?.stringValue
            guard let category = PointOfInterestCategory(class: featureClass, subclass: subclass) else { return nil }
            kind = PointOfInterestKind(category: category, featureClass: featureClass, subclass: subclass,
                                       featureID: feature.id)
        }
        self.init(text: name, role: role, x: Double(first.x) * scale, y: Double(first.y) * scale,
                  importance: feature.properties["rank"]?.numberValue.map { Int($0) } ?? TileLabel.unranked,
                  pointOfInterest: kind)
    }

    private static let poiLayer = "poi"
    /// The `housenumber` layer's one field (openmaptiles.org/schema).
    private static let houseNumberKey = "housenumber"
}

/// A name along a line — a street's, a river's — and the line itself, so a
/// frame can offer the name at intervals along the part it shows.
struct LineLabel: Sendable {
    var text: String
    var role: MapRole
    var importance: Int
    /// The line's points in the tile's unit square, and how far along it
    /// each lies, in the same unit.
    var xs: [Double]
    var ys: [Double]
    var distances: [Double]
    var minimumX: Double
    var minimumY: Double
    var maximumX: Double
    var maximumY: Double

    var length: Double { distances.last ?? 0 }

    /// OpenMapTiles `transportation` classes, the most important first.
    private static let roadClassOrder = ["motorway", "trunk", "primary", "secondary", "tertiary", "minor",
                                         "service", "track", "path"]

    static func roadPriority(_ roadClass: String?) -> Int {
        roadClass.flatMap { roadClassOrder.firstIndex(of: $0) } ?? roadClassOrder.count
    }

    /// The longest part of a named line feature, or nil for a feature
    /// without a name or a line.
    init?(_ feature: VectorFeature, role: MapRole, scale: Double) {
        guard let name = feature.properties["name"]?.stringValue, !name.isEmpty,
              let line = feature.rings.max(by: { $0.count < $1.count }), line.count >= 2 else { return nil }
        text = name
        self.role = role
        // `transportation_name` carries no rank: a road's class orders its
        // name, the biggest roads named first.
        importance = role == .roadLabel
            ? LineLabel.roadPriority(feature.properties["class"]?.stringValue)
            : feature.properties["rank"]?.numberValue.map { Int($0) } ?? TileLabel.unranked
        xs = line.map { Double($0.x) * scale }
        ys = line.map { Double($0.y) * scale }
        var distances = [0.0]
        distances.reserveCapacity(line.count)
        for index in 1..<line.count {
            let deltaX = xs[index] - xs[index - 1], deltaY = ys[index] - ys[index - 1]
            distances.append(distances[index - 1] + (deltaX * deltaX + deltaY * deltaY).squareRoot())
        }
        self.distances = distances
        minimumX = xs.min() ?? 0
        maximumX = xs.max() ?? 0
        minimumY = ys.min() ?? 0
        maximumY = ys.max() ?? 0
    }

    /// The point `distance` along the line, in the unit square; the ends
    /// for a distance before or past them.
    func point(at distance: Double) -> (x: Double, y: Double) {
        guard distance > 0 else { return (xs[0], ys[0]) }
        guard distance < length else { return (xs[xs.count - 1], ys[ys.count - 1]) }
        var low = 0, high = distances.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if distances[middle] <= distance { low = middle } else { high = middle }
        }
        let span = distances[high] - distances[low]
        let along = span > 0 ? (distance - distances[low]) / span : 0
        return (xs[low] + (xs[high] - xs[low]) * along, ys[low] + (ys[high] - ys[low]) * along)
    }
}

/// A raster tile's pixels, north up, covering exactly the tile's square.
struct RasterContent: Sendable {
    let image: ImageBuffer
}

/// How far a building's footprint is raised, in metres: from its base to
/// its top — OpenMapTiles' `render_min_height` and `render_height`
/// (openmaptiles.org/schema, `building`).
struct BuildingExtrusion: Sendable, Equatable {
    var base: Double
    var top: Double

    /// What a footprint without a height stands to: the schema's own
    /// fallback for a building with neither a height nor a level count.
    static let defaultHeight = 5.0

    init(base: Double, top: Double) {
        self.base = base
        self.top = top
    }

    /// A feature's extrusion, or nil for an outline whose `building:part`s
    /// stand in its place, which the schema marks `hide_3d`.
    init?(_ properties: [String: VectorValue]) {
        if case .bool(true)? = properties["hide_3d"] { return nil }
        let top = properties["render_height"]?.numberValue ?? Self.defaultHeight
        let base = properties["render_min_height"]?.numberValue ?? 0
        guard top > base else { return nil }
        self.init(base: base, top: top)
    }
}
