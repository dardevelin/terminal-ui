import Foundation
import Testing
@testable import TerminalUI

// Alpha-aware compositing into a CellBuffer. AlphaLayer is
// the input (a 2D buffer of AlphaCell, each carrying glyph + fg + bg
// + alpha). Compositor.compositeAlphaLayer walks the layer cell-by-
// cell and either passes through (alpha=1.0), preserves (alpha=0.0),
// or blends RGB colors (alpha in 0..1) against the existing
// CellBuffer cell.
//
// Color blending only meaningfully applies to .rgb cases. Other Color
// cases (named colors, ansi256) get resolved to an approximate RGB
// equivalent for the blend, then the result is emitted as .rgb so the
// downstream cell carries a single canonical form.

@Suite("Alpha compositing — AlphaLayer blends into CellBuffer per alpha")
@MainActor
struct AlphaCompositingTests {

    @Test("fully opaque alpha overwrites destination cell")
    func fullyOpaqueOverwrites() {
        var buffer = CellBuffer(width: 4, height: 1)
        buffer[0, 0] = Cell(character: "x", style: Style(foreground: .red, background: nil, bold: false, italic: false, underline: false))

        var layer = AlphaLayer(width: 4, height: 1)
        layer[0, 0] = AlphaCell(
            glyph: .full,
            foreground: .rgb(0, 0, 255),
            background: .rgb(0, 0, 0),
            alpha: 1.0
        )

        Compositor.compositeAlphaLayer(layer, at: Point(x: 0, y: 0), into: &buffer)

        #expect(buffer[0, 0].character == "█")
        #expect(buffer[0, 0].style.foreground == .rgb(0, 0, 255))
    }

    @Test("fully transparent alpha preserves destination")
    func fullyTransparentPreserves() {
        var buffer = CellBuffer(width: 4, height: 1)
        buffer[0, 0] = Cell(character: "x", style: Style(foreground: .red, background: nil, bold: false, italic: false, underline: false))

        var layer = AlphaLayer(width: 4, height: 1)
        layer[0, 0] = AlphaCell(
            glyph: .full,
            foreground: .rgb(0, 0, 255),
            background: .rgb(0, 0, 0),
            alpha: 0.0
        )

        Compositor.compositeAlphaLayer(layer, at: Point(x: 0, y: 0), into: &buffer)

        #expect(buffer[0, 0].character == "x")
        #expect(buffer[0, 0].style.foreground == .red)
    }

    @Test("half alpha blends RGB foreground 50/50")
    func halfAlphaBlendsRGB() {
        var buffer = CellBuffer(width: 4, height: 1)
        // Existing cell has fg=(255,0,0).
        buffer[0, 0] = Cell(character: "█", style: Style(
            foreground: .rgb(255, 0, 0),
            background: nil,
            bold: false, italic: false, underline: false
        ))

        var layer = AlphaLayer(width: 4, height: 1)
        layer[0, 0] = AlphaCell(
            glyph: .full,
            foreground: .rgb(0, 0, 255),
            background: .rgb(0, 0, 0),
            alpha: 0.5
        )

        Compositor.compositeAlphaLayer(layer, at: Point(x: 0, y: 0), into: &buffer)

        // 50/50 blend of (255,0,0) and (0,0,255) = (127,0,127) (or 128 with rounding).
        guard case .rgb(let r, let g, let b) = buffer[0, 0].style.foreground ?? .default else {
            Issue.record("foreground was not .rgb after alpha blend")
            return
        }
        #expect(r >= 127 && r <= 128, "red channel should average to ~127.5; got \(r)")
        #expect(g == 0)
        #expect(b >= 127 && b <= 128, "blue channel should average to ~127.5; got \(b)")
    }

    @Test("compositing at an offset translates layer coordinates")
    func compositeAtOffsetTranslates() {
        var buffer = CellBuffer(width: 8, height: 2)

        var layer = AlphaLayer(width: 2, height: 1)
        layer[0, 0] = AlphaCell(glyph: .full, foreground: .rgb(0, 255, 0), background: .rgb(0, 0, 0), alpha: 1.0)
        layer[1, 0] = AlphaCell(glyph: .halfTop, foreground: .rgb(0, 255, 0), background: .rgb(0, 0, 0), alpha: 1.0)

        Compositor.compositeAlphaLayer(layer, at: Point(x: 5, y: 1), into: &buffer)

        #expect(buffer[5, 1].character == "█")
        #expect(buffer[6, 1].character == "▀")
        // Untouched cells stay empty.
        #expect(buffer[0, 0].character == " ")
        #expect(buffer[5, 0].character == " ")
    }

    @Test("compositing clips when layer extends past buffer bounds")
    func compositeClipsToBufferBounds() {
        var buffer = CellBuffer(width: 4, height: 2)

        var layer = AlphaLayer(width: 4, height: 2)
        for y in 0..<2 {
            for x in 0..<4 {
                layer[x, y] = AlphaCell(glyph: .full, foreground: .rgb(0, 0, 255), background: .rgb(0, 0, 0), alpha: 1.0)
            }
        }

        // Offset (2, 1) means the bottom-right of layer extends past buffer's (4, 2) bounds.
        Compositor.compositeAlphaLayer(layer, at: Point(x: 2, y: 1), into: &buffer)

        #expect(buffer[2, 1].character == "█")
        #expect(buffer[3, 1].character == "█")
        // Cells outside buffer were clipped — no crash.
        // Cells before offset are untouched.
        #expect(buffer[0, 0].character == " ")
        #expect(buffer[1, 0].character == " ")
    }
}
