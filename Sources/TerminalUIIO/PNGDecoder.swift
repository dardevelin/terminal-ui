import Foundation

/// A PNG decoder in pure Swift, so every system draws a PNG the same.
///
/// It reads every image the PNG specification (W3C, *Portable Network
/// Graphics (PNG) Specification*, third edition; ISO/IEC 15948:2004)
/// defines: greyscale at 1, 2, 4, 8 and 16 bits, truecolour and the alpha
/// types at 8 and 16, indexed colour at 1 to 8 bits with its palette,
/// `tRNS` transparency for the types without alpha, all five row filters,
/// and Adam7 interlacing. Each chunk's CRC is checked, and so is the zlib
/// stream's Adler-32.
///
/// What it leaves alone: the colour-space chunks (`gAMA`, `cHRM`, `sRGB`,
/// `iCCP`), whose samples it hands over as stored, every other ancillary
/// chunk, and an animated PNG's frames after the first. Sixteen-bit
/// samples are scaled to eight. The result is straight, not premultiplied,
/// RGBA.
///
/// Malformed input throws ``ImageDecodeError/malformedData(reason:)`` and
/// never traps: a bad signature, chunk, chunk order, CRC, header, palette
/// or filter, a stream that does not inflate to exactly the rows the header
/// promises, or an image of more than ``maximumPixelCount`` pixels, which
/// is refused before anything is inflated.
///
/// ```swift
/// let image = try PNGDecoder().decode(Data(contentsOf: url))
/// ```
public struct PNGDecoder: ImageDecoder {
    /// The pixel count a decoder refuses images beyond unless told
    /// otherwise: 2^26, about 67 million — an 8192 × 8192 image, a
    /// 256 MB buffer.
    public static let defaultMaximumPixelCount = 1 << 26

    /// The most pixels an image may have. A header that claims more is
    /// refused before its rows are inflated, so a hostile file's
    /// dimensions bound what decoding it allocates.
    public let maximumPixelCount: Int

    /// A decoder that refuses images of more than `maximumPixelCount`
    /// pixels.
    public init(maximumPixelCount: Int = PNGDecoder.defaultMaximumPixelCount) {
        self.maximumPixelCount = maximumPixelCount
    }

    /// Decode a PNG file's bytes into straight RGBA.
    ///
    /// - Throws: ``ImageDecodeError/unsupportedFormat(magic:)`` when the
    ///   bytes do not start with PNG's signature, and
    ///   ``ImageDecodeError/malformedData(reason:)`` when they are not a
    ///   PNG this decoder reads.
    public func decode(_ data: Data) throws(ImageDecodeError) -> ImageBuffer {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Signature.bytes) else {
            throw .unsupportedFormat(magic: Array(bytes.prefix(Signature.bytes.count)))
        }
        let chunks = try Self.readChunks(bytes)
        let header = try Self.header(of: chunks.header, maximumPixelCount: maximumPixelCount)
        let palette = try Self.palette(of: chunks, header: header)
        let key = try Self.transparencyKey(of: chunks, header: header)
        let passes = header.interlaced ? Adam7.passes : [Adam7.whole]
        let expected = passes.reduce(0) { total, pass in
            total + header.filteredBytes(of: pass.size(width: header.width, height: header.height))
        }
        var raw = try Self.inflate(chunks.imageData, expected: expected)

        var rgba = [UInt8](repeating: 0, count: header.width * header.height * Pixel.channels)
        var offset = 0
        for pass in passes {
            let size = pass.size(width: header.width, height: header.height)
            let length = header.filteredBytes(of: size)
            guard length > 0 else { continue }
            try Self.unfilter(&raw, at: offset, header: header, size: size)
            let stride = 1 + header.rowBytes(width: size.width)
            for y in 0..<size.height {
                let target = ((pass.firstRow + y * pass.rowStep) * header.width + pass.firstColumn) * Pixel.channels
                Self.expand(raw, row: offset + y * stride + 1, count: size.width, header: header, palette: palette,
                            key: key, into: &rgba, at: target, step: pass.columnStep * Pixel.channels)
            }
            offset += length
        }
        do {
            return try ImageBuffer(rgba: rgba, width: header.width, height: header.height)
        } catch {
            throw .malformedData(reason: "PNG: \(error)")
        }
    }

    // MARK: - Chunks (§5)

    /// §5.2: the eight bytes every PNG datastream starts with.
    private enum Signature {
        static let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// §5.6's chunk types, their four ASCII bytes read big-endian.
    private enum ChunkType {
        static let header: UInt32 = 0x4948_4452
        static let palette: UInt32 = 0x504C_5445
        static let imageData: UInt32 = 0x4944_4154
        static let end: UInt32 = 0x4945_4E44
        static let transparency: UInt32 = 0x7452_4E53
        /// §5.4: bit 5 of a type's first byte, set for an ancillary chunk a
        /// decoder may skip, clear for a critical one it must understand.
        static let ancillaryBit: UInt32 = 0x2000_0000
    }

    /// §5.3: a length, a type, the data, and a CRC of type and data.
    private enum ChunkLayout {
        static let lengthBytes = 4
        static let typeBytes = 4
        static let crcBytes = 4
        static let framing = lengthBytes + typeBytes + crcBytes
        /// A chunk's length is at most 2^31 − 1.
        static let maximumLength = Int(Int32.max)
    }

    /// The chunks the decoder reads, in the order §5.6 Table 5.3 allows.
    private struct Chunks {
        var header: ArraySlice<UInt8>
        var palette: ArraySlice<UInt8>?
        var transparency: ArraySlice<UInt8>?
        /// Every IDAT's data, joined.
        var imageData: [UInt8] = []
    }

    /// §5.6: IHDR first; PLTE before the image data and tRNS after PLTE;
    /// the IDAT chunks consecutive; IEND last. A chunk out of that order, or
    /// a second IHDR, PLTE or tRNS, is refused, as libpng refuses it.
    private static func readChunks(_ bytes: [UInt8]) throws(ImageDecodeError) -> Chunks {
        var header: ArraySlice<UInt8>?
        var palette: ArraySlice<UInt8>?
        var transparency: ArraySlice<UInt8>?
        var imageData: [UInt8] = []
        var position = Signature.bytes.count
        var imageDataState = ImageDataState.before
        while true {
            guard bytes.count - position >= ChunkLayout.framing else {
                throw .malformedData(reason: "PNG: truncated before IEND")
            }
            let length = Int(bigEndianWord(bytes, at: position))
            guard length <= ChunkLayout.maximumLength, bytes.count - position - ChunkLayout.framing >= length else {
                throw .malformedData(reason: "PNG: truncated chunk")
            }
            let typeStart = position + ChunkLayout.lengthBytes
            let dataStart = typeStart + ChunkLayout.typeBytes
            let dataEnd = dataStart + length
            let type = bigEndianWord(bytes, at: typeStart)
            guard CRC32.checksum(bytes[typeStart..<dataEnd]) == bigEndianWord(bytes, at: dataEnd) else {
                throw .malformedData(reason: "PNG: chunk CRC mismatch")
            }
            let data = bytes[dataStart..<dataEnd]
            position = dataEnd + ChunkLayout.crcBytes
            if type == ChunkType.header {
                guard header == nil else { throw .malformedData(reason: "PNG: a second IHDR") }
                header = data
                continue
            }
            guard let imageHeader = header else { throw .malformedData(reason: "PNG: IHDR is not the first chunk") }
            if imageDataState == .within, type != ChunkType.imageData { imageDataState = .after }
            switch type {
            case ChunkType.end:
                guard imageDataState != .before else { throw .malformedData(reason: "PNG: no IDAT chunk") }
                return Chunks(header: imageHeader, palette: palette, transparency: transparency, imageData: imageData)
            case ChunkType.imageData:
                guard imageDataState != .after else { throw .malformedData(reason: "PNG: IDAT chunks not consecutive") }
                imageDataState = .within
                imageData += data
            case ChunkType.palette:
                guard palette == nil, transparency == nil, imageDataState == .before else {
                    throw .malformedData(reason: "PNG: PLTE out of order")
                }
                palette = data
            case ChunkType.transparency:
                guard transparency == nil, imageDataState == .before else {
                    throw .malformedData(reason: "PNG: tRNS out of order")
                }
                transparency = data
            default:
                guard type & ChunkType.ancillaryBit != 0 else {
                    throw .malformedData(reason: "PNG: unknown critical chunk")
                }
            }
        }
    }

    private enum ImageDataState {
        case before, within, after
    }

    /// The four bytes at `index` as a big-endian word; the caller has
    /// checked there are four.
    private static func bigEndianWord(_ bytes: [UInt8], at index: Int) -> UInt32 {
        var word: UInt32 = 0
        for offset in 0..<MemoryLayout<UInt32>.size {
            word = word << UInt8.bitWidth | UInt32(bytes[index + offset])
        }
        return word
    }

    // MARK: - Header (§11.2.1)

    /// §11.2.1 Table 11.1: the colour types and the bit depths each allows.
    private enum ColourType: UInt8 {
        case greyscale = 0
        case truecolour = 2
        case indexed = 3
        case greyscaleAlpha = 4
        case truecolourAlpha = 6

        var channels: Int {
            switch self {
            case .greyscale, .indexed: 1
            case .greyscaleAlpha: 2
            case .truecolour: 3
            case .truecolourAlpha: 4
            }
        }

        var allowedDepths: Set<Int> {
            switch self {
            case .greyscale: [1, 2, 4, 8, 16]
            case .indexed: [1, 2, 4, 8]
            case .truecolour, .greyscaleAlpha, .truecolourAlpha: [8, 16]
            }
        }
    }

    /// §11.2.1: IHDR's thirteen bytes.
    private enum HeaderLayout {
        static let length = 13
        static let heightOffset = 4
        static let depthOffset = 8
        static let colourTypeOffset = 9
        static let compressionOffset = 10
        static let filterOffset = 11
        static let interlaceOffset = 12
        /// Compression method 0 is deflate; filter method 0 the five
        /// adaptive filters; interlace method 0 none and 1 Adam7.
        static let deflate: UInt8 = 0
        static let adaptiveFilters: UInt8 = 0
        static let noInterlace: UInt8 = 0
        static let adam7: UInt8 = 1
    }

    private struct Header {
        var width: Int
        var height: Int
        var depth: Int
        var colourType: ColourType
        var interlaced: Bool

        var bitsPerPixel: Int { depth * colourType.channels }
        /// The unit a filter predicts across: a pixel's bytes, or one byte
        /// where a pixel is smaller (§7.3).
        var filterStride: Int { max(1, bitsPerPixel / UInt8.bitWidth) }

        func rowBytes(width: Int) -> Int { (width * bitsPerPixel + UInt8.bitWidth - 1) / UInt8.bitWidth }

        /// The bytes a reduced image of `size` takes inflated: each row its
        /// filter-type byte and its samples; an empty pass none (§8.2).
        func filteredBytes(of size: (width: Int, height: Int)) -> Int {
            size.width == 0 || size.height == 0 ? 0 : size.height * (1 + rowBytes(width: size.width))
        }
    }

    /// The most bytes decoding gives a pixel: sixteen-bit RGBA's eight
    /// inflated and four of RGBA, rounded up to a power of two.
    private static let mostBytesPerPixel = 16

    private static func header(of fields: ArraySlice<UInt8>,
                               maximumPixelCount: Int) throws(ImageDecodeError) -> Header {
        guard fields.count == HeaderLayout.length else { throw .malformedData(reason: "PNG: IHDR malformed") }
        let fields = Array(fields)
        let width = Int(bigEndianWord(fields, at: 0))
        let height = Int(bigEndianWord(fields, at: HeaderLayout.heightOffset))
        let depth = Int(fields[HeaderLayout.depthOffset])
        guard let colourType = ColourType(rawValue: fields[HeaderLayout.colourTypeOffset]),
              colourType.allowedDepths.contains(depth) else {
            throw .malformedData(reason: "PNG: colour type or bit depth not in the specification")
        }
        guard fields[HeaderLayout.compressionOffset] == HeaderLayout.deflate,
              fields[HeaderLayout.filterOffset] == HeaderLayout.adaptiveFilters,
              [HeaderLayout.noInterlace, HeaderLayout.adam7].contains(fields[HeaderLayout.interlaceOffset]) else {
            throw .malformedData(reason: "PNG: unknown compression, filter or interlace method")
        }
        // §11.2.1: each dimension 1 to 2^31 − 1.
        guard width > 0, height > 0, width <= ChunkLayout.maximumLength, height <= ChunkLayout.maximumLength else {
            throw .malformedData(reason: "PNG: dimensions \(width)×\(height) out of range")
        }
        // A limit past what the buffers' sizes can be counted in is as good
        // as none.
        let maximum = min(maximumPixelCount, Int.max / mostBytesPerPixel)
        guard width <= maximum / height else {
            throw .tooManyPixels(format: "PNG", width: width, height: height, maximum: maximum)
        }
        return Header(width: width, height: height, depth: depth, colourType: colourType,
                      interlaced: fields[HeaderLayout.interlaceOffset] == HeaderLayout.adam7)
    }

    // MARK: - Palette and transparency (§11.2.2, §11.3.1)

    private static let paletteEntryBytes = 3
    private static let paletteSize = 1 << UInt8.bitWidth

    /// What an index reads as: PLTE's colours with tRNS's alphas, and for
    /// an index past the palette's end, which §11.2.2 makes an error a
    /// decoder may recover from, opaque black, as libpng draws it. Empty
    /// for an image that is not indexed: PLTE there only suggests a
    /// palette to quantise to, and is ignored.
    private static func palette(of chunks: Chunks, header: Header) throws(ImageDecodeError) -> [Pixel] {
        guard header.colourType == .indexed else { return [] }
        guard let chunk = chunks.palette else { throw .malformedData(reason: "PNG: indexed image without PLTE") }
        let entries = chunk.count / paletteEntryBytes
        guard chunk.count % paletteEntryBytes == 0, entries > 0, entries <= paletteSize else {
            throw .malformedData(reason: "PNG: PLTE length")
        }
        let alphas = chunks.transparency.map(Array.init) ?? []
        guard alphas.count <= entries else { throw .malformedData(reason: "PNG: tRNS longer than PLTE") }
        let colours = Array(chunk)
        var palette = [Pixel](repeating: Pixel(red: 0, green: 0, blue: 0, alpha: Pixel.opaque), count: paletteSize)
        for entry in 0..<entries {
            let start = entry * paletteEntryBytes
            palette[entry] = Pixel(red: colours[start], green: colours[start + 1], blue: colours[start + 2],
                                   alpha: entry < alphas.count ? alphas[entry] : Pixel.opaque)
        }
        return palette
    }

    /// §11.3.1.1: the one grey sample, or the one RGB triple, at the
    /// image's own depth, that tRNS makes fully transparent. A grey key is
    /// in all three.
    private struct TransparencyKey {
        var red: Int
        var green: Int
        var blue: Int
    }

    private static let keySampleBytes = 2

    private static func transparencyKey(of chunks: Chunks, header: Header) throws(ImageDecodeError) -> TransparencyKey? {
        guard let chunk = chunks.transparency else { return nil }
        switch header.colourType {
        case .indexed:
            return nil
        case .greyscaleAlpha, .truecolourAlpha:
            throw .malformedData(reason: "PNG: tRNS on an image with alpha")
        case .greyscale, .truecolour:
            let data = Array(chunk)
            guard data.count == keySampleBytes * header.colourType.channels else {
                throw .malformedData(reason: "PNG: tRNS length")
            }
            func sample(_ index: Int) -> Int {
                Int(data[index * keySampleBytes]) << UInt8.bitWidth | Int(data[index * keySampleBytes + 1])
            }
            return header.colourType == .greyscale
                ? TransparencyKey(red: sample(0), green: sample(0), blue: sample(0))
                : TransparencyKey(red: sample(0), green: sample(1), blue: sample(2))
        }
    }

    // MARK: - Decompression (§10, RFC 1950)

    /// RFC 1950 §2.2: CMF and FLG, then the deflate data, then the Adler-32
    /// of what it holds.
    private enum ZlibLayout {
        static let headerBytes = 2
        static let trailerBytes = 4
        /// CM = 8 is deflate, in CMF's low four bits; CINFO, the high four,
        /// is the window's base-2 logarithm less eight, at most 7.
        static let methodMask: UInt8 = 0x0F
        static let deflateMethod: UInt8 = 8
        static let windowShift: UInt8 = 4
        static let largestWindowInfo: UInt8 = 7
        /// FLG bit 5: a preset dictionary, which PNG forbids (§10.1).
        static let presetDictionary: UInt8 = 0x20
        /// CMF·256 + FLG is a multiple of 31.
        static let checkDivisor = 31
    }

    private static func inflate(_ stream: [UInt8], expected: Int) throws(ImageDecodeError) -> [UInt8] {
        guard stream.count >= ZlibLayout.headerBytes + ZlibLayout.trailerBytes else {
            throw .malformedData(reason: "PNG: image data truncated")
        }
        let method = stream[0], flags = stream[1]
        guard method & ZlibLayout.methodMask == ZlibLayout.deflateMethod,
              method >> ZlibLayout.windowShift <= ZlibLayout.largestWindowInfo,
              (Int(method) << UInt8.bitWidth | Int(flags)) % ZlibLayout.checkDivisor == 0,
              flags & ZlibLayout.presetDictionary == 0 else {
            throw .malformedData(reason: "PNG: zlib header")
        }
        let inflated: [UInt8]?
        do {
            inflated = try Inflate.inflate(stream, from: ZlibLayout.headerBytes, limit: expected)
        } catch {
            throw .malformedData(reason: "PNG: image data does not inflate: \(error)")
        }
        guard let inflated else {
            throw .malformedData(reason: "PNG: image data holds more than the \(expected) bytes the header gives")
        }
        guard inflated.count == expected else {
            throw .malformedData(reason: "PNG: image data holds \(inflated.count) bytes, the header \(expected)")
        }
        // RFC 1950 puts the Adler-32 straight after the deflate data, and
        // PNG's image data holds nothing after it: the stream's last four
        // bytes, big-endian.
        guard Adler32.checksum(inflated) == bigEndianWord(stream, at: stream.count - ZlibLayout.trailerBytes) else {
            throw .malformedData(reason: "PNG: Adler-32 mismatch")
        }
        return inflated
    }

    // MARK: - Filters (§7.3, §9)

    /// §9.2 Table 9.1: the filter type byte that starts each row.
    private enum Filter: UInt8 {
        case none = 0
        case sub = 1
        case up = 2
        case average = 3
        case paeth = 4
    }

    /// Reconstruct, in place, the rows of a reduced image of `size` whose
    /// filtered bytes start at `start`, each a filter-type byte and the
    /// row (§9.2). The row above the first is zeros.
    private static func unfilter(_ bytes: inout [UInt8], at start: Int, header: Header,
                                 size: (width: Int, height: Int)) throws(ImageDecodeError) {
        let rowBytes = header.rowBytes(width: size.width)
        let stride = header.filterStride
        try bytes.withUnsafeMutableBufferPointer { (buffer) throws(ImageDecodeError) in
            for y in 0..<size.height {
                let typeIndex = start + y * (rowBytes + 1)
                guard let filter = Filter(rawValue: buffer[typeIndex]) else {
                    throw .malformedData(reason: "PNG: filter type \(buffer[typeIndex])")
                }
                let row = typeIndex + 1
                let above = row - (rowBytes + 1)
                let hasAbove = y > 0
                switch filter {
                case .none:
                    break
                case .sub:
                    for column in stride..<max(stride, rowBytes) {
                        buffer[row + column] &+= buffer[row + column - stride]
                    }
                case .up:
                    guard hasAbove else { break }
                    for column in 0..<rowBytes {
                        buffer[row + column] &+= buffer[above + column]
                    }
                case .average:
                    for column in 0..<rowBytes {
                        let left = column >= stride ? Int(buffer[row + column - stride]) : 0
                        let up = hasAbove ? Int(buffer[above + column]) : 0
                        buffer[row + column] &+= UInt8(truncatingIfNeeded: (left + up) / 2)
                    }
                case .paeth:
                    for column in 0..<rowBytes {
                        let left = column >= stride ? buffer[row + column - stride] : 0
                        let up = hasAbove ? buffer[above + column] : 0
                        let upLeft = hasAbove && column >= stride ? buffer[above + column - stride] : 0
                        buffer[row + column] &+= paeth(left: left, up: up, upLeft: upLeft)
                    }
                }
            }
        }
    }

    /// §9.4: the neighbour nearest the linear prediction left + up −
    /// up-left, ties going left, then up.
    private static func paeth(left: UInt8, up: UInt8, upLeft: UInt8) -> UInt8 {
        let estimate = Int(left) + Int(up) - Int(upLeft)
        let toLeft = abs(estimate - Int(left)), toUp = abs(estimate - Int(up)), toUpLeft = abs(estimate - Int(upLeft))
        if toLeft <= toUp, toLeft <= toUpLeft { return left }
        return toUp <= toUpLeft ? up : upLeft
    }

    // MARK: - Interlacing (§8.2)

    /// §8.2 Table 8.1: Adam7's seven passes, each a reduced image of every
    /// `columnStep`-th pixel of every `rowStep`-th row.
    private enum Adam7 {
        struct Pass {
            var firstColumn: Int
            var firstRow: Int
            var columnStep: Int
            var rowStep: Int

            func size(width: Int, height: Int) -> (width: Int, height: Int) {
                (width > firstColumn ? (width - firstColumn + columnStep - 1) / columnStep : 0,
                 height > firstRow ? (height - firstRow + rowStep - 1) / rowStep : 0)
            }
        }

        static let passes = [
            Pass(firstColumn: 0, firstRow: 0, columnStep: 8, rowStep: 8),
            Pass(firstColumn: 4, firstRow: 0, columnStep: 8, rowStep: 8),
            Pass(firstColumn: 0, firstRow: 4, columnStep: 4, rowStep: 8),
            Pass(firstColumn: 2, firstRow: 0, columnStep: 4, rowStep: 4),
            Pass(firstColumn: 0, firstRow: 2, columnStep: 2, rowStep: 4),
            Pass(firstColumn: 1, firstRow: 0, columnStep: 2, rowStep: 2),
            Pass(firstColumn: 0, firstRow: 1, columnStep: 1, rowStep: 2),
        ]

        /// An image without interlacing, as one pass of every pixel.
        static let whole = Pass(firstColumn: 0, firstRow: 0, columnStep: 1, rowStep: 1)
    }

    // MARK: - Samples to pixels (§7.1, §13.12)

    private struct Pixel {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8

        static let channels = 4
        static let opaque = UInt8.max
    }

    /// Sample `index` of the unfiltered row at `row`: packed most
    /// significant bits first below eight bits, big-endian pairs at
    /// sixteen (§7.1, §7.2).
    private static func sample(_ bytes: UnsafeBufferPointer<UInt8>, row: Int, index: Int, depth: Int) -> Int {
        switch depth {
        case UInt8.bitWidth:
            return Int(bytes[row + index])
        case UInt16.bitWidth:
            return Int(bytes[row + index * 2]) << UInt8.bitWidth | Int(bytes[row + index * 2 + 1])
        default:
            let bit = index * depth
            let shift = UInt8.bitWidth - depth - bit % UInt8.bitWidth
            return Int(bytes[row + bit / UInt8.bitWidth] >> shift) & ((1 << depth) - 1)
        }
    }

    /// A sample at `depth` scaled to eight bits, rounded: §13.12's
    /// `output = round(input × 255 / maximum)`.
    private static func eightBit(_ value: Int, depth: Int) -> UInt8 {
        if depth == UInt8.bitWidth { return UInt8(truncatingIfNeeded: value) }
        let maximum = (1 << depth) - 1
        return UInt8(truncatingIfNeeded: (value * Int(UInt8.max) + maximum / 2) / maximum)
    }

    /// Write the `count` pixels of the unfiltered row at `row` into `rgba`
    /// from `target`, `step` bytes apart.
    private static func expand(_ raw: [UInt8], row: Int, count: Int, header: Header, palette: [Pixel],
                               key: TransparencyKey?, into rgba: inout [UInt8], at target: Int, step: Int) {
        let depth = header.depth
        let channels = header.colourType.channels
        raw.withUnsafeBufferPointer { bytes in
            rgba.withUnsafeMutableBufferPointer { output in
                var out = target
                for x in 0..<count {
                    switch header.colourType {
                    case .indexed:
                        let colour = palette[sample(bytes, row: row, index: x, depth: depth)]
                        output[out] = colour.red
                        output[out + 1] = colour.green
                        output[out + 2] = colour.blue
                        output[out + 3] = colour.alpha
                    case .greyscale:
                        let grey = sample(bytes, row: row, index: x, depth: depth)
                        let level = eightBit(grey, depth: depth)
                        output[out] = level
                        output[out + 1] = level
                        output[out + 2] = level
                        let isKey = key.map { $0.red == grey } ?? false
                        output[out + 3] = isKey ? 0 : Pixel.opaque
                    case .greyscaleAlpha:
                        let level = eightBit(sample(bytes, row: row, index: x * channels, depth: depth), depth: depth)
                        output[out] = level
                        output[out + 1] = level
                        output[out + 2] = level
                        output[out + 3] = eightBit(sample(bytes, row: row, index: x * channels + 1, depth: depth),
                                                   depth: depth)
                    case .truecolour:
                        let red = sample(bytes, row: row, index: x * channels, depth: depth)
                        let green = sample(bytes, row: row, index: x * channels + 1, depth: depth)
                        let blue = sample(bytes, row: row, index: x * channels + 2, depth: depth)
                        output[out] = eightBit(red, depth: depth)
                        output[out + 1] = eightBit(green, depth: depth)
                        output[out + 2] = eightBit(blue, depth: depth)
                        let isKey = key.map { $0.red == red && $0.green == green && $0.blue == blue } ?? false
                        output[out + 3] = isKey ? 0 : Pixel.opaque
                    case .truecolourAlpha:
                        for channel in 0..<channels {
                            output[out + channel] = eightBit(sample(bytes, row: row, index: x * channels + channel,
                                                                    depth: depth), depth: depth)
                        }
                    }
                    out += step
                }
            }
        }
    }
}

/// ISO 3309 / ITU-T V.42's CRC-32, reflected, polynomial 0xEDB88320 — the
/// CRC every PNG chunk carries (PNG §5.5, Annex D).
enum CRC32 {
    private static let polynomial: UInt32 = 0xEDB8_8320
    private static let tableSize = 256

    private static let table: [UInt32] = (0..<UInt32(tableSize)).map { index in
        (0..<UInt8.bitWidth).reduce(index) { value, _ in value & 1 == 1 ? polynomial ^ (value >> 1) : value >> 1 }
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        let table = table
        var crc = ~UInt32(0)
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & UInt32(UInt8.max))] ^ (crc >> UInt8.bitWidth)
        }
        return ~crc
    }
}

/// RFC 1950 §8.2's Adler-32: two sums modulo 65521, the largest prime
/// below 2^16.
enum Adler32 {
    private static let modulus: UInt32 = 65_521
    /// The most bytes summed before a reduction keeps the larger sum
    /// within 32 bits (zlib's NMAX).
    private static let blockLength = 5_552

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1, high: UInt32 = 0
        var start = 0
        while start < bytes.count {
            let end = min(start + blockLength, bytes.count)
            for index in start..<end {
                low += UInt32(bytes[index])
                high += low
            }
            low %= modulus
            high %= modulus
            start = end
        }
        return high << UInt16.bitWidth | low
    }
}
