import Observation
import Testing
@testable import TerminalUI

// Canvas draws in three planes — fills on half cells, braille strokes with
// one colour to a cell, text on whole cells — and composites them into the
// cells of its rect. These tests read the cells: which glyph lands where, in
// which foreground and background.

/// Run `renderer` on a canvas of `width` × `height` cells and composite it
/// into `buffer`, or a blank one.
@MainActor
private func draw(width: Int, height: Int, style: Style = .plain, opaque: Bool = false,
                  over buffer: CellBuffer? = nil,
                  _ renderer: (inout GraphicsContext, CanvasSize) -> Void) -> CellBuffer {
    let raster = CanvasRaster()
    raster.begin(width: width, height: height, inheritedGround: style.background)
    var context = GraphicsContext(raster: raster, environment: EnvironmentValues())
    renderer(&context, CanvasSize(width: Double(width), height: Double(height)))
    var output = buffer ?? CellBuffer(width: width, height: height)
    raster.composite(into: &output, at: Rect(x: 0, y: 0, width: width, height: height),
                     style: style, opaque: opaque)
    return output
}

private func point(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(x: x, y: y) }

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CanvasRect {
    CanvasRect(x: x, y: y, width: width, height: height)
}

private func line(_ from: CanvasPoint, _ to: CanvasPoint) -> Path {
    Path { path in
        path.move(to: from)
        path.addLine(to: to)
    }
}

/// The braille pattern a cell holds, as its dot bits, or nil for another glyph.
private func dots(_ cell: Cell) -> UInt8? {
    guard let scalar = cell.character.unicodeScalars.first,
          (0x2800...0x28FF).contains(scalar.value) else { return nil }
    return UInt8(scalar.value - 0x2800)
}

private func rows(_ buffer: CellBuffer) -> [String] {
    (0..<buffer.height).map { y in (0..<buffer.width).map { String(buffer[$0, y].character) }.joined() }
}

private let red = Color.rgb(200, 0, 0)
private let blue = Color.rgb(0, 0, 200)
private let green = Color.rgb(0, 160, 0)
private let white = Color.rgb(255, 255, 255)
private let black = Color.rgb(0, 0, 0)

// Dot bits, Unicode's numbering: 1 4 / 2 5 / 3 6 / 7 8.
private let dot3: UInt8 = 0x04
private let dot6: UInt8 = 0x20
private let leftColumn: UInt8 = 0x01 | 0x02 | 0x04 | 0x40

@Suite("Canvas strokes land on braille dots")
@MainActor
struct CanvasStrokeTests {

    @Test func aHairlineLightsOneDotRowAcrossTheCellsItCrosses() {
        let buffer = draw(width: 6, height: 1) { context, _ in
            context.stroke(line(point(0, 0.5), point(3.75, 0.5)), with: .color(red))
        }
        for x in 0..<4 {
            #expect(dots(buffer[x, 0]) == dot3 | dot6, "cell \(x)")
            #expect(buffer[x, 0].style.foreground == red)
        }
        #expect(buffer[4, 0] == .empty, "the line ends in cell 3")
    }

    @Test func aLaterStrokeOfAnotherColourClearsTheEarlierDotsInItsCells() {
        let buffer = draw(width: 4, height: 2) { context, _ in
            context.stroke(line(point(0, 0.5), point(3.9, 0.5)), with: .color(red))
            context.stroke(line(point(1.25, 0), point(1.25, 1.9)), with: .color(blue))
        }
        #expect(dots(buffer[1, 0]) == leftColumn, "the bridge: only the blue dots stay")
        #expect(buffer[1, 0].style.foreground == blue)
        #expect(dots(buffer[0, 0]) == dot3 | dot6, "a cell the blue never reached keeps its red")
        #expect(buffer[0, 0].style.foreground == red)
        #expect(dots(buffer[1, 1]) == leftColumn)
    }

    @Test func strokesOfOneColourShareTheirCells() {
        let buffer = draw(width: 2, height: 1) { context, _ in
            context.stroke(line(point(0, 0.5), point(1.9, 0.5)), with: .color(red))
            context.stroke(line(point(0.25, 0), point(0.25, 0.9)), with: .color(red))
        }
        #expect(dots(buffer[0, 0]) == leftColumn | dot6)
    }

    @Test func aClosedSubpathStrokesItsClosingSide() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            var triangle = Path()
            triangle.addLines([point(0, 0), point(2.9, 0), point(0, 0.9)])
            triangle.closeSubpath()
            context.stroke(triangle, with: .color(red))
        }
        // The closing side runs down the left column of the first cell.
        #expect((dots(buffer[0, 0]) ?? 0) & leftColumn == leftColumn)
    }

    @Test func aLineWidthOfOneCellCoversFourDotRows() {
        let buffer = draw(width: 2, height: 3) { context, _ in
            context.stroke(line(point(0, 1.5), point(1.9, 1.5)), with: .color(red), lineWidth: 1)
        }
        var lit = 0
        for y in 0..<3 {
            lit += (dots(buffer[0, y]) ?? 0).nonzeroBitCount
        }
        #expect(lit == 2 * 4, "two dot columns, four dot rows each")
    }

    @Test func aLineFarOffTheCanvasDrawsOnlyWhatIsOnIt() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.stroke(line(point(-1e9, 0.5), point(1e9, 0.5)), with: .color(red))
            context.stroke(line(point(-5, -5), point(-1, -1)), with: .color(blue))
        }
        for x in 0..<4 {
            #expect(dots(buffer[x, 0]) == dot3 | dot6)
        }
    }

    @Test func halfBlockResolutionStrokesIntoTheFillPlane() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.resolution = .halfBlock
            context.stroke(line(point(0, 0.25), point(2.9, 0.25)), with: .color(red))
        }
        for x in 0..<3 {
            #expect(buffer[x, 0].character == "▀")
            #expect(buffer[x, 0].style.foreground == red)
            #expect(buffer[x, 0].style.background == nil)
        }
    }

    @Test func cellResolutionStrokesWholeCells() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.resolution = .cell
            context.stroke(line(point(0, 0.25), point(1.9, 0.25)), with: .color(red))
        }
        #expect(buffer[0, 0].character == " ")
        #expect(buffer[0, 0].style.background == red)
        #expect(buffer[1, 0].style.background == red)
        #expect(buffer[2, 0] == .empty)
    }

    @Test func curvesAreFlattenedOntoTheirEnds() {
        let buffer = draw(width: 10, height: 3) { context, _ in
            var arc = Path()
            arc.move(to: point(0, 2.9))
            arc.addQuadCurve(to: point(9.9, 2.9), control: point(5, -2.9))
            context.stroke(arc, with: .color(red))
        }
        #expect(dots(buffer[0, 2]) != nil, "the curve starts at its start")
        #expect(dots(buffer[9, 2]) != nil, "and ends at its end")
        #expect(dots(buffer[5, 0]) != nil, "and bows toward its control point")
        #expect(dots(buffer[5, 2]) == nil)
    }
}

@Suite("Canvas fills land on half cells")
@MainActor
struct CanvasFillTests {

    @Test func aFillTakesTheHalvesWhoseCentresAreInside() {
        let buffer = draw(width: 3, height: 2) { context, _ in
            context.fill(Path(rect(0, 0, 2, 1.5)), with: .color(red))
        }
        #expect(buffer[0, 0].character == " ")
        #expect(buffer[0, 0].style.background == red)
        #expect(buffer[1, 1].character == "▀", "the second row's upper half only")
        #expect(buffer[1, 1].style.foreground == red)
        #expect(buffer[1, 1].style.background == nil)
        #expect(buffer[2, 0] == .empty)
    }

    @Test func halvesOfTwoColoursDrawTheUpperHalfBlock() {
        let buffer = draw(width: 1, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 1, 0.5)), with: .color(red))
            context.fill(Path(rect(0, 0.5, 1, 0.5)), with: .color(blue))
        }
        #expect(buffer[0, 0].character == "▀")
        #expect(buffer[0, 0].style.foreground == red)
        #expect(buffer[0, 0].style.background == blue)
    }

    @Test func aLowerHalfOverNothingDrawsTheLowerHalfBlock() {
        let buffer = draw(width: 1, height: 1) { context, _ in
            context.fill(Path(rect(0, 0.5, 1, 0.5)), with: .color(blue))
        }
        #expect(buffer[0, 0].character == "▄")
        #expect(buffer[0, 0].style.foreground == blue)
    }

    @Test func evenOddLeavesAHole() {
        let buffer = draw(width: 8, height: 4) { context, _ in
            var land = Path(rect(0, 0, 8, 4))
            land.addRect(rect(2, 1, 4, 2))
            context.fill(land, with: .color(green), style: FillStyle(eoFill: true))
        }
        #expect(buffer[0, 0].style.background == green)
        #expect(buffer[3, 1] == .empty, "the lake")
        #expect(buffer[3, 2] == .empty)
        #expect(buffer[6, 2].style.background == green)
    }

    @Test func nonZeroFillsAHoleThatWindsTheSameWay() {
        let buffer = draw(width: 8, height: 4) { context, _ in
            var land = Path(rect(0, 0, 8, 4))
            land.addRect(rect(2, 1, 4, 2))
            context.fill(land, with: .color(green))
        }
        #expect(buffer[3, 1].style.background == green)
    }

    @Test func nonZeroLeavesAHoleThatWindsTheOtherWay() {
        let buffer = draw(width: 8, height: 4) { context, _ in
            var land = Path(rect(0, 0, 8, 4))
            land.addLines([point(2, 1), point(2, 3), point(6, 3), point(6, 1)])
            land.closeSubpath()
            context.fill(land, with: .color(green))
        }
        #expect(buffer[3, 1] == .empty)
        #expect(buffer[1, 1].style.background == green)
    }

    @Test func aConcavePolygonLeavesItsNotchEmpty() {
        // A U: two prongs joined along the bottom.
        let buffer = draw(width: 6, height: 4) { context, _ in
            var shape = Path()
            shape.addLines([point(0, 0), point(2, 0), point(2, 2), point(4, 2),
                            point(4, 0), point(6, 0), point(6, 4), point(0, 4)])
            shape.closeSubpath()
            context.fill(shape, with: .color(green))
        }
        #expect(rows(buffer)[0] == "      ")
        #expect(buffer[2, 0] == .empty, "the notch")
        #expect(buffer[3, 1] == .empty)
        #expect(buffer[1, 0].style.background == green)
        #expect(buffer[4, 1].style.background == green)
        #expect(buffer[3, 2].style.background == green, "below the notch")
    }

    @Test func anEllipseIsRoundedAtItsCorners() {
        let buffer = draw(width: 10, height: 5) { context, _ in
            context.fill(Path(ellipseIn: rect(0, 0, 10, 5)), with: .color(red))
        }
        #expect(buffer[0, 0] == .empty)
        #expect(buffer[9, 4] == .empty)
        #expect(buffer[5, 2].style.background == red)
        #expect(buffer[0, 2].style.background == red)
    }

    @Test func aFillOffTheCanvasIsClippedToIt() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.fill(Path(rect(-100, -100, 101, 200)), with: .color(red))
            context.fill(Path(rect(2, -1e12, 1e12, 2e12)), with: .color(blue))
        }
        #expect(buffer[0, 0].style.background == red)
        #expect(buffer[1, 0] == .empty)
        #expect(buffer[2, 0].style.background == blue)
    }

    @Test func aStrokeOverHalvesOfTwoColoursTakesTheUpperAsItsGround() {
        let buffer = draw(width: 1, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 1, 0.5)), with: .color(red))
            context.fill(Path(rect(0, 0.5, 1, 0.5)), with: .color(blue))
            context.stroke(line(point(0.25, 0), point(0.25, 0.9)), with: .color(white))
        }
        #expect(dots(buffer[0, 0]) == leftColumn)
        #expect(buffer[0, 0].style.foreground == white)
        #expect(buffer[0, 0].style.background == red)
    }

    @Test func aStrokeOverAFillKeepsTheFillAsItsBackground() {
        let buffer = draw(width: 2, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 2, 1)), with: .color(blue))
            context.stroke(line(point(0, 0.5), point(1.9, 0.5)), with: .color(white))
        }
        #expect(buffer[0, 0].style.background == blue)
        #expect(buffer[0, 0].style.foreground == white)
    }

    @Test func aRectFillTakesTheHalvesAPathOfItWould() {
        let shapes = [rect(0, 0, 2, 1.5), rect(0.4, 0.3, 1.2, 0.9), rect(2.6, 0.75, 0.3, 1),
                      rect(-5, -5, 6, 5.6), rect(1, 0, 0, 2)]
        for shape in shapes {
            let byPath = draw(width: 3, height: 2) { context, _ in
                context.fill(Path(shape), with: .color(red))
            }
            let byRect = draw(width: 3, height: 2) { context, _ in
                context.fill(shape, with: .color(red))
            }
            #expect(rows(byRect) == rows(byPath), "\(shape)")
            for y in 0..<2 {
                for x in 0..<3 { #expect(byRect[x, y] == byPath[x, y], "\(shape) at \(x), \(y)") }
            }
        }
    }

    @Test func aRectFillFollowsTheTransformTheClipAndTheOpacity() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.fill(rect(0, 0, 4, 1), with: .color(white))
            var inner = context
            inner.translateBy(x: 1, y: 0)
            inner.scaleBy(x: -1, y: 1)
            inner.fill(rect(0, 0, 1, 1), with: .color(red))
            inner = context
            inner.clip(to: Path(rect(2, 0, 1, 1)))
            inner.fill(rect(0, 0, 4, 1), with: .color(blue))
            inner = context
            inner.opacity = 0.5
            inner.fill(rect(3, 0, 1, 1), with: .color(black))
        }
        #expect(buffer[0, 0].style.background == red, "mirrored back onto the first cell")
        #expect(buffer[1, 0].style.background == white)
        #expect(buffer[2, 0].style.background == blue, "only where the clip lets it")
        #expect(buffer[3, 0].style.background == white.blended(with: black, amount: 0.5))
    }

    @Test func aRectFillOfManyColoursKeepsEachOne() {
        let columns = 64, rowsTall = 32
        let buffer = draw(width: columns, height: rowsTall) { context, _ in
            for y in 0..<(rowsTall * 2) {
                for x in 0..<columns {
                    context.fill(rect(Double(x), Double(y) / 2, 1, 0.5),
                                 with: .color(.rgb(UInt8(x * 4), UInt8(y * 4), 0)))
                }
            }
        }
        #expect(buffer[5, 3].style.foreground == .rgb(20, 24, 0), "the upper half of the fourth row")
        #expect(buffer[5, 3].style.background == .rgb(20, 28, 0))
        #expect(buffer[63, 31].style.background == .rgb(252, 252, 0))
    }
}

@Suite("Canvas text lands on whole cells")
@MainActor
struct CanvasTextTests {

    @Test func textOverAFillKeepsTheFillBeneathIt() {
        let style = Style(foreground: white, background: nil, bold: false, italic: false, underline: false)
        let buffer = draw(width: 6, height: 1, style: style) { context, _ in
            context.fill(Path(rect(0, 0, 6, 1)), with: .color(blue))
            context.draw(Text("Hi"), at: point(1, 0), anchor: .topLeading)
        }
        #expect(rows(buffer)[0] == " Hi   ")
        #expect(buffer[1, 0].style.background == blue)
        #expect(buffer[1, 0].style.foreground == white, "the canvas's own foreground")
    }

    @Test func textCoversTheStrokeBeneathIt() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.stroke(line(point(0, 0.5), point(3.9, 0.5)), with: .color(red))
            context.draw("ab", at: point(1, 0), anchor: .topLeading, with: .color(green))
        }
        #expect(rows(buffer)[0].dropFirst().prefix(2) == "ab")
        #expect(buffer[1, 0].style.foreground == green)
        #expect(dots(buffer[3, 0]) != nil)
    }

    @Test func aRunKeepsTheStyleItStates() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 4, 1)), with: .color(blue))
            context.draw(Text("x".fg(red).bg(green).bolded()), at: point(0, 0), anchor: .topLeading)
        }
        #expect(buffer[0, 0].style.foreground == red)
        #expect(buffer[0, 0].style.background == green)
        #expect(buffer[0, 0].style.bold)
    }

    @Test func anAnchorPlacesTheTextAroundThePoint() {
        let buffer = draw(width: 9, height: 3) { context, _ in
            context.draw("abc", at: point(4.5, 1.5))
            context.draw("z", at: point(9, 3), anchor: .bottomTrailing)
        }
        #expect(rows(buffer)[1] == "   abc   ")
        #expect(rows(buffer)[2] == "        z")
    }

    @Test func aWideCharacterTakesTwoCells() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 4, 1)), with: .color(blue))
            context.draw("世", at: point(1, 0), anchor: .topLeading)
        }
        #expect(buffer[1, 0].character == "世")
        #expect(buffer[2, 0].isContinuation)
        #expect(buffer[1, 0].style.background == blue)
        #expect(buffer[3, 0].style.background == blue)
    }

    @Test func aWideCharacterThatDoesNotFitIsNotDrawn() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.draw("a世", at: point(1, 0), anchor: .topLeading)
        }
        #expect(rows(buffer)[0] == " a ")
    }

    @Test func textOverHalfAWideCharacterRemovesTheOtherHalf() {
        let buffer = draw(width: 4, height: 1) { context, _ in
            context.draw("世", at: point(0, 0), anchor: .topLeading)
            context.draw("x", at: point(1, 0), anchor: .topLeading)
        }
        #expect(rows(buffer)[0] == " x  ")
        #expect(!buffer[1, 0].isContinuation)
    }

    @Test func textOffTheEdgeIsCutAtIt() {
        let buffer = draw(width: 4, height: 2) { context, _ in
            context.draw("Hello", at: point(-2, 0), anchor: .topLeading)
            context.draw("one\ntwo", at: point(2, 1), anchor: .topLeading)
        }
        #expect(rows(buffer)[0] == "llo ")
        #expect(rows(buffer)[1] == "  on")
    }
}

@Suite("Canvas state: transparency, clip, transform, opacity")
@MainActor
struct CanvasStateTests {

    @Test func cellsNothingDrawsInShowWhatLiesBeneath() {
        var beneath = CellBuffer(width: 3, height: 1)
        beneath.write("abc", x: 0, y: 0, style: Style(foreground: nil, background: green,
                                                       bold: false, italic: false, underline: false))
        let buffer = draw(width: 3, height: 1, over: beneath) { context, _ in
            context.fill(Path(rect(1, 0.5, 1, 0.5)), with: .color(red))
        }
        #expect(rows(buffer)[0] == "a▀c")
        #expect(buffer[1, 0].style.foreground == green, "the unfilled half shows the ground beneath")
        #expect(buffer[1, 0].style.background == red)
    }

    @Test func anOpaqueCanvasBlanksWhatItDoesNotDraw() {
        var beneath = CellBuffer(width: 2, height: 1)
        beneath.write("ab", x: 0, y: 0, style: .plain)
        let buffer = draw(width: 2, height: 1, opaque: true, over: beneath) { _, _ in }
        #expect(rows(buffer)[0] == "  ")
    }

    @Test func aClipLimitsWhatFollowsAndACopyKeepsItsOwn() {
        let buffer = draw(width: 6, height: 1) { context, _ in
            var clipped = context
            clipped.clip(to: Path(rect(0, 0, 2, 1)))
            clipped.fill(Path(rect(0, 0, 6, 1)), with: .color(red))
            clipped.stroke(line(point(0, 0.5), point(5.9, 0.5)), with: .color(white))
            clipped.draw("xyz", at: point(0, 0), anchor: .topLeading)
            context.draw("q", at: point(5, 0), anchor: .topLeading)
        }
        #expect(rows(buffer)[0] == "xy   q")
        #expect(buffer[1, 0].style.background == red)
        #expect(buffer[2, 0] == .empty)
    }

    @Test func clipsIntersect() {
        let buffer = draw(width: 6, height: 1) { context, _ in
            context.clip(to: Path(rect(0, 0, 4, 1)))
            context.clip(to: Path(rect(2, 0, 4, 1)))
            context.fill(Path(rect(0, 0, 6, 1)), with: .color(red))
        }
        #expect([0, 1, 4, 5].allSatisfy { buffer[$0, 0] == .empty })
        #expect(buffer[2, 0].style.background == red)
        #expect(buffer[3, 0].style.background == red)
    }

    @Test func translateAndScaleMoveWhatFollows() {
        let buffer = draw(width: 8, height: 2) { context, _ in
            context.translateBy(x: 2, y: 0)
            context.scaleBy(x: 2, y: 2)
            context.fill(Path(rect(0, 0, 1, 0.5)), with: .color(red))
            context.draw("t", at: point(2, 0), anchor: .topLeading)
        }
        #expect(buffer[1, 0] == .empty)
        #expect(buffer[2, 0].style.background == red)
        #expect(buffer[3, 0].style.background == red)
        #expect(buffer[4, 0] == .empty)
        #expect(buffer[6, 0].character == "t")
    }

    @Test func aTranslucentFillIsMixedWithTheFillBeneath() {
        let buffer = draw(width: 1, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 1, 1)), with: .color(black))
            context.opacity = 0.5
            context.fill(Path(rect(0, 0, 1, 1)), with: .color(white))
        }
        #expect(buffer[0, 0].style.background == black.blended(with: white, amount: 0.5))
    }

    @Test func aFaintFillOverTheTerminalsOwnGroundIsNotDrawn() {
        let buffer = draw(width: 2, height: 1) { context, _ in
            context.opacity = 0.25
            context.fill(Path(rect(0, 0, 1, 1)), with: .color(white))
            context.opacity = 0.75
            context.fill(Path(rect(1, 0, 1, 1)), with: .color(white))
        }
        #expect(buffer[0, 0] == .empty)
        #expect(buffer[1, 0].style.background == white)
    }

    @Test func aTranslucentStrokeIsMixedWithItsCellsGround() {
        let buffer = draw(width: 1, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 1, 1)), with: .color(black))
            context.opacity = 0.5
            context.stroke(line(point(0, 0.5), point(0.9, 0.5)), with: .color(white))
        }
        #expect(buffer[0, 0].style.foreground == black.blended(with: white, amount: 0.5))
    }

    @Test func aTranslucentHalfBlockStrokeMixesEachHalfOnce() {
        // A thick brush passes over a half many times, and a polyline's
        // vertex is on both its segments: each half is mixed once all the
        // same.
        let buffer = draw(width: 3, height: 2) { context, _ in
            context.fill(Path(rect(0, 0, 3, 2)), with: .color(black))
            context.resolution = .halfBlock
            context.opacity = 0.5
            var bend = Path()
            bend.addLines([point(0, 0.25), point(1.5, 0.25), point(1.5, 1.75)])
            context.stroke(bend, with: .color(white), lineWidth: 1)
        }
        let once = black.blended(with: white, amount: 0.5)
        #expect(buffer[1, 0].style.foreground == once || buffer[1, 0].style.background == once)
        for x in 0..<3 {
            for y in 0..<2 {
                let cell = buffer[x, y].style
                for colour in [cell.foreground, cell.background].compactMap({ $0 }) {
                    #expect(colour == black || colour == once, "(\(x), \(y)) was mixed more than once")
                }
            }
        }
    }

    @Test func translucentHalfCellsEachMixTheirOwnColour() {
        let buffer = draw(width: 2, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 2, 1)), with: .color(black))
            context.opacity = 0.5
            context.fillHalfCells(columns: 2, halfRows: 2) { column, _ in column == 0 ? white : red }
        }
        #expect(buffer[0, 0].style.background == black.blended(with: white, amount: 0.5))
        #expect(buffer[1, 0].style.background == black.blended(with: red, amount: 0.5))
    }

    @Test func aBlockOfCellsDrawsOverTheFillAndSkipsWhatItLeaves() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.fill(Path(rect(0, 0, 3, 1)), with: .color(blue))
            context.drawCells(columns: 3, rows: 1) { column, _ in
                column == 1 ? nil : CanvasCell(column == 0 ? "a" : "界", foreground: white)
            }
        }
        #expect(buffer[0, 0].character == "a")
        #expect(buffer[0, 0].style.background == blue, "a cell keeps the fill beneath it")
        #expect(buffer[1, 0].character == " ", "nil leaves the cell as it was")
        #expect(buffer[2, 0].character == " ", "a double-width character does not fit one cell")
    }

    @Test func aZeroSizeContextDrawsNothingAndDoesNotTrap() {
        let buffer = draw(width: 0, height: 0) { context, _ in
            context.fill(Path(rect(0, 0, 5, 5)), with: .color(red))
            context.stroke(line(point(0, 0), point(5, 5)), with: .color(red), lineWidth: 2)
            context.draw("hello", at: point(0, 0))
            context.clip(to: Path(rect(0, 0, 1, 1)))
            context.fill(Path(rect(0, 0, 5, 5)), with: .color(red))
        }
        #expect(buffer.width == 0)
    }

    @Test func degeneratePathsDrawNothingAndDoNotTrap() {
        let buffer = draw(width: 3, height: 1) { context, _ in
            context.fill(Path(), with: .color(red))
            context.stroke(Path(), with: .color(red))
            var lone = Path()
            lone.move(to: point(1, 0))
            context.stroke(lone, with: .color(red))
            context.fill(line(point(0, 0), point(2, 0)), with: .color(red))
            context.stroke(line(point(.nan, 0), point(.infinity, 1)), with: .color(red))
            context.draw("x", at: point(.nan, 0))
        }
        #expect(rows(buffer)[0] == "   ")
    }
}

// MARK: - In the graph

@MainActor
private final class Screen {
    let engine = FocusEngine()
    let graph = AttributeGraph()
    let update: (AttributeGraph) -> Void
    let width: Int
    let height: Int
    private(set) var buffer: CellBuffer

    init<V: TerminalView>(width: Int = 20, height: Int = 6, _ view: @escaping () -> V) {
        self.update = { graph in graph.update(from: view()) }
        self.width = width
        self.height = height
        self.buffer = CellBuffer(width: width, height: height)
        frame()
    }

    func frame() {
        engine.clearHandlers()
        GraphContext.$currentFocusEngine.withValue(engine) { update(graph) }
        draw()
    }

    func draw() {
        buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        engine.rebuildIndex(root: graph.root!)
    }
}

@MainActor
private final class Sizes {
    var seen: [CanvasSize] = []
}

@MainActor
@Observable
private final class Marker {
    var column = 0.0
}

@MainActor
private final class Runs {
    var count = 0
}

/// What a body counts and reads, outside the main actor as a body runs.
private final class BodyRuns {
    var count = 0
}

@Observable
private final class Position {
    var column = 0.0
}

@MainActor
@Observable
private final class Wide {
    var columns = 2
}

@MainActor
private final class Drags {
    var locations: [Point] = []
}

@Suite("Canvas in a layout")
@MainActor
struct CanvasLayoutTests {

    @Test func aCanvasFillsWhatItsStackLeaves() {
        let sizes = Sizes()
        let screen = Screen(width: 20, height: 6) {
            VStack(spacing: 0) {
                Text("title")
                Canvas { _, size in sizes.seen.append(size) }
                Text("footer")
            }
        }
        #expect(sizes.seen.last == CanvasSize(width: 20, height: 4))
        #expect(rows(screen.buffer)[5].hasPrefix("footer"))
    }

    @Test func aCanvasSitsBesideOthersInARow() {
        let sizes = Sizes()
        _ = Screen(width: 20, height: 3) {
            HStack(spacing: 0) {
                Text("left")
                Canvas { _, size in sizes.seen.append(size) }
            }
        }
        #expect(sizes.seen.last == CanvasSize(width: 16, height: 3))
    }

    @Test func aCanvasDrawsAtItsRectsOrigin() {
        let screen = Screen(width: 6, height: 2) {
            VStack(spacing: 0) {
                Text("ab")
                Canvas { context, _ in
                    context.draw("z", at: CanvasPoint(x: 1, y: 0), anchor: .topLeading)
                }
            }
        }
        #expect(screen.buffer[1, 1].character == "z")
    }

    @Test func aCanvasWithNoAreaDoesNotRunItsRenderer() {
        let sizes = Sizes()
        let screen = Screen(width: 0, height: 0) {
            Canvas { _, size in sizes.seen.append(size) }
        }
        #expect(sizes.seen.isEmpty)
        #expect(screen.buffer.width == 0)
    }

    @Test func aCanvasPushedPastItsStackDrawsNothingThere() {
        let screen = Screen(width: 10, height: 2) {
            VStack(spacing: 0) {
                Text("one")
                Text("two")
                Canvas { context, size in
                    context.fill(Path(CanvasRect(x: 0, y: 0, width: size.width, height: size.height)),
                                 with: .color(red))
                }
            }
        }
        #expect(rows(screen.buffer) == ["one       ", "two       "])
        #expect(screen.buffer[0, 1].style.background == nil)
    }

    @Test func aResolutionSetAroundTheCanvasReachesItsContext() {
        let screen = Screen(width: 3, height: 1) {
            Canvas { context, _ in
                context.stroke(line(CanvasPoint(x: 0, y: 0.25), CanvasPoint(x: 2.9, y: 0.25)),
                               with: .color(red))
            }
            .canvasResolution(.halfBlock)
        }
        #expect(screen.buffer[0, 0].character == "▀")
    }

    @Test func aCanvasTakesTheBackgroundAroundIt() {
        let screen = Screen(width: 3, height: 1) {
            Canvas { context, _ in
                context.draw("x", at: CanvasPoint(x: 0, y: 0), anchor: .topLeading)
            }
            .background(blue)
        }
        #expect(screen.buffer[0, 0].style.background == blue)
        #expect(screen.buffer[2, 0].style.background == blue)
    }

    @Test func whatTheRendererReadsDrawsItAgainWhenItChanges() {
        let marker = Marker()
        let screen = Screen(width: 6, height: 1) {
            Canvas { context, _ in
                context.draw("m", at: CanvasPoint(x: marker.column, y: 0), anchor: .topLeading)
            }
        }
        #expect(rows(screen.buffer)[0] == "m     ")
        #expect(!screen.graph.hasDirtyNodes)
        marker.column = 3
        #expect(screen.graph.hasDirtyNodes, "the renderer's read was tracked")
        #expect(screen.graph.drain())
        screen.draw()
        #expect(rows(screen.buffer)[0] == "   m  ")
    }

    @Test func aFrameDrawnForSomethingElseShowsWhatTheCanvasLastDrew() {
        let runs = Runs()
        let screen = Screen(width: 6, height: 1) {
            Canvas { context, _ in
                runs.count += 1
                context.draw("m", at: .zero, anchor: .topLeading)
            }
        }
        #expect(runs.count == 1)
        screen.draw()
        screen.draw()
        #expect(runs.count == 1, "the renderer ran for a frame with nothing new to show")
        #expect(rows(screen.buffer)[0] == "m     ", "the frame still shows the drawing")
        screen.frame()
        #expect(runs.count == 2, "a canvas built again draws again")
    }

    @Test func anObservedChangeRunsTheRendererAndNoBody() {
        let marker = Position()
        let bodies = BodyRuns()
        struct Holder: TerminalView {
            let marker: Position
            let bodies: BodyRuns
            var body: some TerminalView {
                bodies.count += 1
                return Canvas { context, _ in
                    context.draw("m", at: CanvasPoint(x: marker.column, y: 0), anchor: .topLeading)
                }
            }
        }
        let screen = Screen(width: 6, height: 1) { Holder(marker: marker, bodies: bodies) }
        #expect(bodies.count == 1)
        marker.column = 2
        #expect(screen.graph.drain(), "the change asks for a frame")
        screen.draw()
        #expect(rows(screen.buffer)[0] == "  m   ")
        #expect(bodies.count == 1, "only the renderer ran again")
    }

    @Test func aCanvasGivenAnotherSizeDrawsAgain() {
        let sizes = Sizes()
        let wide = Wide()
        let screen = Screen(width: 10, height: 1) {
            HStack(spacing: 0) {
                Text(String(repeating: "x", count: wide.columns))
                Canvas { _, size in sizes.seen.append(size) }
            }
        }
        wide.columns = 4
        screen.frame()
        #expect(sizes.seen.map(\.width) == [8, 6])
    }

    @Test func aDragOnACanvasReportsItsOwnCells() {
        let drags = Drags()
        let screen = Screen(width: 20, height: 6) {
            VStack(spacing: 0) {
                Text("above")
                Canvas { _, _ in }
                    .gesture(DragGesture().onChanged { drags.locations.append($0.location) })
            }
        }
        screen.engine.handlePress(PointerPress(x: 2, y: 2), root: screen.graph.root)
        screen.frame()
        screen.engine.continueDrag(x: 7, y: 4)
        screen.frame()
        screen.engine.endDrag(x: 7, y: 4)
        #expect(drags.locations == [Point(x: 7, y: 3)])
    }

    @Test func aClickOnACanvasHitsIt() {
        let clicks = Drags()
        let screen = Screen(width: 10, height: 4) {
            Canvas { _, _ in }
                .onClick { x, y in clicks.locations.append(Point(x: x, y: y)) }
                .padding(1)
        }
        screen.engine.handlePress(PointerPress(x: 4, y: 2), root: screen.graph.root)
        #expect(clicks.locations == [Point(x: 3, y: 1)])
    }
}
