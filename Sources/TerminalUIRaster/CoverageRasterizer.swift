/// An 8-bit coverage image: how much of each pixel a shape covers, 0 to
/// 255, rows top to bottom. `left` and `top` place column 0 and row 0 in
/// the device space the outline was given in (whole pixels, y down).
package struct CoverageBitmap: Equatable, Sendable {
    package var width: Int
    package var height: Int
    package var left: Int
    package var top: Int
    package var coverage: [UInt8]

    package static let empty = CoverageBitmap(width: 0, height: 0, left: 0, top: 0, coverage: [])

    package subscript(x: Int, y: Int) -> UInt8 { coverage[y * width + x] }
}

/// Draws an outline into coverage by accumulating signed area, the method
/// of Raph Levien's font-rs ("Inside the fastest font renderer in the
/// world", 2016) and of stb_truetype's version 2 rasterizer, done here in
/// integers so a glyph is the same bytes on every CPU.
///
/// Each edge is cut where it crosses a pixel row or column, so every piece
/// lies inside one pixel. A piece adds to its pixel the area of the strip
/// to its right within that pixel, and to the next pixel the rest of its
/// height: a running sum along the row then gives each pixel its covered
/// area, every edge to its left having counted for its full height and the
/// edges inside it for the part they leave covered. Coverage is that sum's
/// magnitude clamped to one pixel — the nonzero rule wherever a pixel is
/// wholly inside or outside, and the usual approximation of it at an edge
/// that overlapping contours share.
///
/// Coordinates are 24.8 fixed point: `one` is a pixel. Quadratic
/// Béziers are flattened into lines first. There is no hinting.
package enum CoverageRasterizer {
    /// 24.8 fixed point: 8 fractional bits.
    package static let fractionBits = 8
    package static let one = 1 << fractionBits

    /// The accumulator counts area doubled, in (1/256 px)², so a trapezoid's
    /// halved width sum stays an integer: a whole pixel is 2 · 256 · 256.
    static let fullPixelArea = 2 * one * one
    static let maximumCoverage = Int(UInt8.max)

    /// A flattened curve strays from the true one by at most this, in 24.8
    /// (1/16 px), well under what 8-bit coverage of one pixel resolves.
    static let flatteningTolerance = one / 16
    /// A curve is cut into at most this many lines, whatever its size, so a
    /// malformed outline cannot make the flattening run away.
    static let maximumCurveSteps = 64

    /// Coverage of `outline`, whose points are 24.8 device pixels, y down;
    /// the bitmap is the outline's control box rounded out to whole pixels.
    package static func rasterize(_ outline: GlyphOutline) -> CoverageBitmap {
        guard let first = outline.points.first else { return .empty }
        var minimumX = first.x, maximumX = first.x, minimumY = first.y, maximumY = first.y
        for point in outline.points {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        let left = IntegerMath.floorDivide(minimumX, one)
        let top = IntegerMath.floorDivide(minimumY, one)
        var accumulator = Accumulator(width: IntegerMath.ceilDivide(maximumX, one) - left,
                                      height: IntegerMath.ceilDivide(maximumY, one) - top)
        let origin = OutlinePoint(left * one, top * one)
        for contour in outline.contours {
            forEachLine(of: contour) { start, end in
                accumulator.addLine(OutlinePoint(start.x - origin.x, start.y - origin.y),
                                    OutlinePoint(end.x - origin.x, end.y - origin.y))
            }
        }
        return CoverageBitmap(width: accumulator.width, height: accumulator.height, left: left, top: top,
                              coverage: accumulator.coverage())
    }

    // MARK: - From quadratic splines to lines

    /// A TrueType contour as lines: on-curve points joined straight, an
    /// off-curve point the control of a quadratic Bézier between its
    /// neighbours, two off-curve points in a row with an implied on-curve
    /// point midway (OpenType "glyf"). The contour closes on itself.
    static func forEachLine(of contour: ArraySlice<OutlinePoint>,
                            _ body: (OutlinePoint, OutlinePoint) -> Void) {
        guard let firstPoint = contour.first, let lastPoint = contour.last else { return }
        // Start on a curve: the first point if it is on one, else the last,
        // else the midpoint the two off-curve points imply.
        let start: OutlinePoint = firstPoint.isOnCurve ? firstPoint
            : lastPoint.isOnCurve ? lastPoint : midpoint(lastPoint, firstPoint)
        var current = start
        var control: OutlinePoint?
        for point in contour.dropFirst(firstPoint.isOnCurve ? 1 : 0) + [start] {
            if point.isOnCurve {
                if let pending = control {
                    flatten(from: current, control: pending, to: point, body)
                    control = nil
                } else if point != current {
                    body(current, point)
                }
                current = point
            } else if let pending = control {
                let implied = midpoint(pending, point)
                flatten(from: current, control: pending, to: implied, body)
                current = implied
                control = point
            } else {
                control = point
            }
        }
    }

    static func midpoint(_ first: OutlinePoint, _ second: OutlinePoint) -> OutlinePoint {
        OutlinePoint(IntegerMath.floorDivide(first.x + second.x, 2), IntegerMath.floorDivide(first.y + second.y, 2))
    }

    /// A quadratic Bézier as `steps` lines at equal steps of its parameter.
    /// Each step of 1/n strays from the curve by at most |p0 − 2p1 + p2| / 4n²
    /// (the second derivative is 2(p0 − 2p1 + p2), and a chord over a step
    /// h strays by at most |B″|·h²/8), so n is the least whole number with
    /// n⁴ · 16 · tolerance² ≥ |p0 − 2p1 + p2|², all in integers.
    static func flatten(from start: OutlinePoint, control: OutlinePoint, to end: OutlinePoint,
                        _ body: (OutlinePoint, OutlinePoint) -> Void) {
        let deviationX = start.x - 2 * control.x + end.x
        let deviationY = start.y - 2 * control.y + end.y
        let deviationSquared = deviationX * deviationX + deviationY * deviationY
        let bound = 16 * flatteningTolerance * flatteningTolerance
        var steps = 1
        while steps < maximumCurveSteps && steps * steps * steps * steps * bound < deviationSquared { steps += 1 }
        let denominator = steps * steps
        var previous = start
        for step in 1...steps {
            let remaining = steps - step
            // B(t) = (1−t)²p0 + 2t(1−t)p1 + t²p2, with t = step / steps.
            let point = step == steps ? end : OutlinePoint(
                IntegerMath.roundedDivide(remaining * remaining * start.x + 2 * step * remaining * control.x
                                          + step * step * end.x, denominator),
                IntegerMath.roundedDivide(remaining * remaining * start.y + 2 * step * remaining * control.y
                                          + step * step * end.y, denominator))
            if point != previous { body(previous, point) }
            previous = point
        }
    }

    // MARK: - The accumulation buffer

    struct Accumulator {
        let width: Int
        let height: Int
        /// Each row has two cells past its last pixel: a piece in the last
        /// column adds to the cell after it, and an edge on the bitmap's
        /// right edge lands in that cell itself.
        private let stride: Int
        private var area: [Int]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            stride = width + 2
            area = [Int](repeating: 0, count: stride * height)
        }

        /// A line from `start` to `end`, in 24.8 relative to the bitmap's
        /// top-left corner, cut at each pixel row it crosses. Each cut is
        /// placed from the line's own endpoints, so rounding never drifts
        /// along it.
        mutating func addLine(_ start: OutlinePoint, _ end: OutlinePoint) {
            guard start.y != end.y else { return }
            let downward = end.y > start.y
            var current = start
            while current.y != end.y {
                let row = downward ? IntegerMath.floorDivide(current.y, one) : IntegerMath.ceilDivide(current.y, one) - 1
                let boundary = downward ? min((row + 1) * one, end.y) : max(row * one, end.y)
                let next = boundary == end.y ? end : OutlinePoint(
                    start.x + IntegerMath.roundedDivide((boundary - start.y) * (end.x - start.x), end.y - start.y),
                    boundary)
                addRowPiece(row: row, from: current, to: next)
                current = next
            }
        }

        /// A piece inside one row, cut at each pixel column it crosses.
        private mutating func addRowPiece(row: Int, from start: OutlinePoint, to end: OutlinePoint) {
            guard row >= 0, row < height else { return }
            guard start.x != end.x else {
                addCellPiece(row: row, column: IntegerMath.floorDivide(start.x, one), from: start, to: end)
                return
            }
            let rightward = end.x > start.x
            var current = start
            while true {
                let column = rightward ? IntegerMath.floorDivide(current.x, one) : IntegerMath.ceilDivide(current.x, one) - 1
                let boundary = rightward ? (column + 1) * one : column * one
                if rightward ? end.x <= boundary : end.x >= boundary {
                    addCellPiece(row: row, column: column, from: current, to: end)
                    return
                }
                let next = OutlinePoint(boundary, start.y + IntegerMath.roundedDivide(
                    (boundary - start.x) * (end.y - start.y), end.x - start.x))
                addCellPiece(row: row, column: column, from: current, to: next)
                current = next
            }
        }

        /// A piece inside one pixel: its height times the doubled width of
        /// the trapezoid between it and the pixel's right side goes to the
        /// pixel, the rest of a full-width strip to the pixel after it. Left
        /// of the bitmap counts as its left edge; right of it shows nowhere.
        private mutating func addCellPiece(row: Int, column: Int, from start: OutlinePoint, to end: OutlinePoint) {
            let height = end.y - start.y
            guard column < width else { return }
            let cell = row * stride + max(column, 0)
            if column < 0 {
                area[cell] += height * 2 * one
                return
            }
            let insideWidths = (start.x - column * one) + (end.x - column * one)
            area[cell] += height * (2 * one - insideWidths)
            area[cell + 1] += height * insideWidths
        }

        /// Each row's running sum, as 0–255, rounded to nearest.
        func coverage() -> [UInt8] {
            var result = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                var sum = 0
                for column in 0..<width {
                    sum += area[row * stride + column]
                    let level = (abs(sum) * maximumCoverage + fullPixelArea / 2) / fullPixelArea
                    result[row * width + column] = UInt8(min(level, maximumCoverage))
                }
            }
            return result
        }
    }
}
