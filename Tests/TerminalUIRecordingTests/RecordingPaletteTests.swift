import Testing
import TerminalUI
@testable import TerminalUIRecording

// The colours a picture is drawn in, and how each colour a recording can
// hold resolves to one.

@Suite("Recording palettes")
struct RecordingPaletteTests {

    private func hexes(_ palette: RecordingPalette) -> String {
        palette.ansi.map(\.hexString).joined(separator: " ")
    }

    @Test func catppuccinMochaIsTheOfficialTerminalScheme() {
        // catppuccin/palette v1.8.0, palette.json, mocha: text, base, and
        // ansiColors normal 0–7 then bright 8–15.
        let mocha = RecordingPalette.catppuccinMocha
        #expect(mocha.name == "catppuccin-mocha")
        #expect(mocha.foreground.hexString == "#cdd6f4")
        #expect(mocha.background.hexString == "#1e1e2e")
        #expect(hexes(mocha) == "#45475a #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #a6adc8 "
                + "#585b70 #f37799 #89d88b #ebd391 #74a8fc #f2aede #6bd7ca #bac2de")
    }

    @Test func xtermIsTheFrameworksNominalTable() {
        let xterm = RecordingPalette.xterm
        #expect(xterm.name == "xterm")
        for slot in 0..<RecordingPalette.ansiSlots {
            let nominal = Color.ansi256(UInt8(slot)).nominalRGB
            #expect(xterm.ansi[slot] == RGB(nominal?.red ?? 0, nominal?.green ?? 0, nominal?.blue ?? 0))
        }
        #expect(hexes(xterm) == "#000000 #800000 #008000 #808000 #000080 #800080 #008080 #c0c0c0 "
                + "#808080 #ff0000 #00ff00 #ffff00 #0000ff #ff00ff #00ffff #ffffff")
        #expect(xterm.foreground.hexString == "#c0c0c0")
        #expect(xterm.background.hexString == "#000000")
    }

    @Test func palettesAreFoundByName() {
        #expect(RecordingPalette.named("catppuccin-mocha") == .catppuccinMocha)
        #expect(RecordingPalette.named("xterm") == .xterm)
        #expect(RecordingPalette.named("solarized") == nil)
    }

    @Test func theTerminalsOwnColoursAreThePalettesOrTheWindowBackground() {
        let mocha = RecordingPalette.catppuccinMocha
        #expect(mocha.foreground(nil) == mocha.foreground)
        #expect(mocha.foreground(.default) == mocha.foreground)
        #expect(mocha.background(nil, windowBackground: nil) == mocha.background)
        #expect(mocha.background(.default, windowBackground: nil) == mocha.background)
        let window = Color.rgb(0x10, 0x20, 0x30)
        #expect(mocha.background(nil, windowBackground: window) == RGB(0x10, 0x20, 0x30))
        #expect(mocha.background(.default, windowBackground: window) == RGB(0x10, 0x20, 0x30))
        // A named window background is the palette's, like any named colour.
        #expect(mocha.defaultBackground(windowBackground: .blue) == RGB(hex: 0x89B4FA))
        #expect(mocha.defaultBackground(windowBackground: .default) == mocha.background)
        // A colour the cell states wins over the window's.
        #expect(mocha.background(.red, windowBackground: window) == RGB(hex: 0xF38BA8))
    }

    @Test func everyColourResolvesAsTheRulesSay() {
        let mocha = RecordingPalette.catppuccinMocha
        // The 16 names and ansi256(0…15) are the palette's slots.
        for (slot, entry) in Color.recordedNames.enumerated() {
            #expect(mocha.rgb(entry.color) == mocha.ansi[slot], "\(entry.name)")
            #expect(mocha.rgb(.ansi256(UInt8(slot))) == mocha.ansi[slot], "idx:\(slot)")
        }
        // 16…255 are xterm's cube and grey ramp, whatever the palette.
        for index in 16...255 {
            let nominal = Color.ansi256(UInt8(index)).nominalRGB
            let expected = RGB(nominal?.red ?? 0, nominal?.green ?? 0, nominal?.blue ?? 0)
            #expect(mocha.rgb(.ansi256(UInt8(index))) == expected)
            #expect(RecordingPalette.xterm.rgb(.ansi256(UInt8(index))) == expected)
        }
        #expect(mocha.rgb(.ansi256(16))?.hexString == "#000000")
        #expect(mocha.rgb(.ansi256(196))?.hexString == "#ff0000")
        #expect(mocha.rgb(.ansi256(232))?.hexString == "#080808")
        #expect(mocha.rgb(.ansi256(255))?.hexString == "#eeeeee")
        #expect(mocha.rgb(.rgb(1, 2, 3)) == RGB(1, 2, 3))
        #expect(mocha.rgb(.default) == nil)
    }

    @Test func hexIsLowercaseAndPadded() {
        #expect(RGB(0, 0x0A, 0xFF).hexString == "#000aff")
        #expect(RGB(hex: 0x0A0B0C) == RGB(0x0A, 0x0B, 0x0C))
    }
}

@Suite("Cell metrics")
struct CellMetricsTests {

    @Test func aCellIsTheFontsAdvanceByItsLineHeight() {
        let docs = CellMetrics(fontSize: 15, advance: CellMetrics.jetBrainsMonoAdvance)
        #expect(docs.cellWidth == 9 && docs.cellHeight == 18)
        let retina = CellMetrics(fontSize: 15, advance: CellMetrics.jetBrainsMonoAdvance, scale: 2)
        #expect(retina.pixelFontSize == 30)
        #expect(retina.cellWidth == 18 && retina.cellHeight == 36)
    }

    @Test func eachScaleRoundsFromTheExactProduct() {
        // 13 px: 7.8 × 15.6 rounds to 8 × 16; at scale 2, 15.6 × 31.2 rounds
        // to 16 × 31 — not 16 × 32, which doubling the 1× cell would give.
        let small = CellMetrics(fontSize: 13, advance: CellMetrics.jetBrainsMonoAdvance)
        #expect(small.cellWidth == 8 && small.cellHeight == 16)
        let double = CellMetrics(fontSize: 13, advance: CellMetrics.jetBrainsMonoAdvance, scale: 2)
        #expect(double.cellWidth == 16 && double.cellHeight == 31)
    }

    @Test func aProportionRoundsHalfUp() {
        #expect(Proportion(1, 2).scaled(1) == 1)
        #expect(Proportion(1, 2).scaled(3) == 2)
        #expect(Proportion(1, 3).scaled(1) == 0)
        #expect(Proportion(1229, 2048).scaled(16) == 10)
        #expect(CellMetrics(fontSize: 14, lineHeight: Proportion(3, 2), advance: Proportion(1, 2)).cellHeight == 21)
    }
}
