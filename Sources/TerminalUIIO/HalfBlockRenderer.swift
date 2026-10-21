import TerminalUI

// Universal-floor renderer. Each terminal cell carries
// 2 vertical pixels of source image: top pixel as foreground,
// bottom pixel as background, ▀ (U+2580 upper-half-block) as the
// glyph. Works on any 24-bit-color terminal.
//
// Source images larger than the rect's effective pixel grid
// (cellWidth × (cellHeight × 2)) are downsampled via box-filter.
// Smaller sources stretch — the consumer is expected to size the
// rect appropriately.

public struct HalfBlockRenderer: ImageRenderer, Sendable {
    public let supportedProtocol: GraphicsProtocol = .halfBlock

    public init() {}

    public func render(_ image: ImageBuffer, in rect: Rect, into buffer: inout CellBuffer) {
        guard rect.width > 0, rect.height > 0 else { return }

        // Each cell = 2 vertical pixels. Effective pixel grid =
        // cellWidth × (cellHeight × 2).
        let pixelHeight = rect.height * 2
        let downsampled = image.downsample(toWidth: rect.width, height: pixelHeight)

        for cellY in 0..<rect.height {
            for cellX in 0..<rect.width {
                let topPixel = downsampled.pixel(at: cellX, cellY * 2)
                let bottomPixel = downsampled.pixel(at: cellX, cellY * 2 + 1)
                let style = Style(
                    foreground: .rgb(topPixel.r, topPixel.g, topPixel.b),
                    background: .rgb(bottomPixel.r, bottomPixel.g, bottomPixel.b),
                    bold: false,
                    italic: false,
                    underline: false
                )
                buffer[rect.x + cellX, rect.y + cellY] = Cell(character: "▀", style: style)
            }
        }
    }
}
