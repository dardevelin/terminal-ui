/// An 8-bit-per-channel colour, alpha straight (not premultiplied), in
/// sRGB: what a PNG stores and a GIF palette holds (less the alpha).
package struct RGBA: Hashable, Sendable {
    package var red: UInt8
    package var green: UInt8
    package var blue: UInt8
    package var alpha: UInt8

    package init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = .max) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    package static let transparent = RGBA(0, 0, 0, 0)
}

/// A mutable RGBA image, rows top to bottom, each pixel four bytes in
/// red-green-blue-alpha order — the layout of a PNG's colour type 6
/// scanline, so encoding reads rows straight out of it.
package struct PixelCanvas: Equatable, Sendable {
    package static let bytesPerPixel = 4

    package let width: Int
    package let height: Int
    package private(set) var bytes: [UInt8]

    package init(width: Int, height: Int, fill: RGBA = .transparent) {
        precondition(width >= 0 && height >= 0, "a canvas is \(width)×\(height)")
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
        if fill != .transparent {
            let pixel = [fill.red, fill.green, fill.blue, fill.alpha]
            for offset in stride(from: 0, to: bytes.count, by: Self.bytesPerPixel) {
                bytes.replaceSubrange(offset..<(offset + Self.bytesPerPixel), with: pixel)
            }
        }
    }

    package subscript(x: Int, y: Int) -> RGBA {
        get {
            let offset = self.offset(x, y)
            return RGBA(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        set {
            let offset = self.offset(x, y)
            bytes[offset] = newValue.red
            bytes[offset + 1] = newValue.green
            bytes[offset + 2] = newValue.blue
            bytes[offset + 3] = newValue.alpha
        }
    }

    /// Row `y`'s bytes, `width × 4` of them.
    package func row(_ y: Int) -> ArraySlice<UInt8> {
        precondition(y >= 0 && y < height, "row \(y) of \(height)")
        let start = y * width * Self.bytesPerPixel
        return bytes[start..<(start + width * Self.bytesPerPixel)]
    }

    private func offset(_ x: Int, _ y: Int) -> Int {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "(\(x), \(y)) outside \(width)×\(height)")
        return (y * width + x) * Self.bytesPerPixel
    }
}

/// An image of palette indices, row-major, one byte a pixel: the input to
/// an indexed PNG and to a GIF frame.
package struct IndexedImage: Equatable, Sendable {
    /// PNG's PLTE and a GIF colour table both hold at most 256 entries
    /// (PNG §11.2.3, GIF89a §19).
    package static let maximumPaletteCount = 256

    package let width: Int
    package let height: Int
    package let indices: [UInt8]
    package let palette: [RGBA]

    package init(width: Int, height: Int, indices: [UInt8], palette: [RGBA]) {
        precondition(indices.count == width * height, "\(indices.count) indices for \(width)×\(height)")
        precondition((1...Self.maximumPaletteCount).contains(palette.count), "a palette of \(palette.count)")
        precondition(indices.allSatisfy { Int($0) < palette.count }, "an index past the palette")
        self.width = width
        self.height = height
        self.indices = indices
        self.palette = palette
    }
}
