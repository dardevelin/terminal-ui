import Testing
@testable import TerminalInk

// `nominalRGB` is the forward direction of the palette tables `rgbToAnsi256`
// and `ansi256ToNamed` already searched backwards. It exists so callers doing
// arithmetic on colour — blending a ramp, deriving a shade — have a defined
// starting point for a value that is otherwise just a palette slot.
//
// The round-trip tests are the ones that matter: forward and reverse read the
// same tables, so if they ever disagree one of them has been edited alone.

@Suite("InkColor — nominal sRGB resolution")
struct NominalRGBTests {

    @Test("truecolor resolves to itself")
    func truecolor() {
        let rgb = InkColor.rgb(12, 34, 56).nominalRGB
        #expect(rgb?.red == 12 && rgb?.green == 34 && rgb?.blue == 56)
    }

    @Test("the terminal default has no value to resolve to")
    func terminalDefault() {
        // It means "whatever the terminal uses when no colour is set", which
        // no table can answer.
        #expect(InkColor.default.nominalRGB == nil)
    }

    @Test("named slots resolve to xterm's defaults")
    func named() {
        let black = InkColor.named(.black).nominalRGB
        #expect(black?.red == 0 && black?.green == 0 && black?.blue == 0)
        let brightWhite = InkColor.named(.brightWhite).nominalRGB
        #expect(brightWhite?.red == 255 && brightWhite?.green == 255 && brightWhite?.blue == 255)
        // Normal red is the dim half of the pair — 128, not 255. Getting this
        // backwards is the classic palette mistake.
        let red = InkColor.named(.red).nominalRGB
        #expect(red?.red == 128 && red?.green == 0 && red?.blue == 0)
    }

    @Test("the 6×6×6 cube resolves by its step table")
    func cube() {
        // 16 is the cube origin, 231 its far corner. Steps are the xterm
        // sequence 0/95/135/175/215/255, not an even split.
        let origin = InkColor.ansi256(16).nominalRGB
        #expect(origin?.red == 0 && origin?.green == 0 && origin?.blue == 0)
        let corner = InkColor.ansi256(231).nominalRGB
        #expect(corner?.red == 255 && corner?.green == 255 && corner?.blue == 255)
        // 16 + 36*1 = 52 is one red step in, green and blue still at zero.
        let oneRedStep = InkColor.ansi256(52).nominalRGB
        #expect(oneRedStep?.red == 95 && oneRedStep?.green == 0 && oneRedStep?.blue == 0)
    }

    @Test("the grayscale ramp resolves to 8 + i*10")
    func grayscale() {
        let first = InkColor.ansi256(232).nominalRGB
        #expect(first?.red == 8 && first?.green == 8 && first?.blue == 8)
        let last = InkColor.ansi256(255).nominalRGB
        #expect(last?.red == 238 && last?.green == 238 && last?.blue == 238)
    }

    @Test("the first sixteen slots agree with the named colors")
    func lowSlotsMatchNamed() {
        // Slots 0-15 and the named colors are the same sixteen entries; the
        // two paths must not drift.
        for (index, name) in NamedColor.allCases.enumerated() {
            let bySlot = InkColor.ansi256(UInt8(index)).nominalRGB
            let byName = InkColor.named(name).nominalRGB
            #expect(bySlot?.red == byName?.red, "slot \(index) vs \(name)")
            #expect(bySlot?.green == byName?.green, "slot \(index) vs \(name)")
            #expect(bySlot?.blue == byName?.blue, "slot \(index) vs \(name)")
        }
    }

    @Test("resolving a cube slot and collapsing it back returns the same slot")
    func roundTripsThroughTheCube() {
        // Forward and reverse read the same tables; a mismatch means one was
        // edited without the other.
        for slot in stride(from: 16, through: 231, by: 17) {
            let rgb = InkColor.ansi256(UInt8(slot)).nominalRGB!
            let back = ColorCapability.ansi256.downgrade(.rgb(rgb.red, rgb.green, rgb.blue))
            #expect(back == .ansi256(UInt8(slot)), "slot \(slot) did not survive the round trip")
        }
    }
}
