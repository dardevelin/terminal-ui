import Foundation
import TerminalUIIO
import TerminalUIRaster

/// The ground Millbrook stands on: a hill to the north-west, downs to the
/// south-east, and the Silver River's valley between — invented, as the
/// town is, so the sample has relief to shade and contour with no network.
enum SampleGround {
    /// A rise of the ground: its top in metres east and north of the
    /// town's origin, its height above the plain, and how far it spreads.
    private struct Hill {
        var east: Double
        var north: Double
        var height: Double
        var spread: Double
    }

    private static let hills = [
        Hill(east: -750, north: 650, height: 160, spread: 380),   // Beacon Hill
        Hill(east: 850, north: -700, height: 90, spread: 420),    // the downs
        Hill(east: -300, north: -850, height: 40, spread: 500),
    ]

    /// The plain's height, the valley's depth and half-width, and how much
    /// the land rises toward the north, in metres and metres per metre.
    private enum Plain {
        static let height = 30.0
        static let valleyDepth = 18.0
        static let valleyWidth = 140.0
        static let northwardRise = 0.01
    }

    /// The river's centreline in metres, from the town's own waterway.
    private static let river: [(east: Double, north: Double)] = {
        guard let waterway = SampleTown.features.first(where: { $0.layer == "waterway" }),
              case .line(let coordinates) = waterway.shape else { return [] }
        return coordinates.map { SampleTown.metres(of: $0) }
    }()

    /// The ground's height at a point, in metres above sea level.
    static func height(east: Double, north: Double) -> Double {
        var height = Plain.height + north * Plain.northwardRise
        for hill in hills {
            let deltaEast = east - hill.east, deltaNorth = north - hill.north
            height += hill.height * exp(-(deltaEast * deltaEast + deltaNorth * deltaNorth) / (2 * hill.spread * hill.spread))
        }
        let distance = distanceToRiver(east: east, north: north)
        height -= Plain.valleyDepth * exp(-(distance * distance) / (Plain.valleyWidth * Plain.valleyWidth))
        return height
    }

    static func distanceToRiver(east: Double, north: Double) -> Double {
        zip(river, river.dropFirst()).reduce(Double.infinity) { nearest, segment in
            min(nearest, SampleGeometry.distance(east, north, segment.0, segment.1))
        }
    }

    /// Heights over a tile, `samples` a side, at each sample's middle.
    static func tile(_ id: TileID, samples: Int) -> ElevationTile {
        var metres = [Float](repeating: 0, count: samples * samples)
        SampleGeometry.forEachSample(of: id, samples: samples) { index, east, north in
            metres[index] = Float(height(east: east, north: north))
        }
        return ElevationTile(checkedWidth: samples, height: samples, metres: metres)
    }
}

/// The sample ground as Terrarium PNG tiles, encoded and decoded as AWS's
/// are, at every zoom: no network, and the whole path a real terrain tile
/// takes.
public struct SampleTerrainSource: EncodedTileSource {
    /// Terrarium tiles are 256 samples a side.
    public static let samplesPerTile = 256

    public init() {}

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: "Sample terrain", attribution: SampleTown.attribution,
                       zoomRange: SampleTileSource.zoomRange, bounds: SampleTown.bounds)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard id.isValid, SampleTileSource.zoomRange.contains(id.zoom), id.bounds.intersects(SampleTown.bounds),
              let image = Terrarium.image(of: SampleGround.tile(id, samples: Self.samplesPerTile)) else { return nil }
        return PNGWriter.encode(PixelCanvas(width: image.width, height: image.height, bytes: image.rgba),
                                colourType: .rgb)
    }

    public func tile(_ id: TileID) async throws -> MapTile? {
        guard let bytes = try await tileData(id) else { return nil }
        return try RasterEncoding.terrarium.decode(bytes)
    }
}

/// The sample town from the air, painted from its own features: fields
/// around it, roofs and gardens, the park's trees, the river and the
/// roads, lit by the sample ground's slopes. PNG tiles, so a pack can hold
/// them and the decoder reads them, at every zoom.
public struct SampleImagerySource: EncodedTileSource {
    public static let pixelsPerTile = 256

    public init() {}

    public func info() async throws -> TileSourceInfo {
        TileSourceInfo(name: "Sample imagery", attribution: SampleTown.attribution,
                       zoomRange: SampleTileSource.zoomRange, bounds: SampleTown.bounds)
    }

    public func tileData(_ id: TileID) async throws -> [UInt8]? {
        guard id.isValid, SampleTileSource.zoomRange.contains(id.zoom),
              id.bounds.intersects(SampleTown.bounds) else { return nil }
        guard let image = SampleAerial.paint(id, pixels: Self.pixelsPerTile) else { return nil }
        return PNGWriter.encode(PixelCanvas(width: image.width, height: image.height, bytes: image.rgba),
                                colourType: .rgb)
    }

    public func tile(_ id: TileID) async throws -> MapTile? {
        guard let bytes = try await tileData(id) else { return nil }
        return try RasterEncoding.picture.decode(bytes)
    }
}

/// Paints the aerial view. The colours are a photograph's, not the
/// theme's: what grass, roofs and water look like from above.
enum SampleAerial {
    private struct Colour {
        var red: Double
        var green: Double
        var blue: Double

        func scaled(_ factor: Double) -> Colour { Colour(red: red * factor, green: green * factor, blue: blue * factor) }
    }

    /// What each kind of ground looks like from above, in sRGB.
    private enum Palette {
        static let fields = [Colour(red: 122, green: 140, blue: 72), Colour(red: 160, green: 152, blue: 92),
                             Colour(red: 96, green: 124, blue: 64), Colour(red: 140, green: 120, blue: 84)]
        static let garden = Colour(red: 88, green: 112, blue: 66)
        static let roof = Colour(red: 150, green: 92, blue: 76)
        static let paving = Colour(red: 128, green: 126, blue: 120)
        static let industrial = Colour(red: 146, green: 146, blue: 140)
        static let trees = Colour(red: 46, green: 78, blue: 44)
        static let grass = Colour(red: 84, green: 128, blue: 62)
        static let water = Colour(red: 38, green: 70, blue: 82)
        static let asphalt = Colour(red: 70, green: 72, blue: 74)
        static let motorway = Colour(red: 84, green: 84, blue: 86)
        static let rail = Colour(red: 96, green: 84, blue: 72)
    }

    /// Sizes on the ground, in metres: a field, a house's plot, a roof,
    /// the texture's grain, and each class of road's half-width.
    private enum Ground {
        static let field = 160.0
        static let plot = 24.0
        static let roofShare = 0.55
        static let grain = 3.0
        static let jitter = 0.12
        static let roadHalfWidths: [String: Double] = [
            "motorway": 14, "primary": 9, "secondary": 8, "tertiary": 7, "minor": 5, "service": 4, "path": 1.5,
            "rail": 3,
        ]
    }

    /// How the slopes light the picture: its brightness moves this far
    /// either way with the hillshade's distance from flat.
    private static let reliefLight = 0.9

    private struct Shapes {
        var areas: [(layer: String, featureClass: String, ring: [(east: Double, north: Double)])] = []
        var lines: [(featureClass: String, halfWidth: Double, line: [(east: Double, north: Double)])] = []

        /// Those that reach a tile: a tile at a street zoom asks a few
        /// shapes of each pixel rather than the whole town.
        func near(_ id: TileID) -> Shapes {
            let bounds = id.bounds
            let southWest = SampleTown.metres(of: GeoCoordinate(latitude: bounds.south, longitude: bounds.west))
            let northEast = SampleTown.metres(of: GeoCoordinate(latitude: bounds.north, longitude: bounds.east))
            func reaches(_ points: [(east: Double, north: Double)], margin: Double) -> Bool {
                guard let first = points.first else { return false }
                let box = points.reduce((first.east, first.north, first.east, first.north)) { box, point in
                    (min(box.0, point.east), min(box.1, point.north), max(box.2, point.east), max(box.3, point.north))
                }
                return box.0 - margin <= northEast.east && box.2 + margin >= southWest.east
                    && box.1 - margin <= northEast.north && box.3 + margin >= southWest.north
            }
            return Shapes(areas: areas.filter { reaches($0.ring, margin: 0) },
                          lines: lines.filter { reaches($0.line, margin: $0.halfWidth) })
        }
    }

    /// The town's features in metres, areas in draw order, then lines.
    private static let shapes: Shapes = {
        var shapes = Shapes()
        let areaOrder = ["landuse", "landcover", "park", "water", "building"]
        for layer in areaOrder {
            for feature in SampleTown.features where feature.layer == layer {
                guard case .polygon(let exterior, _) = feature.shape else { continue }
                let featureClass = feature.properties["class"]?.stringValue ?? layer
                shapes.areas.append((layer, featureClass, exterior.map(SampleTown.metres)))
            }
        }
        for feature in SampleTown.features where feature.layer == "transportation" {
            guard case .line(let coordinates) = feature.shape,
                  let featureClass = feature.properties["class"]?.stringValue,
                  let halfWidth = Ground.roadHalfWidths[featureClass] else { continue }
            shapes.lines.append((featureClass, halfWidth, coordinates.map(SampleTown.metres)))
        }
        return shapes
    }()

    static func paint(_ id: TileID, pixels: Int) -> ImageBuffer? {
        let channels = 4
        var rgba = [UInt8](repeating: UInt8.max, count: pixels * pixels * channels)
        let lighting = Hillshade.standard
        let pixelMetres = WebMercator.metresPerWorldUnit(atLatitude: SampleTown.origin.latitude)
            / Double(TileID.tilesPerSide(atZoom: id.zoom)) / Double(pixels)
        let shades = lighting.shades(of: SampleGround.tile(id, samples: pixels), cellSize: pixelMetres)
        let flat = lighting.flat
        let covers = covers(of: id, pixels: pixels)
        SampleGeometry.forEachSample(of: id, samples: pixels) { index, east, north in
            var colour = colour(of: covers[index], east: east, north: north)
            let grain = SampleGeometry.hash(Int((east / Ground.grain).rounded(.down)),
                                            Int((north / Ground.grain).rounded(.down)))
            colour = colour.scaled(1 + (grain - 0.5) * Ground.jitter)
            colour = colour.scaled(1 + (Double(shades[index]) - flat) * reliefLight)
            let base = index * channels
            rgba[base] = UInt8(min(max(colour.red, 0), Double(UInt8.max)))
            rgba[base + 1] = UInt8(min(max(colour.green, 0), Double(UInt8.max)))
            rgba[base + 2] = UInt8(min(max(colour.blue, 0), Double(UInt8.max)))
        }
        return try? ImageBuffer(rgba: rgba, width: pixels, height: pixels)
    }

    /// What lies on the ground, before it is coloured.
    enum Cover: Equatable {
        case fields, water, roof, park, trees, industrial, houses, motorway, rail, asphalt
    }

    /// The cover of every pixel of a tile, row by row from the north-west:
    /// each shape drawn once onto the tile — an area filled a row at a
    /// time, a road painted over only the pixels its segment's box reaches —
    /// in the order `cover(east:north:shapes:)` reads them, later over
    /// earlier and roads over areas. Asking every shape of every pixel
    /// instead cost a tile the whole town's buildings 65 536 times over:
    /// seconds a tile when zoomed out.
    static func covers(of id: TileID, pixels: Int) -> [Cover] {
        let grid = SampleGeometry.Grid(id, samples: pixels)
        let near = shapes.near(id)
        var covers = [Cover](repeating: .fields, count: pixels * pixels)
        for area in near.areas {
            let cover = cover(ofArea: area)
            grid.fill(area.ring) { covers[$0] = cover }
        }
        for line in near.lines {
            let cover = cover(ofLine: line.featureClass)
            for (start, end) in zip(line.line, line.line.dropFirst()) {
                grid.paint(from: start, to: end, halfWidth: line.halfWidth) { covers[$0] = cover }
            }
        }
        return covers
    }

    /// The cover at one point, asking every shape near the tile: the
    /// definition `covers(of:pixels:)` draws faster, and its tests' measure.
    static func cover(of id: TileID, east: Double, north: Double) -> Cover {
        let near = shapes.near(id)
        for line in near.lines.reversed() {
            for (start, end) in zip(line.line, line.line.dropFirst())
            where SampleGeometry.distance(east, north, start, end) <= line.halfWidth {
                return cover(ofLine: line.featureClass)
            }
        }
        for area in near.areas.reversed() where SampleGeometry.contains(area.ring, east: east, north: north) {
            return cover(ofArea: area)
        }
        return .fields
    }

    private static func cover(ofLine featureClass: String) -> Cover {
        switch featureClass {
        case "motorway": .motorway
        case "rail": .rail
        default: .asphalt
        }
    }

    private static func cover(ofArea area: (layer: String, featureClass: String, ring: [(east: Double, north: Double)]))
        -> Cover {
        switch (area.layer, area.featureClass) {
        case ("water", _): .water
        case ("building", _): .roof
        case ("park", _): .park
        case ("landcover", _): .trees
        case (_, "industrial"): .industrial
        default: .houses
        }
    }

    /// What a cover looks like at a point: the patterned ones — fields,
    /// house plots, a park's trees — vary with where they are.
    private static func colour(of cover: Cover, east: Double, north: Double) -> Colour {
        switch cover {
        case .water: return Palette.water
        case .roof: return Palette.roof
        case .park: return trees(east: east, north: north)
        case .trees: return Palette.trees
        case .industrial: return Palette.industrial
        case .houses: return houses(east: east, north: north)
        case .motorway: return Palette.motorway
        case .rail: return Palette.rail
        case .asphalt: return Palette.asphalt
        case .fields:
            let field = SampleGeometry.hash(Int((east / Ground.field).rounded(.down)),
                                            Int((north / Ground.field).rounded(.down)))
            return Palette.fields[min(Int(field * Double(Palette.fields.count)), Palette.fields.count - 1)]
        }
    }

    /// Plots of houses: a roof in each plot's corner, its garden around.
    private static func houses(east: Double, north: Double) -> Colour {
        let alongEast = (east / Ground.plot).truncatingRemainder(dividingBy: 1)
        let alongNorth = (north / Ground.plot).truncatingRemainder(dividingBy: 1)
        let inRoof = abs(alongEast) < Ground.roofShare && abs(alongNorth) < Ground.roofShare
        let plot = SampleGeometry.hash(Int((east / Ground.plot).rounded(.down)), Int((north / Ground.plot).rounded(.down)))
        if inRoof { return plot < 0.5 ? Palette.roof : Palette.paving }
        return Palette.garden
    }

    /// A park: grass, with clumps of trees.
    private static func trees(east: Double, north: Double) -> Colour {
        let clump = SampleGeometry.hash(Int((east / Ground.plot).rounded(.down)), Int((north / Ground.plot).rounded(.down)))
        return clump < 0.4 ? Palette.trees : Palette.grass
    }
}

/// Geometry in the town's metres, shared by the sample ground and its
/// aerial view.
enum SampleGeometry {
    /// Calls `body` with each sample of a tile — its index row by row from
    /// the north-west, and its middle in metres east and north of the
    /// town's origin.
    static func forEachSample(of id: TileID, samples: Int, _ body: (Int, Double, Double) -> Void) {
        let grid = Grid(id, samples: samples)
        for row in 0..<samples {
            let north = grid.north(ofRow: row)
            for column in 0..<samples {
                body(row * samples + column, grid.east(ofColumn: column), north)
            }
        }
    }

    /// A tile's samples as a grid in the town's metres: where each sample's
    /// middle lies, and which samples a shape can reach — so a shape is
    /// drawn onto the samples it covers rather than every sample asked of
    /// every shape.
    struct Grid {
        let samples: Int
        private let minimum: (x: Double, y: Double)
        private let span: (x: Double, y: Double)
        private let origin: (x: Double, y: Double)
        private let metresPerUnit: Double
        private static let middle = 0.5

        init(_ id: TileID, samples: Int) {
            let (minimum, maximum) = id.worldBounds
            let origin = WebMercator.project(SampleTown.origin)
            self.samples = samples
            self.minimum = (minimum.x, minimum.y)
            span = (maximum.x - minimum.x, maximum.y - minimum.y)
            self.origin = (origin.x, origin.y)
            metresPerUnit = WebMercator.metresPerWorldUnit(atLatitude: SampleTown.origin.latitude)
        }

        func east(ofColumn column: Int) -> Double {
            (minimum.x + (Double(column) + Self.middle) / Double(samples) * span.x - origin.x) * metresPerUnit
        }

        func north(ofRow row: Int) -> Double {
            (origin.y - (minimum.y + (Double(row) + Self.middle) / Double(samples) * span.y)) * metresPerUnit
        }

        /// The columns whose middles may lie between two eastings — a
        /// column's margin either side, so rounding never drops one; the
        /// caller tests each exactly.
        private func columns(east low: Double, _ high: Double) -> ClosedRange<Int>? {
            let first = Int(((low / metresPerUnit + origin.x - minimum.x) / span.x * Double(samples)).rounded(.down)) - 1
            let last = Int(((high / metresPerUnit + origin.x - minimum.x) / span.x * Double(samples)).rounded(.up)) + 1
            return clamped(first, last)
        }

        /// The rows whose middles may lie between two northings, north at
        /// the top.
        private func rows(north low: Double, _ high: Double) -> ClosedRange<Int>? {
            let first = Int(((origin.y - high / metresPerUnit - minimum.y) / span.y * Double(samples)).rounded(.down)) - 1
            let last = Int(((origin.y - low / metresPerUnit - minimum.y) / span.y * Double(samples)).rounded(.up)) + 1
            return clamped(first, last)
        }

        private func clamped(_ first: Int, _ last: Int) -> ClosedRange<Int>? {
            let low = max(first, 0), high = min(last, samples - 1)
            return low <= high ? low...high : nil
        }

        /// Calls `body` with each sample inside `ring` by the even-odd rule
        /// — the same crossings, in the same order, as `contains`, so a
        /// sample is inside here exactly when it is inside there.
        func fill(_ ring: [(east: Double, north: Double)], _ body: (Int) -> Void) {
            guard let last = ring.last,
                  let rowRange = rows(north: ring.map(\.north).min() ?? 0, ring.map(\.north).max() ?? 0),
                  let columnRange = columns(east: ring.map(\.east).min() ?? 0, ring.map(\.east).max() ?? 0)
            else { return }
            var crossings: [Double] = []
            for row in rowRange {
                let north = north(ofRow: row)
                crossings.removeAll(keepingCapacity: true)
                var previous = last
                for point in ring {
                    if (point.north > north) != (previous.north > north) {
                        crossings.append(previous.east + (north - previous.north) / (point.north - previous.north)
                                         * (point.east - previous.east))
                    }
                    previous = point
                }
                guard !crossings.isEmpty else { continue }
                crossings.sort()
                // A sample is inside when an odd number of crossings lie
                // east of it (`contains` counts `east < crossing`).
                var passed = 0
                for column in columnRange {
                    let east = east(ofColumn: column)
                    while passed < crossings.count, crossings[passed] <= east { passed += 1 }
                    if (crossings.count - passed) % 2 == 1 { body(row * samples + column) }
                }
            }
        }

        /// Calls `body` with each sample within `halfWidth` of a segment.
        func paint(from start: (east: Double, north: Double), to end: (east: Double, north: Double),
                   halfWidth: Double, _ body: (Int) -> Void) {
            guard let rowRange = rows(north: min(start.north, end.north) - halfWidth,
                                      max(start.north, end.north) + halfWidth),
                  let columnRange = columns(east: min(start.east, end.east) - halfWidth,
                                            max(start.east, end.east) + halfWidth)
            else { return }
            for row in rowRange {
                let north = north(ofRow: row)
                for column in columnRange
                where SampleGeometry.distance(east(ofColumn: column), north, start, end) <= halfWidth {
                    body(row * samples + column)
                }
            }
        }
    }

    /// The distance from a point to a segment.
    static func distance(_ east: Double, _ north: Double, _ start: (east: Double, north: Double),
                         _ end: (east: Double, north: Double)) -> Double {
        let deltaEast = end.east - start.east, deltaNorth = end.north - start.north
        let lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth
        let along = lengthSquared == 0 ? 0
            : min(max(((east - start.east) * deltaEast + (north - start.north) * deltaNorth) / lengthSquared, 0), 1)
        let nearestEast = start.east + along * deltaEast, nearestNorth = start.north + along * deltaNorth
        return ((east - nearestEast) * (east - nearestEast) + (north - nearestNorth) * (north - nearestNorth))
            .squareRoot()
    }

    /// Whether a ring holds a point, by the even-odd rule.
    static func contains(_ ring: [(east: Double, north: Double)], east: Double, north: Double) -> Bool {
        var inside = false
        var previous = ring.last ?? (0, 0)
        for point in ring {
            if (point.north > north) != (previous.north > north) {
                let crossing = previous.east + (north - previous.north) / (point.north - previous.north)
                    * (point.east - previous.east)
                if east < crossing { inside.toggle() }
            }
            previous = point
        }
        return inside
    }

    /// A number in 0 ..< 1 that depends only on two integers: a
    /// SplitMix64 finaliser (Steele, Lea and Flood, "Fast splittable
    /// pseudorandom number generators", OOPSLA 2014) over them both.
    static func hash(_ first: Int, _ second: Int) -> Double {
        var value = UInt64(bitPattern: Int64(first)) &* SplitMix.multiplierA ^ UInt64(bitPattern: Int64(second))
        value = (value ^ (value >> SplitMix.shiftA)) &* SplitMix.multiplierB
        value = (value ^ (value >> SplitMix.shiftB)) &* SplitMix.multiplierC
        value ^= value >> SplitMix.shiftC
        return Double(value >> SplitMix.mantissaShift) / Double(1 << SplitMix.mantissaBits)
    }

    private enum SplitMix {
        static let multiplierA: UInt64 = 0x9E37_79B9_7F4A_7C15
        static let multiplierB: UInt64 = 0xBF58_476D_1CE4_E5B9
        static let multiplierC: UInt64 = 0x94D0_49BB_1331_11EB
        static let shiftA: UInt64 = 30
        static let shiftB: UInt64 = 27
        static let shiftC: UInt64 = 31
        /// A double's 53 bits of mantissa, from the top of the word.
        static let mantissaBits = 53
        static let mantissaShift: UInt64 = 11
    }
}
