import Foundation
import Testing
@testable import TerminalUI

// Sub-cell glyph atlas. Maps each glyph-class case to the
// canonical Unicode block-element character. Existing BrailleCanvas
// already does the braille bit-encoding (`Sources/TerminalUI/Views/
// Charts/BrailleCanvas.swift::brailleChar`); the primitive formalises
// that pattern AND extends it to quadrants, eighths, halves, shades
// so any sub-cell shape can be rendered through one type.
//
// Quadrant glyphs (Unicode "Block Elements" U+2580..U+259F) are the
// load-bearing cases — Avatar circle clip uses them at the perimeter
// for sub-cell precision without going all the way to braille
// resolution (which would lose color fidelity by treating fg/bg as
// dot fg/bg).

@Suite("SubCellGlyph atlas — glyph-class cases map to canonical block-element chars")
@MainActor
struct SubCellGlyphTests {

    @Test("full block maps to U+2588 █")
    func fullBlock() {
        let glyph = SubCellGlyph.full
        #expect(glyph.character == "█")
    }

    @Test("half-top maps to U+2580 ▀")
    func halfTop() {
        let glyph = SubCellGlyph.halfTop
        #expect(glyph.character == "▀")
    }

    @Test("half-bottom maps to U+2584 ▄")
    func halfBottom() {
        let glyph = SubCellGlyph.halfBottom
        #expect(glyph.character == "▄")
    }

    @Test("half-left maps to U+258C ▌")
    func halfLeft() {
        let glyph = SubCellGlyph.halfLeft
        #expect(glyph.character == "▌")
    }

    @Test("half-right maps to U+2590 ▐")
    func halfRight() {
        let glyph = SubCellGlyph.halfRight
        #expect(glyph.character == "▐")
    }

    // MARK: - Quadrant masks

    @Test("quadrant top-left only maps to U+2598 ▘")
    func quadrantTopLeft() {
        let glyph = SubCellGlyph.quadrant(.topLeft)
        #expect(glyph.character == "▘")
    }

    @Test("quadrant top-right only maps to U+259D ▝")
    func quadrantTopRight() {
        let glyph = SubCellGlyph.quadrant(.topRight)
        #expect(glyph.character == "▝")
    }

    @Test("quadrant diagonal (top-left + bottom-right) maps to U+259A ▚")
    func quadrantDiagonal() {
        let glyph = SubCellGlyph.quadrant([.topLeft, .bottomRight])
        #expect(glyph.character == "▚")
    }

    @Test("quadrant all four maps to U+2588 █ (full block)")
    func quadrantAllFour() {
        let glyph = SubCellGlyph.quadrant([.topLeft, .topRight, .bottomLeft, .bottomRight])
        #expect(glyph.character == "█")
    }

    @Test("quadrant empty maps to space")
    func quadrantEmpty() {
        let glyph = SubCellGlyph.quadrant([])
        #expect(glyph.character == " ")
    }

    // MARK: - Eighth fills (vertical from bottom)

    @Test("eighth one-eighth from bottom maps to U+2581 ▁")
    func eighthOneEighth() {
        let glyph = SubCellGlyph.eighthVertical(.oneEighth)
        #expect(glyph.character == "▁")
    }

    @Test("eighth half (four-eighths) from bottom maps to U+2584 ▄")
    func eighthHalf() {
        let glyph = SubCellGlyph.eighthVertical(.fourEighths)
        #expect(glyph.character == "▄")
    }

    @Test("eighth full maps to U+2588 █")
    func eighthFull() {
        let glyph = SubCellGlyph.eighthVertical(.eightEighths)
        #expect(glyph.character == "█")
    }

    // MARK: - Shade levels

    @Test("shade light maps to U+2591 ░")
    func shadeLight() {
        let glyph = SubCellGlyph.shade(.light)
        #expect(glyph.character == "░")
    }

    @Test("shade medium maps to U+2592 ▒")
    func shadeMedium() {
        let glyph = SubCellGlyph.shade(.medium)
        #expect(glyph.character == "▒")
    }

    @Test("shade dark maps to U+2593 ▓")
    func shadeDark() {
        let glyph = SubCellGlyph.shade(.dark)
        #expect(glyph.character == "▓")
    }

    // MARK: - Braille dot patterns (delegating to BrailleCanvas's encoding shape)

    @Test("braille empty maps to U+2800 ⠀ (blank)")
    func brailleEmpty() {
        let glyph = SubCellGlyph.braille([])
        #expect(glyph.character.unicodeScalars.first?.value == 0x2800)
    }

    @Test("braille dot 1 maps to U+2801 ⠁")
    func brailleDot1() {
        let glyph = SubCellGlyph.braille(.dot1)
        #expect(glyph.character.unicodeScalars.first?.value == 0x2801)
    }

    @Test("braille all 8 dots maps to U+28FF ⣿")
    func brailleAllDots() {
        let glyph = SubCellGlyph.braille([.dot1, .dot2, .dot3, .dot4, .dot5, .dot6, .dot7, .dot8])
        #expect(glyph.character.unicodeScalars.first?.value == 0x28FF)
    }
}
