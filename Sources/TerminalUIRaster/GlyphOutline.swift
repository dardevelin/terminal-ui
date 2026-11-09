/// One point of a TrueType outline. In a font's own outline the
/// coordinates are font units, y up; handed to the rasterizer they are
/// 24.8 fixed-point device pixels, y down.
package struct OutlinePoint: Equatable, Sendable {
    package var x: Int
    package var y: Int
    /// Off-curve points are the control points of quadratic Béziers; two in
    /// a row imply an on-curve point midway between them (OpenType spec,
    /// "glyf", simple glyph description; Apple TrueType Reference Manual,
    /// chapter 1, "Digitizing letterform designs").
    package var isOnCurve: Bool

    package init(_ x: Int, _ y: Int, onCurve: Bool = true) {
        self.x = x
        self.y = y
        isOnCurve = onCurve
    }
}

/// A glyph's contours as `glyf` stores them: every point in order, and the
/// index of each contour's last point. A composite glyph's outline is its
/// components', transformed and concatenated, so point numbers run across
/// the whole glyph as the composite's point-matching arguments count them.
package struct GlyphOutline: Equatable, Sendable {
    package var points: [OutlinePoint]
    package var contourEnds: [Int]

    package init() {
        points = []
        contourEnds = []
    }

    package init(contours: [[OutlinePoint]]) {
        self.init()
        for contour in contours { append(contour: contour) }
    }

    package var isEmpty: Bool { points.isEmpty }

    package var contours: [ArraySlice<OutlinePoint>] {
        var start = 0
        return contourEnds.map { end in
            defer { start = end + 1 }
            return points[start...end]
        }
    }

    package mutating func append(contour: some Collection<OutlinePoint>) {
        guard !contour.isEmpty else { return }
        points += contour
        contourEnds.append(points.count - 1)
    }

    /// Every point moved through `transform`, contour structure kept.
    func map(_ transform: (OutlinePoint) -> OutlinePoint) -> GlyphOutline {
        var result = self
        result.points = points.map(transform)
        return result
    }
}
