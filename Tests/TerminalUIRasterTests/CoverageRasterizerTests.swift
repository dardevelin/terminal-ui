import Testing
@testable import TerminalUIRaster

/// Shapes whose coverage is known exactly, in 24.8 device pixels, y down.
@Suite("Coverage rasterizer")
struct CoverageRasterizerTests {
    private let one = CoverageRasterizer.one

    private func rasterize(_ contours: [OutlinePoint]...) -> CoverageBitmap {
        CoverageRasterizer.rasterize(GlyphOutline(contours: contours))
    }

    @Test("a square on whole pixels covers each of them fully, placed where it lies")
    func wholePixels() {
        let bitmap = rasterize(rectangle(1, 2, 3, 4))
        #expect(bitmap.width == 2 && bitmap.height == 2)
        #expect(bitmap.left == 1 && bitmap.top == 2)
        #expect(bitmap.coverage == [255, 255, 255, 255])
    }

    // 24.8 counts area exactly in (1/256 px)²; 8-bit coverage rounds it to
    // the nearest level, a half up, so half a pixel is 127.5 → 128.
    @Test("an edge halfway across a pixel covers it with exactly 128")
    func halfPixelEdge() {
        let bitmap = rasterize([OutlinePoint(0, 0), OutlinePoint(3 * one / 2, 0),
                                OutlinePoint(3 * one / 2, one), OutlinePoint(0, one)])
        #expect(bitmap.coverage == [255, 128])
        let shifted = rasterize([OutlinePoint(one / 2, 0), OutlinePoint(3 * one / 2, 0),
                                 OutlinePoint(3 * one / 2, one), OutlinePoint(one / 2, one)])
        #expect(shifted.coverage == [128, 128])
    }

    @Test("a quarter pixel in each direction covers a sixteenth")
    func quarterPixelCorner() {
        let bitmap = rasterize([OutlinePoint(0, 0), OutlinePoint(one / 4, 0),
                                OutlinePoint(one / 4, one / 4), OutlinePoint(0, one / 4)])
        // 255 / 16 = 15.94.
        #expect(bitmap.coverage == [16])
    }

    // The hypotenuse runs corner to corner of the two pixels it crosses,
    // halving each; the pixel below and right of it is touched at a point.
    @Test("a right triangle covers its diagonal pixels by half")
    func triangle() {
        let bitmap = rasterize([OutlinePoint(0, 0), OutlinePoint(2 * one, 0), OutlinePoint(0, 2 * one)])
        #expect(bitmap.width == 2 && bitmap.height == 2)
        #expect(bitmap.coverage == [255, 128, 128, 0])
    }

    @Test("winding direction does not change coverage")
    func direction() {
        let triangle = [OutlinePoint(0, 0), OutlinePoint(5 * one, one), OutlinePoint(2 * one, 4 * one)]
        #expect(rasterize(triangle) == rasterize(Array(triangle.reversed())))
    }

    // Each pixel's level is its exact area rounded, so the total is within
    // half a level a pixel; cutting edges at pixel boundaries rounds the
    // cut to 1/256 px, which this triangle's slopes exercise.
    @Test("coverage sums to the area, within the rounding of each pixel")
    func areaSum() {
        let points = [OutlinePoint(37, 12), OutlinePoint(9 * one + 101, 3 * one + 7), OutlinePoint(4 * one + 55, 7 * one + 200)]
        let bitmap = rasterize(points)
        let doubledArea = abs((points[1].x - points[0].x) * (points[2].y - points[0].y)
                              - (points[2].x - points[0].x) * (points[1].y - points[0].y))
        // Σ coverage ≈ 255 · area / one², area being doubledArea / 2.
        let expected = Double(255 * doubledArea) / Double(2 * one * one)
        let total = bitmap.coverage.reduce(0) { $0 + Int($1) }
        #expect(abs(Double(total) - expected) <= Double(bitmap.width * bitmap.height) / 2,
                "\(total) against \(expected)")
    }

    // A parabolic segment encloses two thirds of its control triangle
    // (Archimedes), here 2/3 · ½ · 8 · 8 px; the curve's apex is halfway to
    // its control point, at y = 4, so nothing below is inked. Flattened, the
    // curve is a polygon inscribed in it, each chord within the tolerance of
    // the arc, so the area falls short by under 2/3 · tolerance · length
    // (each sliver a parabolic segment itself), the length here under the
    // control polygon's 2√80 px; each pixel's rounding adds half a level.
    @Test("a quadratic curve encloses two thirds of its control triangle, and stops at its apex")
    func quadratic() {
        let bitmap = rasterize([OutlinePoint(0, 0), OutlinePoint(4 * one, 8 * one, onCurve: false), OutlinePoint(8 * one, 0)])
        #expect(bitmap.width == 8 && bitmap.height == 8, "the control box")
        let total = Double(bitmap.coverage.reduce(0) { $0 + Int($1) })
        let expected = 255.0 * 64.0 / 3.0
        let tolerance = Double(CoverageRasterizer.flatteningTolerance) / Double(one)
        let flatteningLoss = 255.0 * 2.0 / 3.0 * tolerance * 2.0 * 80.0.squareRoot()
        let rounding = Double(bitmap.width * bitmap.height) / 2
        #expect(total <= expected + rounding && total >= expected - flatteningLoss - rounding,
                "\(total) against \(expected)")
        let art = asciiArt(width: 8, height: 8, coverage: bitmap.coverage)
        #expect(bitmap.coverage[(4 * 8)...].allSatisfy { $0 == 0 }, "\n\(art)")
        #expect(bitmap[3, 0] == 255 && bitmap[4, 3] > 0)
    }

    @Test("two off-curve points imply the on-curve point between them")
    func impliedOnCurvePoint() {
        // A circle-ish contour from four off-curve points only: the implied
        // points are the side midpoints, so it touches each side of its box.
        let bitmap = rasterize([OutlinePoint(0, 0, onCurve: false), OutlinePoint(8 * one, 0, onCurve: false),
                                OutlinePoint(8 * one, 8 * one, onCurve: false), OutlinePoint(0, 8 * one, onCurve: false)])
        #expect(bitmap[3, 0] > 0 && bitmap[0, 3] > 0 && bitmap[7, 4] > 0 && bitmap[4, 7] > 0)
        #expect(bitmap[0, 0] == 0 && bitmap[7, 7] == 0, "the box's corners are outside the curve")
        #expect(bitmap[4, 4] == 255)
    }

    // Nonzero winding: where two contours drawn the same way overlap, the
    // winding number is 2 and the pixel is inside; even-odd would empty it.
    @Test("overlapping contours drawn the same way fill their overlap")
    func nonzeroOverlap() {
        let bitmap = rasterize(rectangle(0, 0, 2, 1), rectangle(1, 0, 3, 1))
        #expect(bitmap.coverage == [255, 255, 255])
    }

    @Test("a contour drawn the other way inside another is a hole")
    func hole() {
        let bitmap = rasterize(rectangle(0, 0, 3, 3), Array(rectangle(1, 1, 2, 2).reversed()))
        #expect(bitmap.coverage == [255, 255, 255, 255, 0, 255, 255, 255, 255])
    }

    @Test("an empty outline is an empty bitmap")
    func empty() {
        #expect(CoverageRasterizer.rasterize(GlyphOutline()) == .empty)
        #expect(rasterize([OutlinePoint(one, one), OutlinePoint(3 * one, one)]).coverage.allSatisfy { $0 == 0 },
                "a contour with no area")
    }

    @Test("a curve is flattened into more lines the further it bends")
    func flatteningSteps() {
        func steps(_ bend: Int) -> Int {
            var count = 0
            CoverageRasterizer.flatten(from: OutlinePoint(0, 0), control: OutlinePoint(bend, bend),
                                       to: OutlinePoint(2 * bend, 0)) { _, _ in count += 1 }
            return count
        }
        #expect(steps(one / 8) == 1, "a bend within the tolerance stays one line")
        #expect(steps(4 * one) > steps(one))
        #expect(steps(1 << 30) == CoverageRasterizer.maximumCurveSteps)
    }
}

@Suite("Synthetic styles")
struct SyntheticStyleTests {
    private let one = CoverageRasterizer.one

    // At 16 px an em, 1/32 em is half a pixel: a 2 px square (y up,
    // clockwise as TrueType draws outer contours) grows to 3 px, half a
    // pixel each side, its corners a quarter covered.
    @Test("emboldening moves each edge out by 1/32 em")
    func embolden() {
        let square = GlyphOutline(contours: [[OutlinePoint(one, one), OutlinePoint(one, 3 * one),
                                              OutlinePoint(3 * one, 3 * one), OutlinePoint(3 * one, one)]])
        let bold = SyntheticStyle.embolden(square, size: GlyphSize(pixelsPerEm: 16))
        #expect(bold.points == [OutlinePoint(one / 2, one / 2), OutlinePoint(one / 2, 7 * one / 2),
                                OutlinePoint(7 * one / 2, 7 * one / 2), OutlinePoint(7 * one / 2, one / 2)])
        let bitmap = CoverageRasterizer.rasterize(bold.map { OutlinePoint($0.x, -$0.y) })
        #expect(bitmap.coverage == [64, 128, 128, 64,
                                    128, 255, 255, 128,
                                    128, 255, 255, 128,
                                    64, 128, 128, 64])
    }

    @Test("a font drawn counter-clockwise grows too, and a hole shrinks")
    func emboldenOrientation() {
        let outer = [OutlinePoint(0, 0), OutlinePoint(8 * one, 0), OutlinePoint(8 * one, 8 * one), OutlinePoint(0, 8 * one)]
        let inner = [OutlinePoint(2 * one, 2 * one), OutlinePoint(2 * one, 6 * one),
                     OutlinePoint(6 * one, 6 * one), OutlinePoint(6 * one, 2 * one)]
        let bold = SyntheticStyle.embolden(GlyphOutline(contours: [outer, inner]), size: GlyphSize(pixelsPerEm: 16))
        #expect(bold.points[0] == OutlinePoint(-one / 2, -one / 2))
        #expect(bold.points[4] == OutlinePoint(5 * one / 2, 5 * one / 2))
    }

    @Test("oblique shears right by 17/80 of the height above the baseline")
    func oblique() {
        let outline = GlyphOutline(contours: [[OutlinePoint(0, 0), OutlinePoint(10, 80 * one), OutlinePoint(0, -40 * one)]])
        #expect(SyntheticStyle.oblique(outline).points.map(\.x) == [0, 10 + 17 * one, -17 * one / 2])
    }
}

@Suite("Integer maths")
struct IntegerMathTests {
    @Test("division rounds toward negative infinity, and to nearest a half up")
    func division() {
        #expect([7, -7, 6, -6].map { IntegerMath.floorDivide($0, 2) } == [3, -4, 3, -3])
        #expect(IntegerMath.floorDivide(7, -2) == -4)
        #expect([7, -7, 6, -6].map { IntegerMath.ceilDivide($0, 2) } == [4, -3, 3, -3])
        #expect([5, -5, 4, -4, 3, -3].map { IntegerMath.roundedDivide($0, 2) } == [3, -2, 2, -2, 2, -1])
        #expect(IntegerMath.roundedDivide(5, -2) == -2)
    }

    @Test("square roots are floored")
    func squareRoot() {
        #expect([0, 1, 2, 3, 4, 15, 16, 17, 1 << 40].map(IntegerMath.squareRoot) == [0, 1, 1, 1, 2, 3, 4, 4, 1 << 20])
    }
}
