import Foundation

/// How a terrain map lights its hills: Horn's slope over a 3 × 3
/// neighbourhood (B. K. P. Horn, "Hill shading and the reflectance map",
/// Proceedings of the IEEE 69(1), 1981, the method GDAL's `gdaldem
/// hillshade` and Esri's Hillshade tool use), lit by a sun at `azimuth`
/// and `altitude`.
///
/// For each sample, with a … i its neighbours row by row from the
/// north-west and the cell `cellSize` metres a side:
///
///     dz/dx = ((c + 2f + i) − (a + 2d + g)) / (8 · cellSize)
///     dz/dy = ((g + 2h + i) − (a + 2b + c)) / (8 · cellSize)
///     slope  = atan(exaggeration · √(dz/dx² + dz/dy²))
///     aspect = atan2(dz/dy, −dz/dx)
///     shade  = cos(zenith) cos(slope) + sin(zenith) sin(slope) cos(azimuth′ − aspect)
///
/// where zenith is 90° less the altitude and azimuth′ the compass azimuth
/// turned to the mathematical angle, 360° − azimuth + 90° (Esri, "How
/// Hillshade works"). Flat ground shades at cos(zenith); a slope facing
/// the sun brighter, one facing away darker, to zero.
public struct Hillshade: Sendable, Equatable {
    /// The sun's compass bearing, in degrees: north-west by cartographic
    /// convention, so hills read as raised rather than as hollows.
    public var azimuth: Double
    /// The sun's height above the horizon, in degrees.
    public var altitude: Double
    /// How much steeper slopes are drawn than they are.
    public var exaggeration: Double

    /// The convention every hillshade defaults to: a sun at 315°, 45° up.
    public static let standard = Hillshade(azimuth: 315, altitude: 45, exaggeration: 1)

    public init(azimuth: Double, altitude: Double, exaggeration: Double) {
        self.azimuth = azimuth
        self.altitude = altitude
        self.exaggeration = exaggeration
    }

    /// The shade flat ground takes: cos(zenith).
    public var flat: Double { cos(radians(Angles.rightAngle - altitude)) }

    /// The shade of every sample of `tile`, 0 (unlit) to 1 (facing the
    /// sun), its cells `cellSize` metres a side. A sample at the edge takes
    /// its missing neighbours from the edge, and its difference across one
    /// cell rather than two, so a tile's border shades as its middle does
    /// and no seam shows where tiles meet.
    public func shades(of tile: ElevationTile, cellSize: Double) -> [Float] {
        let cell = max(cellSize, .leastNonzeroMagnitude)
        var shades = [Float](repeating: Float(flat), count: tile.width * tile.height)
        func span(_ index: Int, _ count: Int) -> Double {
            Double((index > 0 ? 1 : 0) + (index < count - 1 ? 1 : 0))
        }
        for y in 0..<tile.height {
            let weightY = Horn.sideWeight * max(span(y, tile.height), 1) * cell
            for x in 0..<tile.width {
                let weightX = Horn.sideWeight * max(span(x, tile.width), 1) * cell
                func at(_ column: Int, _ row: Int) -> Double { Double(tile.elevation(x: x + column, y: y + row)) }
                let northWest = at(-1, -1), north = at(0, -1), northEast = at(1, -1)
                let west = at(-1, 0), east = at(1, 0)
                let southWest = at(-1, 1), south = at(0, 1), southEast = at(1, 1)
                let deltaX = ((northEast + 2 * east + southEast) - (northWest + 2 * west + southWest)) / weightX
                let deltaY = ((southWest + 2 * south + southEast) - (northWest + 2 * north + northEast)) / weightY
                shades[y * tile.width + x] = Float(shade(gradientX: deltaX, gradientY: deltaY))
            }
        }
        return shades
    }

    /// The shade of ground rising `gradientX` metres a metre east and
    /// `gradientY` a metre south — Horn's dz/dx and dz/dy — from 0 to 1.
    public func shade(gradientX: Double, gradientY: Double) -> Double {
        let zenith = radians(Angles.rightAngle - altitude)
        let sunAngle = radians(Angles.fullTurn - azimuth + Angles.rightAngle)
        let slope = atan(exaggeration * (gradientX * gradientX + gradientY * gradientY).squareRoot())
        let aspect = atan2(gradientY, -gradientX)
        let shade = cos(zenith) * cos(slope) + sin(zenith) * sin(slope) * cos(sunAngle - aspect)
        return min(max(shade, 0), 1)
    }

    /// Horn's kernel: one side's weights, 1 + 2 + 1, over a span of two
    /// cells make the formula's eight.
    private enum Horn {
        static let sideWeight = 4.0
    }

    private enum Angles {
        static let rightAngle = 90.0
        static let fullTurn = 360.0
    }

    private func radians(_ degrees: Double) -> Double { degrees * .pi / (Angles.fullTurn / 2) }
}

/// Lines of equal height through a grid of heights, by marching squares
/// (W. E. Lorensen and H. E. Cline's "Marching cubes", SIGGRAPH 1987, in
/// two dimensions): each cell of four samples is cut where the level
/// crosses its edges, the crossing placed by linear interpolation, and a
/// saddle — two opposite corners above — resolved by the cell's mean.
public enum ContourTracer {
    /// A level's segments: four values each, `x0 y0 x1 y1`, in the tile's
    /// unit square.
    public struct Contours: Sendable, Equatable {
        public var interval: Double
        /// Every `interval` of height but the index ones.
        public var minor: [Float] = []
        /// Every fifth interval, drawn heavier, as topographic maps do.
        public var index: [Float] = []

        public init(interval: Double) {
            self.interval = interval
        }

        /// The levels traced: one segment is four values.
        public var segmentCount: Int { (minor.count + index.count) / ContourTracer.valuesPerSegment }
    }

    /// Four values make a segment: its two ends' x and y.
    public static let valuesPerSegment = 4
    /// Every fifth line is an index contour (USGS, *Topographic Map
    /// Symbols*).
    public static let indexEvery = 5

    /// The contour interval for a tile zoom, in metres: a ladder of round
    /// heights that keeps lines some ten dots apart on a 10 % slope, from
    /// 5 m at street zooms to 1 000 m across a continent.
    public static func interval(forZoom zoom: Int) -> Double {
        switch zoom {
        case ...6: 1_000
        case 7: 500
        case 8, 9: 200
        case 10: 100
        case 11, 12: 50
        case 13: 20
        case 14: 10
        default: 5
        }
    }

    /// The contours of `tile` at every multiple of `interval`.
    public static func trace(_ tile: ElevationTile, interval: Double) -> Contours {
        var contours = Contours(interval: interval)
        guard interval > 0, tile.width >= 2, tile.height >= 2 else { return contours }
        let scaleX = 1 / Double(tile.width), scaleY = 1 / Double(tile.height)
        let middle = 0.5
        for y in 0..<(tile.height - 1) {
            for x in 0..<(tile.width - 1) {
                let topLeft = tile.metres[y * tile.width + x], topRight = tile.metres[y * tile.width + x + 1]
                let bottomLeft = tile.metres[(y + 1) * tile.width + x]
                let bottomRight = tile.metres[(y + 1) * tile.width + x + 1]
                let lowest = Double(min(topLeft, topRight, bottomLeft, bottomRight))
                let highest = Double(max(topLeft, topRight, bottomLeft, bottomRight))
                let firstStep = Int((lowest / interval).rounded(.up)), lastStep = Int((highest / interval).rounded(.down))
                guard firstStep <= lastStep else { continue }
                for step in firstStep...lastStep {
                    let level = Float(Double(step) * interval)
                    let isIndex = step % indexEvery == 0
                    let corners = (topLeft >= level ? Corner.topLeft : 0) | (topRight >= level ? Corner.topRight : 0)
                        | (bottomRight >= level ? Corner.bottomRight : 0)
                        | (bottomLeft >= level ? Corner.bottomLeft : 0)
                    guard corners != 0, corners != Corner.all else { continue }
                    // The four edges' crossings, each where the level lies
                    // between the edge's two samples.
                    func along(_ from: Float, _ to: Float) -> Double {
                        from == to ? middle : Double((level - from) / (to - from))
                    }
                    let top = (Double(x) + along(topLeft, topRight), Double(y))
                    let right = (Double(x + 1), Double(y) + along(topRight, bottomRight))
                    let bottom = (Double(x) + along(bottomLeft, bottomRight), Double(y + 1))
                    let left = (Double(x), Double(y) + along(topLeft, bottomLeft))
                    var pairs: [((Double, Double), (Double, Double))] = []
                    switch corners {
                    case 1, 14: pairs = [(left, top)]
                    case 2, 13: pairs = [(top, right)]
                    case 3, 12: pairs = [(left, right)]
                    case 4, 11: pairs = [(right, bottom)]
                    case 6, 9: pairs = [(top, bottom)]
                    case 7, 8: pairs = [(left, bottom)]
                    case 5, 10:
                        let mean = (topLeft + topRight + bottomLeft + bottomRight) / Float(Corner.count)
                        let centreAbove = mean >= level
                        // Case 5 is top-left and bottom-right above: a
                        // centre above joins them across the cell, cutting
                        // off the other two corners.
                        if (corners == 5) == centreAbove {
                            pairs = [(left, bottom), (top, right)]
                        } else {
                            pairs = [(left, top), (right, bottom)]
                        }
                    default: break
                    }
                    for (start, end) in pairs {
                        let segment = [Float((start.0 + middle) * scaleX), Float((start.1 + middle) * scaleY),
                                       Float((end.0 + middle) * scaleX), Float((end.1 + middle) * scaleY)]
                        if isIndex { contours.index += segment } else { contours.minor += segment }
                    }
                }
            }
        }
        return contours
    }

    /// The bits of a marching-squares case: which corners lie at or above
    /// the level.
    private enum Corner {
        static let topLeft = 1
        static let topRight = 2
        static let bottomRight = 4
        static let bottomLeft = 8
        static let all = 15
        static let count = 4
    }
}

extension ElevationTile {
    /// The grid at `factor` times fewer samples a side, each the mean of
    /// the block it replaces: the smoothing a contour wants before it is
    /// traced, so a line follows the ground and not the noise of its data.
    public func reduced(by factor: Int) -> ElevationTile {
        guard factor > 1, width >= factor, height >= factor else { return self }
        let reducedWidth = width / factor, reducedHeight = height / factor
        var reduced = [Float](repeating: 0, count: reducedWidth * reducedHeight)
        let samples = Float(factor * factor)
        for y in 0..<reducedHeight {
            for x in 0..<reducedWidth {
                var sum: Float = 0
                for row in 0..<factor {
                    for column in 0..<factor {
                        sum += metres[(y * factor + row) * width + x * factor + column]
                    }
                }
                reduced[y * reducedWidth + x] = sum / samples
            }
        }
        return ElevationTile(checkedWidth: reducedWidth, height: reducedHeight, metres: reduced)
    }
}
