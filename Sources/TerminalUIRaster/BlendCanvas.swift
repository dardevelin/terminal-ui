/// One opaque pixel as the colour drawn last over the colour beneath it,
/// and how much of the pixel the drawn colour covers: what a pixel of
/// terminal text is — a cell's foreground anti-aliased over its background.
///
/// Kept apart, rather than as the colour they blend to, so a palette can
/// shade the edge with fewer steps between the same two colours
/// (``IndexedPaletteBuilder``) while a solid pixel stays the exact colour.
/// A pixel wholly one colour is always held as that colour over itself,
/// fully covered, so two pixels that look alike compare equal.
///
/// The three are packed in one word — foreground red, green, blue,
/// background red, green, blue, coverage, from the high byte down — so a
/// screen of them compares, hashes and copies as integers.
package struct BlendedPixel: Hashable, Sendable {
    let bits: UInt64

    private enum Shift {
        static let foreground: UInt64 = 32
        static let background: UInt64 = 8
    }

    private static let colourMask: UInt64 = 0xFF_FFFF
    private static let maximum = Int(UInt8.max)

    package init(_ foreground: RGBA, over background: RGBA, coverage: UInt8) {
        let (top, bottom, amount): (RGBA, RGBA, UInt8)
        if coverage == .max || foreground.rgb == background.rgb {
            (top, bottom, amount) = (foreground, foreground, .max)
        } else if coverage == 0 {
            (top, bottom, amount) = (background, background, .max)
        } else {
            (top, bottom, amount) = (foreground, background, coverage)
        }
        bits = top.rgb << Shift.foreground | bottom.rgb << Shift.background | UInt64(amount)
    }

    package static func solid(_ colour: RGBA) -> BlendedPixel {
        BlendedPixel(colour, over: colour, coverage: .max)
    }

    package var foreground: RGBA { RGBA(rgb: bits >> Shift.foreground & Self.colourMask) }
    package var background: RGBA { RGBA(rgb: bits >> Shift.background & Self.colourMask) }
    /// 0 to 255: how much of the pixel `foreground` covers.
    package var coverage: UInt8 { UInt8(truncatingIfNeeded: bits) }

    /// Whether the pixel is one colour, with no edge to shade.
    package var isSolid: Bool { coverage == .max }

    /// The colour the pixel shows, each channel blended in sRGB:
    /// `(fg·a + bg·(255 − a) + 127) / 255`, rounded to nearest.
    package var colour: RGBA { Self.blend(foreground, over: background, coverage: Int(coverage)) }

    package static func blend(_ foreground: RGBA, over background: RGBA, coverage: Int) -> RGBA {
        guard coverage < maximum else { return RGBA(foreground.red, foreground.green, foreground.blue) }
        let remaining = maximum - coverage
        return RGBA(UInt8((Int(foreground.red) * coverage + Int(background.red) * remaining + maximum / 2) / maximum),
                    UInt8((Int(foreground.green) * coverage + Int(background.green) * remaining + maximum / 2) / maximum),
                    UInt8((Int(foreground.blue) * coverage + Int(background.blue) * remaining + maximum / 2) / maximum))
    }
}

extension RGBA {
    /// Red, green and blue in the low 24 bits, red highest.
    var rgb: UInt64 { UInt64(red) << 16 | UInt64(green) << 8 | UInt64(blue) }

    init(rgb: UInt64) {
        self.init(UInt8(truncatingIfNeeded: rgb >> 16), UInt8(truncatingIfNeeded: rgb >> 8), UInt8(truncatingIfNeeded: rgb))
    }
}

/// A rectangle of a canvas, in pixels.
package struct PixelRectangle: Equatable, Sendable {
    package var x: Int
    package var y: Int
    package var width: Int
    package var height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// An opaque image whose pixels remember how they were drawn: each one a
/// ``BlendedPixel``, the colour drawn last over what it covered. Drawing
/// over a pixel already blended blends over the colour it shows.
///
/// Its loops walk the pixels' storage with `while` and an index: swtui is
/// run unoptimised, where a range's iterator and an array's checked
/// subscript each cost a call through generic metadata a pixel, and a
/// screen is a million pixels.
package struct BlendCanvas: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package private(set) var pixels: [BlendedPixel]

    package init(width: Int, height: Int, fill: RGBA) {
        precondition(width >= 0 && height >= 0, "a canvas is \(width)×\(height)")
        self.width = width
        self.height = height
        pixels = [BlendedPixel](repeating: .solid(fill), count: width * height)
    }

    package subscript(x: Int, y: Int) -> BlendedPixel {
        precondition(contains(x, y), "(\(x), \(y)) outside \(width)×\(height)")
        return pixels[y * width + x]
    }

    package func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    /// The rectangle filled with `colour`, clipped to the canvas.
    package mutating func fill(x: Int, y: Int, width rectWidth: Int, height rectHeight: Int, with colour: RGBA) {
        let (left, right) = (max(x, 0), min(x + rectWidth, width))
        let (top, bottom) = (max(y, 0), min(y + rectHeight, height))
        guard left < right, top < bottom else { return }
        let solid = BlendedPixel.solid(colour)
        let stride = width
        pixels.withUnsafeMutableBufferPointer { pixels in
            var row = top
            while row < bottom {
                var index = row * stride + left
                let end = row * stride + right
                while index < end {
                    pixels[index] = solid
                    index += 1
                }
                row += 1
            }
        }
    }

    /// `colour` over the pixel at `(x, y)`, covering `coverage` of it; a
    /// pixel off the canvas is left alone.
    package mutating func blend(_ colour: RGBA, coverage: UInt8, x: Int, y: Int) {
        guard coverage > 0, contains(x, y) else { return }
        let index = y * width + x
        pixels[index] = BlendedPixel(colour, over: pixels[index].colour, coverage: coverage)
    }

    /// A coverage mask `maskWidth` pixels wide, its top-left pixel at
    /// `(x, y)`, in `colour`, clipped to the canvas.
    package mutating func blend(_ colour: RGBA, mask: [UInt8], maskWidth: Int, x: Int, y: Int) {
        guard maskWidth > 0 else { return }
        let maskHeight = mask.count / maskWidth
        let (firstColumn, endColumn) = (max(0, -x), min(maskWidth, width - x))
        let (firstRow, endRow) = (max(0, -y), min(maskHeight, height - y))
        guard firstColumn < endColumn, firstRow < endRow else { return }
        let stride = width
        mask.withUnsafeBufferPointer { mask in
            pixels.withUnsafeMutableBufferPointer { pixels in
                var row = firstRow
                while row < endRow {
                    var column = firstColumn
                    while column < endColumn {
                        let coverage = mask[row * maskWidth + column]
                        if coverage > 0 {
                            let index = (y + row) * stride + x + column
                            pixels[index] = BlendedPixel(colour, over: pixels[index].colour, coverage: coverage)
                        }
                        column += 1
                    }
                    row += 1
                }
            }
        }
    }

    /// A colour with alpha of its own, premultiplied (Porter and Duff's
    /// "over", 1984): the pixel becomes the colour it shows, solid, since a
    /// glyph in colours of its own has no single foreground to shade.
    package mutating func composite(premultiplied source: RGBA, x: Int, y: Int) {
        guard source.alpha > 0, contains(x, y) else { return }
        let index = y * width + x
        let beneath = pixels[index].colour
        let maximum = Int(UInt8.max)
        let remaining = maximum - Int(source.alpha)
        func channel(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8(min(maximum, Int(top) + (Int(bottom) * remaining + maximum / 2) / maximum))
        }
        pixels[index] = .solid(RGBA(channel(source.red, beneath.red), channel(source.green, beneath.green),
                                    channel(source.blue, beneath.blue)))
    }

    /// The pixels as the colours they show.
    package var pixelCanvas: PixelCanvas {
        var bytes = [UInt8](repeating: .max, count: pixels.count * PixelCanvas.bytesPerPixel)
        pixels.withUnsafeBufferPointer { pixels in
            bytes.withUnsafeMutableBufferPointer { bytes in
                var index = 0
                var last: (pixel: BlendedPixel, colour: RGBA)?
                while index < pixels.count {
                    let pixel = pixels[index]
                    let colour = last?.pixel == pixel ? last!.colour : pixel.colour
                    last = (pixel, colour)
                    let offset = index * PixelCanvas.bytesPerPixel
                    bytes[offset] = colour.red
                    bytes[offset + 1] = colour.green
                    bytes[offset + 2] = colour.blue
                    index += 1
                }
            }
        }
        return PixelCanvas(width: width, height: height, bytes: bytes)
    }

    /// The smallest rectangle holding every pixel that differs from
    /// `previous`, a canvas of the same size; nil when none does.
    package func changedRectangle(since previous: BlendCanvas) -> PixelRectangle? {
        precondition(previous.width == width && previous.height == height, "canvases of different sizes")
        var (left, top, right, bottom) = (width, height, -1, -1)
        let stride = width
        pixels.withUnsafeBufferPointer { pixels in
            previous.pixels.withUnsafeBufferPointer { previous in
                var row = 0
                while row < height {
                    var column = 0
                    let start = row * stride
                    while column < stride {
                        if pixels[start + column] != previous[start + column] {
                            left = min(left, column)
                            right = max(right, column)
                            if top > row { top = row }
                            bottom = row
                        }
                        column += 1
                    }
                    row += 1
                }
            }
        }
        guard right >= 0 else { return nil }
        return PixelRectangle(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    /// The pixels of `rectangle`, row by row, as runs of one pixel
    /// repeated: `body` gets each run's pixel and length, the pixel nil
    /// for a run unchanged from `previous`. A screen is mostly runs, so a
    /// caller that looks a pixel up does so once a run.
    package func forEachRun(in rectangle: PixelRectangle, since previous: BlendCanvas?,
                            _ body: (BlendedPixel?, Int) -> Void) {
        let stride = width
        pixels.withUnsafeBufferPointer { pixels in
            (previous?.pixels ?? []).withUnsafeBufferPointer { previous in
                var run: (pixel: BlendedPixel?, length: Int)?
                var row = rectangle.y
                while row < rectangle.y + rectangle.height {
                    var index = row * stride + rectangle.x
                    let end = index + rectangle.width
                    while index < end {
                        let pixel = pixels[index]
                        let shown: BlendedPixel? = previous.isEmpty || previous[index] != pixel ? pixel : nil
                        if let current = run, current.pixel == shown {
                            run = (shown, current.length + 1)
                        } else {
                            if let current = run { body(current.pixel, current.length) }
                            run = (shown, 1)
                        }
                        index += 1
                    }
                    row += 1
                }
                if let current = run { body(current.pixel, current.length) }
            }
        }
    }
}

extension IndexedImage {
    /// `canvas` as palette indices with no colour changed, when it shows at
    /// most 256 colours; nil when it shows more. The palette lists the
    /// colours in the order the rows first show them.
    package init?(exactly canvas: PixelCanvas) {
        var palette: [RGBA] = []
        var indexOf: [RGBA: UInt8] = [:]
        var indices = [UInt8](repeating: 0, count: canvas.width * canvas.height)
        let fits = canvas.bytes.withUnsafeBufferPointer { bytes in
            indices.withUnsafeMutableBufferPointer { indices in
                var last: (colour: RGBA, index: UInt8)?
                var pixel = 0
                while pixel < indices.count {
                    let offset = pixel * PixelCanvas.bytesPerPixel
                    let colour = RGBA(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
                    if let known = last, known.colour == colour {
                        indices[pixel] = known.index
                    } else if let index = indexOf[colour] {
                        indices[pixel] = index
                        last = (colour, index)
                    } else {
                        guard palette.count < Self.maximumPaletteCount else { return false }
                        let index = UInt8(palette.count)
                        indexOf[colour] = index
                        palette.append(colour)
                        indices[pixel] = index
                        last = (colour, index)
                    }
                    pixel += 1
                }
                return true
            }
        }
        guard fits, !palette.isEmpty else { return nil }
        self.init(width: canvas.width, height: canvas.height, indices: indices, palette: palette)
    }
}
