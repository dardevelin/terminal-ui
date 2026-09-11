import Testing
@testable import TerminalUI

// Blending is the primitive under every gradient device a terminal UI uses
// for identity — a wordmark, a diagonal field, a row of progress triangles.
//
// It interpolates in Oklab rather than sRGB because equal numeric steps in
// sRGB are not equal visual steps: the classic blue-to-yellow ramp goes grey
// and dead in the middle. The midpoint tests below are what pin that, and
// they are the reason the extra transform is worth its cost.

@MainActor
@Suite struct ColorBlendingTests {

    private func rgb(_ color: Color) -> (Int, Int, Int)? {
        guard let c = color.nominalRGB else { return nil }
        return (Int(c.red), Int(c.green), Int(c.blue))
    }

    // MARK: - Nominal resolution

    @Test func truecolorResolvesToItself() {
        #expect(rgb(.rgb(12, 34, 56))! == (12, 34, 56))
    }

    @Test func namedColorsResolveToTheXtermDefaults() {
        // Nominal, not authoritative — the terminal may paint `.red`
        // however it likes. These are the values the downgrade tables
        // already search in the other direction.
        #expect(rgb(.brightRed)! == (255, 0, 0))
        #expect(rgb(.black)! == (0, 0, 0))
        #expect(rgb(.brightWhite)! == (255, 255, 255))
    }

    @Test func ansi256CubeAndGrayscaleResolve() {
        // 16 is the cube's origin; 231 its far corner; 232+ the gray ramp.
        #expect(rgb(.ansi256(16))! == (0, 0, 0))
        #expect(rgb(.ansi256(231))! == (255, 255, 255))
        #expect(rgb(.ansi256(232))! == (8, 8, 8))
    }

    /// `.default` means "whatever the terminal uses when no color is set",
    /// which this process cannot know — so it has no triple, and blending
    /// has to cope with that rather than inventing black.
    @Test func terminalDefaultHasNoNominalValue() {
        #expect(Color.default.nominalRGB == nil)
    }

    // MARK: - Blending

    @Test func blendEndpointsAreExact() {
        let start = Color.rgb(10, 20, 30)
        let end = Color.rgb(200, 100, 50)
        #expect(rgb(start.blended(with: end, amount: 0))! == (10, 20, 30))
        #expect(rgb(start.blended(with: end, amount: 1))! == (200, 100, 50))
    }

    @Test func amountIsClampedRatherThanExtrapolated() {
        let start = Color.rgb(10, 20, 30)
        let end = Color.rgb(200, 100, 50)
        #expect(rgb(start.blended(with: end, amount: -5))! == (10, 20, 30))
        #expect(rgb(start.blended(with: end, amount: 5))! == (200, 100, 50))
    }

    /// The whole reason for Oklab. Blue→yellow through sRGB passes through a
    /// desaturated grey; a perceptual blend keeps the midpoint colourful.
    /// Asserted as "not grey" rather than an exact triple so the test pins
    /// the property, not the arithmetic.
    @Test func midpointOfOpposingHuesStaysColourful() {
        let mid = Color.rgb(0, 0, 255).blended(with: .rgb(255, 255, 0), amount: 0.5)
        let (r, g, b) = rgb(mid)!
        let spread = max(r, max(g, b)) - min(r, min(g, b))
        #expect(spread > 40, "midpoint went grey — that is the sRGB failure Oklab exists to avoid")
    }

    /// Black→white halfway lands near sRGB 99, and that number is the point.
    /// Averaging sRGB channels would give 128; averaging linear light would
    /// give about 188. Oklab puts the perceptual centre lower than both,
    /// because sRGB 128 is already Oklab L≈0.60 rather than 0.5 — mid-grey on
    /// screen is lighter than half-way between black and white to the eye.
    @Test func midpointOfBlackAndWhiteIsPerceptuallyCentred() {
        let mid = Color.rgb(0, 0, 0).blended(with: .rgb(255, 255, 255), amount: 0.5)
        let (r, g, b) = rgb(mid)!
        #expect(r == g && g == b, "a neutral blend must stay neutral")
        #expect(abs(r - 99) <= 2, "midpoint \(r) is not Oklab's perceptual centre")
    }

    @Test func blendingFromTerminalDefaultFallsBackToTheNearerEnd() {
        #expect(Color.default.blended(with: .rgb(1, 2, 3), amount: 0.2).nominalRGB == nil)
        #expect(rgb(Color.default.blended(with: .rgb(1, 2, 3), amount: 0.8))! == (1, 2, 3))
    }

    @Test func blendingAlwaysYieldsAnExactColour() {
        // A blend between two palette slots is not itself a palette slot.
        let blended = Color.red.blended(with: .blue, amount: 0.5)
        guard case .rgb = blended else {
            Issue.record("expected an exact .rgb result, got \(blended)")
            return
        }
    }

    // MARK: - Ramps

    @Test func rampHitsBothEndpointsExactly() {
        let ramp = Color.rgb(0, 0, 0).ramp(to: .rgb(255, 255, 255), count: 5)
        #expect(ramp.count == 5)
        #expect(rgb(ramp.first!)! == (0, 0, 0))
        #expect(rgb(ramp.last!)! == (255, 255, 255))
    }

    @Test func rampIsMonotonicInLightness() {
        let ramp = Color.rgb(0, 0, 0).ramp(to: .rgb(255, 255, 255), count: 8)
        let reds = ramp.map { rgb($0)!.0 }
        #expect(reds == reds.sorted(), "a black→white ramp must not double back")
    }

    @Test func degenerateRampCountsAreHandled() {
        #expect(Color.red.ramp(to: .blue, count: 0).isEmpty)
        #expect(Color.red.ramp(to: .blue, count: 1).count == 1)
    }

    @Test func multiStopRampPassesThroughItsMiddleStop() {
        let stops: [Color] = [.rgb(255, 0, 0), .rgb(0, 255, 0), .rgb(0, 0, 255)]
        let ramp = Color.ramp(through: stops, count: 9)
        #expect(ramp.count == 9)
        #expect(rgb(ramp[0])! == (255, 0, 0))
        #expect(rgb(ramp[8])! == (0, 0, 255))
        // Index 4 is the shared boundary between the two segments.
        #expect(rgb(ramp[4])! == (0, 255, 0))
    }

    @Test func singleStopRampRepeatsThatStop() {
        let ramp = Color.ramp(through: [.rgb(7, 7, 7)], count: 3)
        #expect(ramp.count == 3)
        #expect(ramp.allSatisfy { rgb($0)! == (7, 7, 7) })
    }

    // MARK: - Text gradient

    @Test func gradientEmitsOneSpanPerCharacter() {
        let text = Text.gradient("abcd", from: .rgb(0, 0, 0), to: .rgb(255, 255, 255))
        #expect(text.spans.count == 4)
        #expect(text.spans.map(\.text).joined() == "abcd")
        #expect(text.spans.first?.foreground == .rgb(0, 0, 0))
        #expect(text.spans.last?.foreground == .rgb(255, 255, 255))
    }

    /// Swift's `Character` is a grapheme cluster, so a multi-scalar emoji is
    /// one step of the ramp however many cells it takes. The ramp follows the
    /// text, not the grid.
    @Test func gradientStepsPerGraphemeNotPerScalar() {
        let text = Text.gradient("a👨‍👩‍👧b", from: .rgb(0, 0, 0), to: .rgb(255, 255, 255))
        #expect(text.spans.count == 3)
        #expect(text.spans[1].text == "👨‍👩‍👧")
    }

    @Test func gradientOfASingleCharacterTakesTheStartColour() {
        let text = Text.gradient("x", from: .rgb(9, 9, 9), to: .rgb(200, 200, 200))
        #expect(text.spans.count == 1)
        #expect(text.spans[0].foreground == .rgb(9, 9, 9))
    }

    @Test func gradientOfEmptyTextIsEmpty() {
        #expect(Text.gradient("", from: .red, to: .blue).content.isEmpty)
    }

    @Test func gradientWithOneStopPaintsASingleColour() {
        let text = Text.gradient("abc", through: [.rgb(5, 6, 7)])
        #expect(text.spans.count == 1)
        #expect(text.spans[0].foreground == .rgb(5, 6, 7))
    }

    /// The rendered cells must actually carry the ramp — a gradient that only
    /// exists in the span list is not a gradient.
    @Test func gradientReachesTheRenderedCells() {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 4, height: 1)
        let rect = Rect(x: 0, y: 0, width: 4, height: 1)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: Text.gradient("abcd", from: .rgb(0, 0, 0), to: .rgb(255, 255, 255)))
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        #expect(buffer[0, 0].style.foreground == .rgb(0, 0, 0))
        #expect(buffer[3, 0].style.foreground == .rgb(255, 255, 255))
        #expect(buffer[1, 0].style.foreground != buffer[2, 0].style.foreground)
    }
}
