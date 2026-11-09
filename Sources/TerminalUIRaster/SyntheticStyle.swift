/// Bold and italic for a family without those files, made from the
/// regular outline the way FreeType's FT_GlyphSlot_Embolden and
/// FT_GlyphSlot_Oblique make them, in integers. Outlines here are 24.8
/// device pixels, y up, before the rasterizer flips them.
enum SyntheticStyle {
    /// A 12° slant, FreeType's oblique angle: tan 12° ≈ 0.21256, and 17/80
    /// is 0.2125, within 1/16 px of it across a 15 px em's whole height.
    static let slantNumerator = 17
    static let slantDenominator = 80

    /// Each side of every stroke moves out by 1/32 em, so a stem gains 1/16
    /// em, about the step from JetBrains Mono's Regular to its Bold. The
    /// advance stays: a cell's width is fixed, and the ink grows evenly
    /// about where it was.
    static let emboldenDivisor = 32

    /// Unit vectors in 16.16 fixed point.
    private static let unit = 1 << 16
    /// FreeType leaves a point where the outline turns back on itself by
    /// more than about 160° (cosine below −15/16), where the offset along
    /// the bisector would shoot off.
    private static let sharpestTurnCosine = -unit * 15 / 16

    /// Sheared right in proportion to height above the baseline.
    static func oblique(_ outline: GlyphOutline) -> GlyphOutline {
        outline.map { point in
            OutlinePoint(point.x + IntegerMath.roundedDivide(point.y * slantNumerator, slantDenominator), point.y,
                         onCurve: point.isOnCurve)
        }
    }

    /// Every point, on or off the curve, moved outward along the bisector
    /// of its two edges' normals, so far that both edges move by the
    /// strength (FT_Outline_EmboldenXY). At an inward corner the move is
    /// capped by the shorter edge, so a short segment cannot fold over.
    static func embolden(_ outline: GlyphOutline, size: GlyphSize) -> GlyphOutline {
        let strength = IntegerMath.roundedDivide(size.fixedPixelsPerEm, emboldenDivisor)
        // TrueType draws outer contours clockwise (y up), ink on the right
        // of travel; a font drawn the other way round has ink on the left.
        let inkOnRight = signedArea(outline) <= 0
        var result = outline
        var contourStart = 0
        for end in outline.contourEnds {
            let contour = Array(outline.points[contourStart...end])
            for index in contour.indices {
                if let shift = shift(at: index, of: contour, strength: strength, inkOnRight: inkOnRight) {
                    result.points[contourStart + index].x += shift.x
                    result.points[contourStart + index].y += shift.y
                }
            }
            contourStart = end + 1
        }
        return result
    }

    private static func shift(at index: Int, of contour: [OutlinePoint], strength: Int,
                              inkOnRight: Bool) -> (x: Int, y: Int)? {
        let current = contour[index]
        let count = contour.count
        // The nearest distinct neighbours: a repeated point has no edge.
        guard let previous = (1..<count).lazy.map({ contour[(index - $0 + count) % count] }).first(where: { $0 != current }),
              let next = (1..<count).lazy.map({ contour[(index + $0) % count] }).first(where: { $0 != current })
        else { return nil }
        let incoming = (x: current.x - previous.x, y: current.y - previous.y)
        let outgoing = (x: next.x - current.x, y: next.y - current.y)
        let incomingLength = IntegerMath.squareRoot(incoming.x * incoming.x + incoming.y * incoming.y)
        let outgoingLength = IntegerMath.squareRoot(outgoing.x * outgoing.x + outgoing.y * outgoing.y)
        guard incomingLength > 0, outgoingLength > 0 else { return nil }
        let incomingUnit = (x: IntegerMath.roundedDivide(incoming.x * unit, incomingLength),
                            y: IntegerMath.roundedDivide(incoming.y * unit, incomingLength))
        let outgoingUnit = (x: IntegerMath.roundedDivide(outgoing.x * unit, outgoingLength),
                            y: IntegerMath.roundedDivide(outgoing.y * unit, outgoingLength))
        let cosine = IntegerMath.roundedDivide(incomingUnit.x * outgoingUnit.x + incomingUnit.y * outgoingUnit.y, unit)
        guard cosine > sharpestTurnCosine else { return nil }

        // The outward normal of a direction (x, y) is its left, (−y, x),
        // when ink is on the right, else its right.
        let side = inkOnRight ? 1 : -1
        let bisector = (x: -side * (incomingUnit.y + outgoingUnit.y), y: side * (incomingUnit.x + outgoingUnit.x))
        // The sine of the turn, positive where the outline turns away from
        // its ink — an inward corner, whose edges the offset shortens.
        let sine = side * IntegerMath.roundedDivide(incomingUnit.x * outgoingUnit.y - incomingUnit.y * outgoingUnit.x, unit)
        let onePlusCosine = unit + cosine
        let shortest = min(incomingLength, outgoingLength)
        // |bisector| is 2cos(θ/2), so bisector · s / (1 + cos θ) moves both
        // edges by s; at an inward corner that slides the point s·tan(θ/2)
        // along each edge, which is capped at the shorter edge's length.
        let (numerator, denominator) = strength * sine <= shortest * onePlusCosine
            ? (strength, onePlusCosine) : (shortest, sine)
        return (IntegerMath.roundedDivide(bisector.x * numerator, denominator),
                IntegerMath.roundedDivide(bisector.y * numerator, denominator))
    }

    /// Twice the area the outline's points enclose, by the shoelace
    /// formula: positive for counter-clockwise contours, y up.
    private static func signedArea(_ outline: GlyphOutline) -> Int {
        outline.contours.reduce(0) { total, contour in
            let points = Array(contour)
            return total + points.indices.reduce(0) { sum, index in
                let point = points[index]
                let next = points[(index + 1) % points.count]
                return sum + point.x * next.y - next.x * point.y
            }
        }
    }
}
