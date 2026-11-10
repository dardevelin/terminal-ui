import Foundation

/// The block transform of a DCT-based JPEG: the coefficients' order in the
/// stream, and the inverse DCT back to samples.
enum JPEGBlock {
    /// T.81 A.1.3, A.3.6: a block is 8 × 8 samples.
    static let side = 8
    static let count = side * side

    /// T.81 A.3.1: samples are coded level-shifted by 2^(P−1), P = 8.
    static let levelShift: Float = 128
    static let largestSample: Float = 255

    /// T.81 figure A.6: the zig-zag order, the natural (row-major) index of
    /// each coefficient as it comes in the stream.
    static let zigZag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// T.81 A.3.3's IDCT basis, ½·C(u)·cos((2x + 1)uπ / 16) at
    /// `x * side + u`, with C(0) = 1/√2 and C(u) = 1 otherwise — the
    /// two-dimensional transform is separable, so it is applied to rows
    /// and then columns.
    static let basis: [Float] = {
        var table = [Float](repeating: 0, count: count)
        for x in 0..<side {
            for frequency in 0..<side {
                let scale = frequency == 0 ? 1 / Float(2).squareRoot() : 1
                let angle = Float(2 * x + 1) * Float(frequency) * Float.pi / Float(2 * side)
                table[x * side + frequency] = scale * cos(angle) / 2
            }
        }
        return table
    }()

    /// The inverse DCT of `coefficients`, natural order and dequantised,
    /// level-shifted back and clamped (A.3.1), into `plane` at `offset`
    /// with rows `stride` apart. `rows`, of `count` values, holds the row
    /// pass, kept by the caller so a block allocates nothing.
    ///
    /// The loops are `while` loops and each sum is written out: a debug
    /// build steps a `Range` through a generic iterator, which cost a
    /// hundred times the arithmetic here, and an app's debug build decodes
    /// its pictures too.
    static func inverseTransform(_ coefficients: [Float], hasAC: Bool, rows: inout [Float],
                                 into plane: inout [UInt8], offset: Int, stride: Int) {
        if !hasAC {
            // Only the DC term: every sample is F(0,0)·C(0)²/4 = F(0,0)/8.
            let value = clamped(coefficients[0] / Float(side) + levelShift)
            var y = 0
            while y < side {
                let rowStart = offset + y * stride
                plane.replaceSubrange(rowStart..<(rowStart + side), with: repeatElement(value, count: side))
                y += 1
            }
            return
        }
        let basis = basis
        var index = 0
        while index < count {
            let row = index / side * side, x = index % side
            rows[index] = sum(basis, x * side, coefficients, row, 1)
            index += 1
        }
        index = 0
        while index < count {
            let y = index / side, x = index % side
            plane[offset + y * stride + x] = clamped(sum(basis, y * side, rows, x, side) + levelShift)
            index += 1
        }
    }

    /// Σ over the eight frequencies of a basis row times the values from
    /// `start`, `step` apart.
    private static func sum(_ basis: [Float], _ basisRow: Int, _ values: [Float], _ start: Int,
                            _ step: Int) -> Float {
        let first = basis[basisRow] * values[start] + basis[basisRow + 1] * values[start + step]
            + basis[basisRow + 2] * values[start + 2 * step] + basis[basisRow + 3] * values[start + 3 * step]
        let second = basis[basisRow + 4] * values[start + 4 * step] + basis[basisRow + 5] * values[start + 5 * step]
            + basis[basisRow + 6] * values[start + 6 * step] + basis[basisRow + 7] * values[start + 7 * step]
        return first + second
    }

    static func clamped(_ value: Float) -> UInt8 {
        UInt8(min(max(value.rounded(), 0), largestSample))
    }
}

/// JFIF's colour (ITU-T T.871 §7): YCbCr of BT.601's full range, Cb and Cr
/// offset by 128.
enum JFIFColour {
    static let chromaOffset: Float = 128
    static let redFromCr: Float = 1.402
    static let greenFromCb: Float = 0.344136
    static let greenFromCr: Float = 0.714136
    static let blueFromCb: Float = 1.772

    static func rgb(luma: Float, blueDifference: Float, redDifference: Float) -> (UInt8, UInt8, UInt8) {
        let blue = blueDifference - chromaOffset, red = redDifference - chromaOffset
        return (JPEGBlock.clamped(luma + redFromCr * red),
                JPEGBlock.clamped(luma - greenFromCb * blue - greenFromCr * red),
                JPEGBlock.clamped(luma + blueFromCb * blue))
    }
}

enum JPEGUpsampling {
    /// Output row `y` of a component whose samples are `plane`, rows
    /// `stride` apart: the two sample rows nearest it mixed into
    /// `vertical`, then each pixel mixed from the two samples nearest it
    /// across — linear interpolation each way, so bilinear. `while` loops,
    /// as in ``JPEGBlock/inverseTransform(_:hasAC:rows:into:offset:stride:)``,
    /// for a debug build's sake.
    static func row(_ y: Int, of plane: [UInt8], stride: Int, across: JPEGUpsamplingAxis,
                    down: JPEGUpsamplingAxis, vertical: inout [Float], into output: inout [Float]) {
        let top = down.lower[y] * stride, bottom = down.upper[y] * stride
        let lowerWeight = down.weight[y], upperWeight = 1 - lowerWeight
        let samples = min(vertical.count, stride)
        var index = 0
        if top == bottom || lowerWeight == 0 {
            while index < samples {
                vertical[index] = Float(plane[top + index])
                index += 1
            }
        } else {
            while index < samples {
                vertical[index] = Float(plane[top + index]) * upperWeight + Float(plane[bottom + index]) * lowerWeight
                index += 1
            }
        }
        var x = 0
        while x < output.count {
            let weight = across.weight[x]
            output[x] = weight == 0
                ? vertical[across.lower[x]]
                : vertical[across.lower[x]] * (1 - weight) + vertical[across.upper[x]] * weight
            x += 1
        }
    }
}

/// Where each output pixel samples a subsampled component: the two nearest
/// samples along one axis and the weight of the second — linear
/// interpolation between sample centres, the "fancy" upsampling libjpeg
/// does by default, and with a factor of one the sample itself.
struct JPEGUpsamplingAxis {
    /// A pixel's or a sample's centre, half its width in from its edge.
    private static let centre: Float = 0.5

    var lower: [Int]
    var upper: [Int]
    var weight: [Float]

    /// - Parameters:
    ///   - outputCount: Pixels along the axis.
    ///   - factor: Output pixels per sample.
    ///   - sampleCount: The component's samples along the axis that the
    ///     image covers (T.81 A.1.1), the last repeated past the edge.
    init(outputCount: Int, factor: Int, sampleCount: Int) {
        lower = []
        upper = []
        weight = []
        lower.reserveCapacity(outputCount)
        upper.reserveCapacity(outputCount)
        weight.reserveCapacity(outputCount)
        let last = max(0, sampleCount - 1)
        for index in 0..<outputCount {
            if factor == 1 {
                lower.append(min(index, last))
                upper.append(min(index, last))
                weight.append(0)
                continue
            }
            let centre = (Float(index) + Self.centre) / Float(factor) - Self.centre
            let floor = centre.rounded(.down)
            let first = Int(floor)
            lower.append(min(max(first, 0), last))
            upper.append(min(max(first + 1, 0), last))
            weight.append(centre - floor)
        }
    }
}
