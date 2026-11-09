/// A PNG encoder (W3C PNG Specification, Third Edition; ISO/IEC 15948),
/// section numbers below from it.
///
/// Chunks are IHDR, sRGB, PLTE and tRNS for an indexed image, IDAT, IEND —
/// nothing that records when or on what the file was made (no tIME), so
/// the same image is always the same file.
package enum PNGWriter {
    /// The truecolour layouts a canvas can be written in (§6.1).
    package enum TruecolourType: UInt8, Sendable {
        /// Colour type 2: red, green, blue; the canvas's alpha is dropped.
        case rgb = 2
        /// Colour type 6: red, green, blue, alpha.
        case rgba = 6

        var bytesPerPixel: Int { self == .rgb ? 3 : 4 }
    }

    /// §5.2: the eight bytes every PNG starts with.
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let indexedColourType: UInt8 = 3
    private static let truecolourBitDepth: UInt8 = 8
    /// §11.2.2: compression method 0 (zlib deflate), filter method 0
    /// (the five adaptive filters), interlace method 0 (none).
    private static let compressionMethod: UInt8 = 0
    private static let filterMethod: UInt8 = 0
    private static let interlaceMethod: UInt8 = 0
    /// §11.3.3.5: rendering intent 0, perceptual — the canvas is sRGB.
    private static let perceptualIntent: UInt8 = 0
    /// §10.2 allows any split of the zlib stream across IDAT chunks; libpng
    /// writes 8 KiB, and 32 KiB keeps the per-chunk overhead negligible
    /// while a reader still never needs a large chunk whole.
    static let maximumIDATLength = 32_768

    /// `canvas` as a truecolour PNG, each row filtered by the adaptive
    /// heuristic §12.8 recommends.
    package static func encode(_ canvas: PixelCanvas, colourType: TruecolourType) -> [UInt8] {
        precondition(canvas.width > 0 && canvas.height > 0, "PNG needs at least one pixel (§11.2.2)")
        let bytesPerPixel = colourType.bytesPerPixel
        var scanlines: [UInt8] = []
        scanlines.reserveCapacity(canvas.height * (1 + canvas.width * bytesPerPixel))
        var previous = [UInt8](repeating: 0, count: canvas.width * bytesPerPixel)
        for y in 0..<canvas.height {
            let row = rowBytes(canvas.row(y), bytesPerPixel: bytesPerPixel)
            ScanlineFilter.appendBest(row, previous: previous, bytesPerPixel: bytesPerPixel, to: &scanlines)
            previous = row
        }
        return file(width: canvas.width, height: canvas.height, bitDepth: truecolourBitDepth,
                    colourType: colourType.rawValue, palette: [], scanlines: scanlines)
    }

    /// A canvas row's bytes, each pixel cut to its first `bytesPerPixel`
    /// channels — red, green, blue, then alpha if it is kept.
    private static func rowBytes(_ row: ArraySlice<UInt8>, bytesPerPixel: Int) -> [UInt8] {
        guard bytesPerPixel != PixelCanvas.bytesPerPixel else { return Array(row) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(row.count / PixelCanvas.bytesPerPixel * bytesPerPixel)
        for pixel in stride(from: row.startIndex, to: row.endIndex, by: PixelCanvas.bytesPerPixel) {
            bytes += row[pixel..<(pixel + bytesPerPixel)]
        }
        return bytes
    }

    /// `image` as an indexed PNG at the smallest bit depth its palette
    /// fits (§11.2.2 allows 1, 2, 4 and 8), rows unfiltered: §12.8
    /// recommends filter type 0 for indexed images, whose neighbouring
    /// indices are no closer in value for being close in colour.
    package static func encode(_ image: IndexedImage) -> [UInt8] {
        precondition(image.width > 0 && image.height > 0, "PNG needs at least one pixel (§11.2.2)")
        let bitDepth = [1, 2, 4, 8].first { image.palette.count <= 1 << $0 } ?? UInt8.bitWidth
        let pixelsPerByte = UInt8.bitWidth / bitDepth
        let rowLength = (image.width + pixelsPerByte - 1) / pixelsPerByte
        var scanlines = [UInt8](repeating: 0, count: image.height * (1 + rowLength))
        // §7.2: pixels narrower than a byte are packed leftmost in the
        // most significant bits.
        for y in 0..<image.height {
            let rowStart = y * (1 + rowLength) + 1
            for x in 0..<image.width {
                let shift = UInt8.bitWidth - bitDepth * (x % pixelsPerByte + 1)
                scanlines[rowStart + x / pixelsPerByte] |= image.indices[y * image.width + x] << shift
            }
        }
        return file(width: image.width, height: image.height, bitDepth: UInt8(bitDepth),
                    colourType: indexedColourType, palette: image.palette, scanlines: scanlines)
    }

    private static func file(width: Int, height: Int, bitDepth: UInt8, colourType: UInt8,
                             palette: [RGBA], scanlines: [UInt8]) -> [UInt8] {
        var png = signature
        appendChunk("IHDR", UInt32(width).bigEndianBytes + UInt32(height).bigEndianBytes
                        + [bitDepth, colourType, compressionMethod, filterMethod, interlaceMethod], to: &png)
        appendChunk("sRGB", [perceptualIntent], to: &png)
        if !palette.isEmpty {
            appendChunk("PLTE", palette.flatMap { [$0.red, $0.green, $0.blue] }, to: &png)
            // §11.3.2.1: entries past the last one listed are opaque, so
            // the list stops there, and is left out when all are opaque.
            if let lastTranslucent = palette.lastIndex(where: { $0.alpha != .max }) {
                appendChunk("tRNS", palette[...lastTranslucent].map(\.alpha), to: &png)
            }
        }
        let stream = Deflate.zlibCompress(scanlines)
        for start in stride(from: 0, to: stream.count, by: maximumIDATLength) {
            appendChunk("IDAT", stream[start..<min(start + maximumIDATLength, stream.count)], to: &png)
        }
        appendChunk("IEND", [], to: &png)
        return png
    }

    /// §5.3: length, type, data, and the CRC of type and data.
    private static func appendChunk(_ type: String, _ data: some Collection<UInt8>, to png: inout [UInt8]) {
        let typeAndData = Array(type.utf8) + data
        png += UInt32(data.count).bigEndianBytes + typeAndData + CRC32.checksum(typeAndData).bigEndianBytes
    }

}

/// The five filter types of filter method 0 (§9.2), and the choice among
/// them §12.8 recommends: for each row, the filter whose output bytes,
/// read as signed, have the smallest sum of absolute values.
private enum ScanlineFilter: UInt8, CaseIterable {
    case none = 0
    case sub = 1
    case up = 2
    case average = 3
    case paeth = 4

    /// Appends `row`'s filter byte and filtered bytes; a tie goes to the
    /// lower filter type. The search is most of a truecolour PNG's
    /// encoding time, so it runs over the rows' storage directly, as
    /// LZ77's match search does: an array's checked subscript costs a
    /// call a byte in an unoptimised build, and swtui is run as one.
    static func appendBest(_ row: [UInt8], previous: [UInt8], bytesPerPixel: Int, to scanlines: inout [UInt8]) {
        let count = row.count
        var best = (filter: none, cost: Int.max)
        var bestOutput: [UInt8] = []
        var output = [UInt8](repeating: 0, count: count)
        for filter in allCases {
            let cost = row.withUnsafeBufferPointer { row in
                previous.withUnsafeBufferPointer { previous in
                    output.withUnsafeMutableBufferPointer { output in
                        filter.apply(row, previous: previous, bytesPerPixel: bytesPerPixel, into: output)
                    }
                }
            }
            if cost < best.cost {
                best = (filter, cost)
                bestOutput = output
            }
        }
        scanlines.append(best.filter.rawValue)
        scanlines += bestOutput
    }

    /// §9.2: each byte less its prediction from the byte a pixel to the
    /// left (`a`), the byte above (`b`) and the one above that (`c`),
    /// modulo 256, with bytes outside the image taken as 0. Returns the
    /// output's cost: the sum of its bytes' magnitudes, read as signed.
    private func apply(_ row: UnsafeBufferPointer<UInt8>, previous: UnsafeBufferPointer<UInt8>, bytesPerPixel: Int,
                       into output: UnsafeMutableBufferPointer<UInt8>) -> Int {
        var cost = 0
        // A while loop, not a range's iterator, which an unoptimised build
        // calls through generic metadata for every byte.
        var index = 0
        while index < row.count {
            defer { index += 1 }
            let left = index >= bytesPerPixel ? Int(row[index - bytesPerPixel]) : 0
            let above = Int(previous[index])
            let prediction: Int
            switch self {
            case .none: prediction = 0
            case .sub: prediction = left
            case .up: prediction = above
            case .average: prediction = (left + above) / 2
            case .paeth: prediction = Self.paeth(left, above, index >= bytesPerPixel ? Int(previous[index - bytesPerPixel]) : 0)
            }
            let byte = UInt8(truncatingIfNeeded: Int(row[index]) - prediction)
            output[index] = byte
            cost += byte < Self.signBit ? Int(byte) : Self.byteRange - Int(byte)
        }
        return cost
    }

    private static let signBit: UInt8 = 0x80
    private static let byteRange = 0x100

    /// §9.4: whichever of a, b, c is nearest a + b − c, ties in that order.
    private static func paeth(_ left: Int, _ above: Int, _ aboveLeft: Int) -> Int {
        let estimate = left + above - aboveLeft
        let toLeft = estimate >= left ? estimate - left : left - estimate
        let toAbove = estimate >= above ? estimate - above : above - estimate
        let toAboveLeft = estimate >= aboveLeft ? estimate - aboveLeft : aboveLeft - estimate
        if toLeft <= toAbove && toLeft <= toAboveLeft { return left }
        return toAbove <= toAboveLeft ? above : aboveLeft
    }
}
