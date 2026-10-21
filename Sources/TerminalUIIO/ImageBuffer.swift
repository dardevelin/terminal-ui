import Foundation

// RGBA pixel buffer used as the canonical input to all
// renderers (half-block, kitty, sixel, etc.). Holds raw bytes +
// dimensions; provides downsample (box-filter) + pixel access +
// rect-mean color helpers used by per-protocol renderers.

/// RGBA pixel buffer. Always 4 bytes per pixel: red, green, blue,
/// alpha — premultiplied or straight is the consumer's choice
/// (renderers that care document their expectation).
public struct ImageBuffer: Sendable, Equatable {
    public let rgba: [UInt8]
    public let width: Int
    public let height: Int

    public init(rgba: [UInt8], width: Int, height: Int) throws(ImageBufferError) {
        guard width > 0, height > 0 else {
            throw .nonPositiveDimensions(width: width, height: height)
        }
        let expected = width * height * 4
        guard rgba.count == expected else {
            throw .dimensionMismatch(expected: expected, actual: rgba.count)
        }
        self.rgba = rgba
        self.width = width
        self.height = height
    }

    /// Sample one pixel as RGBA. Returns `(0, 0, 0, 0)` for out-
    /// of-bounds reads — renderers that care about bounds should
    /// check `width`/`height` first.
    public func pixel(at x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else {
            return (0, 0, 0, 0)
        }
        let offset = (y * width + x) * 4
        return (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
    }

    /// Box-filter downsample to target dimensions. Each output
    /// pixel is the average of the source pixels covering its
    /// rect. Used by renderers to reduce source pixels to the
    /// cell-grid output size.
    public func downsample(toWidth targetWidth: Int, height targetHeight: Int) -> ImageBuffer {
        guard targetWidth > 0, targetHeight > 0 else {
            // Caller error; return self unchanged rather than
            // crash. Tests pin positive-dim contract via init.
            return self
        }
        guard targetWidth != width || targetHeight != height else { return self }

        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        for ty in 0..<targetHeight {
            for tx in 0..<targetWidth {
                // Source rect this output pixel covers.
                let srcX0 = (tx * width) / targetWidth
                let srcX1 = max(srcX0 + 1, ((tx + 1) * width) / targetWidth)
                let srcY0 = (ty * height) / targetHeight
                let srcY1 = max(srcY0 + 1, ((ty + 1) * height) / targetHeight)

                var rSum = 0, gSum = 0, bSum = 0, aSum = 0
                var count = 0
                for sy in srcY0..<srcY1 {
                    for sx in srcX0..<srcX1 {
                        let (r, g, b, a) = pixel(at: sx, sy)
                        rSum += Int(r)
                        gSum += Int(g)
                        bSum += Int(b)
                        aSum += Int(a)
                        count += 1
                    }
                }
                if count > 0 {
                    let outOffset = (ty * targetWidth + tx) * 4
                    output[outOffset]     = UInt8(rSum / count)
                    output[outOffset + 1] = UInt8(gSum / count)
                    output[outOffset + 2] = UInt8(bSum / count)
                    output[outOffset + 3] = UInt8(aSum / count)
                }
            }
        }
        // Force-cast through `try!` is acceptable here: we just built
        // the array with exact dimensions. A consumer constructing
        // ImageBuffer manually still goes through the throwing init.
        return (try? ImageBuffer(rgba: output, width: targetWidth, height: targetHeight)) ?? self
    }
}

/// Error cases for `ImageBuffer.init`. Typed-throws so consumers
/// know exactly what went wrong without `as` chains.
public enum ImageBufferError: Error, Sendable, Equatable {
    case dimensionMismatch(expected: Int, actual: Int)
    case nonPositiveDimensions(width: Int, height: Int)
}
