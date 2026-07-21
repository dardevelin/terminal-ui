import Foundation
import Testing
@testable import TerminalUI

// Slider, Stepper and Gauge share one value model, which is why they ship
// together: clamping, degenerate ranges and numeric formatting are the same
// problem three times over, and three separate implementations would drift.
//
// The rules pinned here:
//
//   * A value outside the bounds is **corrected, not rejected** — a control
//     that refuses to render because its model is briefly out of range is
//     worse than one that shows the nearest legal value.
//   * Inverted bounds are a programmer error, not a user input. They warn and
//     disable rather than crashing or looping.
//   * A zero-width range is legal and inert: `5...5` has exactly one legal
//     value, so the control is full and cannot move.

@Suite("Bounded value — shared model")
struct BoundedValueModelTests {

    @Test("a value inside the bounds is its own fraction")
    func fractionInsideBounds() {
        let scale = BoundedValueScale(bounds: 0.0...10.0)
        #expect(scale.fraction(of: 2.5) == 0.25)
    }

    @Test("values outside the bounds are clamped, not rejected", arguments: [
        (-5.0, 0.0), (99.0, 1.0),
    ])
    func clampsOutOfRange(input: Double, expected: Double) {
        let scale = BoundedValueScale(bounds: 0.0...10.0)
        #expect(scale.fraction(of: input) == expected)
    }

    @Test("clamp returns the nearest legal value")
    func clampReturnsNearestLegalValue() {
        let scale = BoundedValueScale(bounds: 10.0...20.0)
        #expect(scale.clamp(3.0) == 10.0)
        #expect(scale.clamp(30.0) == 20.0)
        #expect(scale.clamp(15.0) == 15.0)
    }

    // A zero-width range has exactly one legal value. Reporting fraction 1.0
    // (rather than dividing by zero) makes the control render full and inert.
    @Test("a zero-width range is full, not a division by zero")
    func zeroWidthRangeIsFull() {
        let scale = BoundedValueScale(bounds: 5.0...5.0)
        #expect(scale.isDegenerate)
        #expect(scale.fraction(of: 5.0) == 1.0)
        #expect(scale.clamp(99.0) == 5.0)
    }

    @Test("inverted bounds are reported as invalid rather than normalised")
    func invertedBoundsAreInvalid() {
        let scale = BoundedValueScale(invertedLower: 10.0, upper: 0.0)
        #expect(!scale.isValid)
        // Still answerable — a disabled control must render something.
        #expect(scale.fraction(of: 5.0) == 0.0)
    }

    @Test("a nil step is one percent of the range")
    func nilStepIsOnePercent() {
        let scale = BoundedValueScale(bounds: 0.0...200.0)
        #expect(scale.resolvedStep(nil) == 2.0)
    }

    @Test("a step larger than the range clamps rather than overshooting")
    func oversizedStepClamps() {
        let scale = BoundedValueScale(bounds: 0.0...10.0)
        #expect(scale.clamp(0.0 + 999.0) == 10.0)
    }

    // One formatter for all three components, so a slider and a gauge showing
    // the same number never disagree about how it looks.
    //
    // `%g` counts *significant* digits, not decimals, so it silently truncates
    // (12.5 → "12") and flips to scientific notation past three digits
    // (1234.5 → "1.2e+03"). A Slider over 0...5000 has a default step of 50,
    // so ordinary use would have shown the user "1.2e+03".
    @Test("numeric formatting is shared and trims noise", arguments: [
        (0.5, "0.5"), (12.0, "12"), (0.6234, "0.62"), (100.0, "100"),
        (12.5, "12.5"), (123.5, "123.5"), (1234.5, "1234.5"), (5000.0, "5000"),
    ])
    func sharedNumericFormatting(value: Double, expected: String) {
        #expect(BoundedValueScale.format(value) == expected)
    }

    @Test("large values never render in scientific notation")
    func noScientificNotation() {
        for value in [1234.5, 99999.0, 250_000.75] {
            let text = BoundedValueScale.format(value)
            #expect(!text.contains("e"), "\(value) formatted as \(text)")
        }
    }
}
