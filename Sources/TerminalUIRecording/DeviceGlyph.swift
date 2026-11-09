/// A point in device pixels, in sixteenths: fine enough to place a curve's
/// edge for anti-aliasing, and a power of two, so it converts exactly to a
/// rasterizer's fixed point and prints as a short exact decimal.
package struct SubpixelPoint: Hashable, Sendable {
    package static let perPixel = 16

    package var x: Int
    package var y: Int

    package init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }
}

/// How thick a light and a heavy line are drawn, in whole device pixels:
/// in a raster a stroke is snapped to the pixel grid, and in SVG a line
/// that starts on a pixel's edge is drawn sharp.
package struct StrokeWidths: Hashable, Sendable {
    package var light: Int
    package var heavy: Int

    /// A ninth of the cell's width, at least a pixel: one pixel at the
    /// docs' 15 px font, two at `@2x`. A heavy line is twice as thick.
    package static let lightShareOfCellWidth = Proportion(1, 9)
    package static let heavyMultiple = 2

    package init(cellWidth: Int) {
        light = max(1, Self.lightShareOfCellWidth.scaled(cellWidth))
        heavy = light * Self.heavyMultiple
    }

    package func width(_ weight: StrokeWeight) -> Int {
        weight == .light ? light : heavy
    }
}

/// A glyph's shape resolved for one cell size: what a renderer fills, in
/// device pixels from the cell's top-left corner.
///
/// Edges a renderer should draw sharp — straight lines, block elements,
/// squares — are whole pixels, and every line is rounded to the pixel grid
/// the same way, so a line meets the one across it, and the next cell's,
/// exactly. Curves and slants are in ``SubpixelPoint`` sixteenths, for a
/// renderer to anti-alias.
package struct DeviceGlyph: Hashable, Sendable {
    package enum Figure: Hashable, Sendable {
        /// Whole pixels.
        case rect(x: Int, y: Int, width: Int, height: Int)
        case polygon([SubpixelPoint])
        case circle(centre: SubpixelPoint, radius: Int)
        /// The part of a ring between two radii in one quarter of its
        /// circle: the points whose offset from `centre` has the signs of
        /// `quarter`.
        case quarterRing(centre: SubpixelPoint, innerRadius: Int, outerRadius: Int, quarter: CornerOpening)
    }

    package struct Mark: Hashable, Sendable {
        package var figure: Figure
        package var opacity: Proportion
    }

    package var width: Int
    package var height: Int
    package var marks: [Mark]

    /// Every mark a rect from the cell's left edge to its right: a row of
    /// such glyphs side by side draws the same as one stretched across
    /// them — `─`, `═`, `█`, `▀`, the shades.
    package var spansWidth: Bool {
        !marks.isEmpty && marks.allSatisfy { mark in
            guard case .rect(let x, _, let rectWidth, _) = mark.figure else { return false }
            return x == 0 && rectWidth == width
        }
    }

    package init(_ shape: GlyphShape, cellWidth: Int, cellHeight: Int) {
        let resolver = Resolver(cellWidth: cellWidth, cellHeight: cellHeight,
                                strokes: StrokeWidths(cellWidth: cellWidth))
        width = cellWidth
        height = cellHeight
        marks = Self.merged(shape.primitives.flatMap { primitive in
            resolver.figures(primitive.figure).map { Mark(figure: $0, opacity: primitive.opacity) }
        })
    }

    /// `marks` with each rectangle that continues an earlier one in line —
    /// the halves of a line through the cell, the arms of a double line
    /// that overlap at its centre — folded into it, so a picture holds one
    /// rectangle per stroke.
    private static func merged(_ marks: [Mark]) -> [Mark] {
        var result: [Mark] = []
        for mark in marks {
            guard case .rect(let x, let y, let width, let height) = mark.figure,
                  let index = result.firstIndex(where: { continues($0, x, y, width, height, mark.opacity) }),
                  case .rect(let otherX, let otherY, let otherWidth, let otherHeight) = result[index].figure else {
                result.append(mark)
                continue
            }
            let left = min(x, otherX), top = min(y, otherY)
            result[index].figure = .rect(x: left, y: top, width: max(x + width, otherX + otherWidth) - left,
                                         height: max(y + height, otherY + otherHeight) - top)
        }
        return result
    }

    /// Whether the rectangle lies in line with `mark`'s and touches or
    /// overlaps it, at the same opacity.
    private static func continues(_ mark: Mark, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
                                  _ opacity: Proportion) -> Bool {
        guard mark.opacity == opacity, case .rect(let otherX, let otherY, let otherWidth, let otherHeight) = mark.figure
        else { return false }
        let rows = y == otherY && height == otherHeight && x <= otherX + otherWidth && otherX <= x + width
        let columns = x == otherX && width == otherWidth && y <= otherY + otherHeight && otherY <= y + height
        return rows || columns
    }
}

private struct Resolver {
    let cellWidth: Int
    let cellHeight: Int
    let strokes: StrokeWidths

    private static let units = CellCoordinate.unitsPerCell
    private static let sub = SubpixelPoint.perPixel

    func figures(_ figure: GlyphPrimitive.Figure) -> [DeviceGlyph.Figure] {
        switch figure {
        case .rect(let from, let to):
            let left = pixel(x(from.x)), right = pixel(x(to.x))
            let top = pixel(y(from.y)), bottom = pixel(y(to.y))
            return nonEmpty(.rect(x: min(left, right), y: min(top, bottom),
                                  width: abs(right - left), height: abs(bottom - top)))
        case .line(let from, let to, let weight):
            return line(from, to, thickness: strokes.width(weight), capped: true)
        case .dash(let from, let to, let weight):
            return line(from, to, thickness: strokes.width(weight), capped: false)
        case .roundedCorner(let centre, let opening, let weight):
            return roundedCorner(centre, opening, thickness: strokes.width(weight))
        case .circle(let centre, let radius):
            return [.circle(centre: SubpixelPoint(x(centre.x), y(centre.y)), radius: length(radius))]
        case .polygon(let points):
            return [.polygon(points.map { SubpixelPoint(x($0.x), y($0.y)) })]
        }
    }

    // MARK: Coordinates

    /// A coordinate in sixteenths of a pixel along an axis `extent` pixels
    /// long.
    private func sixteenths(_ coordinate: CellCoordinate, extent: Int) -> Int {
        let numerator = (coordinate.cell * extent + coordinate.width * cellWidth) * Self.sub
        return roundedDivision(numerator, Self.units) + coordinate.strokes * strokes.light * Self.sub
    }

    private func x(_ coordinate: CellCoordinate) -> Int { sixteenths(coordinate, extent: cellWidth) }
    private func y(_ coordinate: CellCoordinate) -> Int { sixteenths(coordinate, extent: cellHeight) }
    private func length(_ coordinate: CellCoordinate) -> Int { sixteenths(coordinate, extent: cellWidth) }

    /// The nearest whole pixel, half up.
    private func pixel(_ sixteenths: Int) -> Int { roundedDivision(sixteenths, Self.sub) }

    /// Where a stroke `thickness` pixels thick, centred on `centre`
    /// sixteenths, starts: its centre rounded so the stroke covers whole
    /// pixels, the same way for every line.
    private func strokeStart(_ centre: Int, thickness: Int) -> Int {
        roundedDivision(centre - thickness * Self.sub / 2, Self.sub)
    }

    /// The centre of the stroke `strokeStart` places, in sixteenths.
    private func snappedCentre(_ centre: Int, thickness: Int) -> Int {
        strokeStart(centre, thickness: thickness) * Self.sub + thickness * Self.sub / 2
    }

    private func nonEmpty(_ figure: DeviceGlyph.Figure) -> [DeviceGlyph.Figure] {
        if case .rect(_, _, let width, let height) = figure, width <= 0 || height <= 0 { return [] }
        return [figure]
    }

    // MARK: Lines

    private func line(_ from: CellPoint, _ to: CellPoint, thickness: Int, capped: Bool) -> [DeviceGlyph.Figure] {
        let cap = capped ? thickness * Self.sub / 2 : 0
        if from.y == to.y {
            let (top, (left, right)) = (strokeStart(y(from.y), thickness: thickness),
                                        span(from.x, to.x, extent: cellWidth, cap: cap))
            return nonEmpty(.rect(x: left, y: top, width: right - left, height: thickness))
        }
        if from.x == to.x {
            let (left, (top, bottom)) = (strokeStart(x(from.x), thickness: thickness),
                                         span(from.y, to.y, extent: cellHeight, cap: cap))
            return nonEmpty(.rect(x: left, y: top, width: thickness, height: bottom - top))
        }
        return [slantedLine(from, to, thickness: thickness)]
    }

    /// A straight line's extent along its axis, in whole pixels: an end on
    /// the cell's edge exactly there, an end inside it `cap` sixteenths
    /// past the point.
    private func span(_ from: CellCoordinate, _ to: CellCoordinate, extent: Int, cap: Int) -> (Int, Int) {
        func end(_ coordinate: CellCoordinate, outward: Int) -> Int {
            if coordinate.isEdge { return coordinate.cell == 0 ? 0 : extent }
            return roundedDivision(sixteenths(coordinate, extent: extent) + outward * cap, Self.sub)
        }
        let (low, high) = sixteenths(from, extent: extent) <= sixteenths(to, extent: extent) ? (from, to) : (to, from)
        return (end(low, outward: -1), end(high, outward: 1))
    }

    /// A diagonal, as the rectangle its stroke covers: the centre line
    /// offset half the stroke to each side, an end inside the cell capped
    /// as a straight line's is.
    private func slantedLine(_ from: CellPoint, _ to: CellPoint, thickness: Int) -> DeviceGlyph.Figure {
        let start = SubpixelPoint(x(from.x), y(from.y)), finish = SubpixelPoint(x(to.x), y(to.y))
        let (dx, dy) = (finish.x - start.x, finish.y - start.y)
        let length = max(integerSquareRoot(dx * dx + dy * dy), 1)
        let half = thickness * Self.sub / 2
        // The unit normal and direction, scaled to half the stroke.
        let normal = (roundedDivision(-dy * half, length), roundedDivision(dx * half, length))
        let along = (roundedDivision(dx * half, length), roundedDivision(dy * half, length))
        let startCap = from.x.isEdge || from.y.isEdge ? 0 : 1
        let finishCap = to.x.isEdge || to.y.isEdge ? 0 : 1
        let first = SubpixelPoint(start.x - startCap * along.0, start.y - startCap * along.1)
        let last = SubpixelPoint(finish.x + finishCap * along.0, finish.y + finishCap * along.1)
        return .polygon([
            SubpixelPoint(first.x + normal.0, first.y + normal.1), SubpixelPoint(last.x + normal.0, last.y + normal.1),
            SubpixelPoint(last.x - normal.0, last.y - normal.1), SubpixelPoint(first.x - normal.0, first.y - normal.1),
        ])
    }

    // MARK: Rounded corners

    private func roundedCorner(_ centre: CellPoint, _ opening: CornerOpening, thickness: Int) -> [DeviceGlyph.Figure] {
        // The arc is tangent to the lines as they are snapped, so it meets
        // the next cell's ─ and │ where they are drawn.
        let lineX = snappedCentre(x(centre.x), thickness: thickness)
        let lineY = snappedCentre(y(centre.y), thickness: thickness)
        let radius = opening.horizontal > 0 ? cellWidth * Self.sub - lineX : lineX
        let circle = SubpixelPoint(lineX + opening.horizontal * radius, lineY + opening.vertical * radius)
        let half = thickness * Self.sub / 2
        let ring = DeviceGlyph.Figure.quarterRing(
            centre: circle, innerRadius: radius - half, outerRadius: radius + half,
            quarter: CornerOpening(horizontal: -opening.horizontal, vertical: -opening.vertical))
        // The vertical line on from the arc's end to the edge.
        let arcEnd = pixel(lineY + opening.vertical * radius)
        let (top, bottom) = opening.vertical > 0 ? (arcEnd, cellHeight) : (0, arcEnd)
        let left = strokeStart(x(centre.x), thickness: thickness)
        return [ring] + nonEmpty(.rect(x: left, y: top, width: thickness, height: bottom - top))
    }
}

/// `numerator / denominator` rounded to the nearest integer, half up, for
/// either sign: Swift's `/` truncates toward zero.
func roundedDivision(_ numerator: Int, _ denominator: Int) -> Int {
    let doubled = 2 * numerator + denominator
    let divisor = 2 * denominator
    return doubled >= 0 ? doubled / divisor : -((-doubled + divisor - 1) / divisor)
}

/// The largest integer whose square is at most `value`, by Newton's method
/// on integers: the same answer on every CPU, as no float is involved.
func integerSquareRoot(_ value: Int) -> Int {
    guard value > 1 else { return max(value, 0) }
    var estimate = value
    var next = (estimate + 1) / 2
    while next < estimate {
        estimate = next
        next = (estimate + value / estimate) / 2
    }
    return estimate
}
