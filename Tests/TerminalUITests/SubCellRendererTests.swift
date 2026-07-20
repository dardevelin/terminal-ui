import Foundation
import Testing
@testable import TerminalUI

// HYP-298 — SubCellRenderer maps a 2×4 alpha pattern (matching braille
// resolution) to the best-fitting SubCellGlyph + colors. Used by
// shape-clip modifiers to convert alpha masks into terminal cells.
//
// The renderer doesn't pick "the" perfect glyph for every input — it
// picks the closest of a small atlas (full/halves/quadrants/eighths/
// braille/shade) for the input pattern. Quadrant fallback covers 95%
// of cases (4 sub-pixels per cell); braille is reserved for the
// finest precision; halves/full are degenerate cases that quadrants
// also covers.

@Suite("SubCellRenderer — alpha pattern → glyph + colors")
@MainActor
struct SubCellRendererTests {

    @Test("uniform full alpha pattern produces full block")
    func uniformFullProducesFull() {
        let pattern = AlphaPattern(uniformValue: 1.0)
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(0, 0, 255),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "█")
        #expect(cell.foreground == .rgb(0, 0, 255))
    }

    @Test("uniform zero alpha produces space (transparent)")
    func uniformZeroProducesSpace() {
        let pattern = AlphaPattern(uniformValue: 0.0)
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(0, 0, 255),
            background: .rgb(0, 0, 0)
        )
        // Space-glyph + alpha 0 means "this cell is transparent."
        // The renderer signals this via `cell.alpha == 0.0`, even
        // if the glyph happens to be a space.
        #expect(cell.alpha == 0.0)
    }

    @Test("top half opaque + bottom half transparent produces half-top glyph")
    func topHalfProducesHalfTop() {
        // 2×4 pattern: rows 0-1 opaque (alpha=1), rows 2-3 transparent (alpha=0).
        // Half-top maps to the upper half of the cell — top 4 sub-rows out of 8?
        // Conservative check: ALL top sub-pixels opaque AND ALL bottom transparent.
        var pattern = AlphaPattern(uniformValue: 0.0)
        for y in 0..<2 {     // top 2 rows of the 4-row braille grid
            for x in 0..<2 {
                pattern[x, y] = 1.0
            }
        }
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(0, 255, 0),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "▀")
    }

    @Test("bottom half opaque produces half-bottom glyph")
    func bottomHalfProducesHalfBottom() {
        var pattern = AlphaPattern(uniformValue: 0.0)
        for y in 2..<4 {
            for x in 0..<2 {
                pattern[x, y] = 1.0
            }
        }
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(0, 255, 0),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "▄")
    }

    @Test("top-left quadrant only produces ▘ quadrant glyph")
    func topLeftQuadrantProducesGlyph() {
        var pattern = AlphaPattern(uniformValue: 0.0)
        // Top-left quadrant = top-left 1×2 of the 2×4 braille grid.
        pattern[0, 0] = 1.0
        pattern[0, 1] = 1.0
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(255, 255, 255),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "▘")
    }

    @Test("diagonal quadrants produce ▚ glyph")
    func diagonalQuadrantsProduceGlyph() {
        var pattern = AlphaPattern(uniformValue: 0.0)
        // Top-left quadrant + bottom-right quadrant.
        pattern[0, 0] = 1.0; pattern[0, 1] = 1.0
        pattern[1, 2] = 1.0; pattern[1, 3] = 1.0
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(255, 255, 255),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "▚")
    }

    @Test("shade level 0.5 produces medium shade ▒")
    func shadeMediumLevel() {
        let pattern = AlphaPattern(uniformValue: 0.5)
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(255, 255, 255),
            background: .rgb(0, 0, 0)
        )
        // Uniform partial alpha doesn't fit any quadrant/half cleanly,
        // so the renderer falls back to a shade glyph.
        #expect(cell.glyph.character == "▒")
    }

    @Test("shade level 0.25 produces light shade ░")
    func shadeLightLevel() {
        let pattern = AlphaPattern(uniformValue: 0.25)
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(255, 255, 255),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "░")
    }

    @Test("shade level 0.75 produces dark shade ▓")
    func shadeDarkLevel() {
        let pattern = AlphaPattern(uniformValue: 0.75)
        let cell = SubCellRenderer.render(
            pattern,
            foreground: .rgb(255, 255, 255),
            background: .rgb(0, 0, 0)
        )
        #expect(cell.glyph.character == "▓")
    }
}
