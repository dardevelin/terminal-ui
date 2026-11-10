import Foundation

/// A pure-Swift decoder of baseline JPEG (ITU-T T.81 | ISO/IEC 10918-1),
/// so a picture decodes to the same pixels on every system.
///
/// It reads sequential DCT images of 8-bit samples with Huffman coding —
/// baseline (SOF0) and extended sequential (SOF1), whose quantisation
/// tables may be 16-bit:
///
/// - greyscale, and YCbCr as JFIF defines it (ITU-T T.871), or RGB where
///   an Adobe APP14 segment or the component ids say so;
/// - any sampling factors that divide the largest (4:4:4, 4:2:2, 4:2:0,
///   4:4:0 …), chroma upsampled by linear interpolation between sample
///   centres, as libjpeg's default "fancy" upsampling is;
/// - interleaved scans and one scan per component, restart intervals, fill
///   bytes, and sizes that are no multiple of a block.
///
/// It refuses, with a reason saying so: progressive, lossless and
/// hierarchical JPEG, arithmetic coding, 12-bit samples, CMYK and other
/// component counts, and a height left to a DNL marker. Malformed input
/// throws; it never traps.
///
/// ```swift
/// let image = try JPEGDecoder().decode(Data(contentsOf: url))
/// ```
public struct JPEGDecoder: ImageDecoder {
    /// The pixel count a decoder refuses images beyond unless told
    /// otherwise: 2^26, about 67 million — an 8192 × 8192 image, a
    /// 256 MB buffer.
    public static let defaultMaximumPixelCount = 1 << 26

    /// The most pixels an image may have. A frame header that claims more
    /// is refused before anything is allocated for it, so a hostile
    /// file's dimensions bound what decoding it allocates.
    public let maximumPixelCount: Int

    /// A decoder that refuses images of more than `maximumPixelCount`
    /// pixels.
    public init(maximumPixelCount: Int = JPEGDecoder.defaultMaximumPixelCount) {
        self.maximumPixelCount = maximumPixelCount
    }

    /// Decode `data`, which must begin with a JPEG's SOI marker, into
    /// straight RGBA, every pixel opaque.
    ///
    /// - Throws: ``ImageDecodeError/unsupportedFormat(magic:)`` when the
    ///   bytes do not start with SOI, and
    ///   ``ImageDecodeError/malformedData(reason:)`` when they are not a
    ///   JPEG this decoder reads, with a reason that names what it does
    ///   not support.
    public func decode(_ data: Data) throws(ImageDecodeError) -> ImageBuffer {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == JPEGMarker.prefix, bytes[1] == JPEGMarker.startOfImage else {
            throw .unsupportedFormat(magic: Array(bytes.prefix(JPEGMarker.magicLength)))
        }
        var parser = JPEGParser(bytes: bytes, maximumPixelCount: maximumPixelCount)
        return try parser.decode()
    }
}

/// T.81 Table B.1's marker codes, the second byte after 0xFF.
enum JPEGMarker {
    static let prefix: UInt8 = 0xFF
    /// B.1.1.5: a 0xFF of entropy-coded data is followed by 0x00.
    static let stuffedZero: UInt8 = 0x00
    /// The bytes an unsupported format reports as its magic.
    static let magicLength = 4

    static let startOfImage: UInt8 = 0xD8
    static let endOfImage: UInt8 = 0xD9
    static let startOfScan: UInt8 = 0xDA
    static let quantisationTables: UInt8 = 0xDB
    static let huffmanTables: UInt8 = 0xC4
    static let arithmeticConditioning: UInt8 = 0xCC
    static let restartInterval: UInt8 = 0xDD
    static let numberOfLines: UInt8 = 0xDC
    static let baseline: UInt8 = 0xC0
    static let extendedSequential: UInt8 = 0xC1
    static let progressive: UInt8 = 0xC2
    /// SOF3 and SOF5 to SOF15 but DHT (C4), JPG (C8) and DAC (CC): the
    /// lossless, hierarchical and arithmetic-coded frames.
    static let otherFrames: Set<UInt8> = [0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
    /// RST0 to RST7.
    static let restart0: UInt8 = 0xD0
    static let restartCount = 8
    /// B.1.1.4: TEM, and RSTm outside a scan, stand alone, without a
    /// length.
    static let temporary: UInt8 = 0x01
    static let restartRange: ClosedRange<UInt8> = 0xD0...0xD7
    static let adobe: UInt8 = 0xEE
}

/// A frame component (T.81 B.2.2): its id, sampling factors and table.
private struct JPEGComponent {
    var id: UInt8
    var horizontal: Int
    var vertical: Int
    var quantisationTable: Int
    /// Samples, whole MCUs' worth across and down.
    var plane: [UInt8] = []
    var stride = 0
    /// Blocks across and down that cover the component's share of the
    /// image (T.81 A.2.2: what a scan of it alone codes).
    var blocksAcross = 0
    var blocksDown = 0
    /// Samples across and down that the image covers (A.1.1).
    var samplesAcross = 0
    var samplesDown = 0
    var isDecoded = false
}

private struct JPEGFrame {
    var width: Int
    var height: Int
    var components: [JPEGComponent]
    var largestHorizontal: Int
    var largestVertical: Int
    var mcusAcross: Int
    var mcusDown: Int
}

private struct JPEGParser {
    private let bytes: [UInt8]
    private var position = 2
    private var quantisation: [[Float]?] = Array(repeating: nil, count: Limits.tables)
    private var dcTables: [JPEGHuffmanTable?] = Array(repeating: nil, count: Limits.tables)
    private var acTables: [JPEGHuffmanTable?] = Array(repeating: nil, count: Limits.tables)
    private var restartInterval = 0
    private var frame: JPEGFrame?
    /// Adobe APP14's transform flag: 0 for components stored as they are
    /// (RGB), 1 for YCbCr.
    private var adobeTransform: UInt8?

    private enum Limits {
        /// B.2.4.1, B.2.4.2: table destinations 0 to 3.
        static let tables = 4
        /// B.2.2: sampling factors 1 to 4.
        static let samplingFactors = 1...4
        /// B.2.2: 8-bit samples for the DCT processes this reads.
        static let samplePrecision = 8
        /// B.2.4.1: Pq is 0 for 8-bit table entries and 1 for 16-bit.
        static let wideTableEntries = 1
        /// Greyscale and three-component colour.
        static let componentCounts: Set<Int> = [1, 3]
        /// Adobe's CMYK and YCCK.
        static let cmykComponents = 4
        static let lengthFieldSize = 2
        /// B.2.4.2: Tc is 0 for a DC table, 1 for an AC table.
        static let acTableClass = 1
        static let nibbleBits = 4
        static let lowNibble: UInt8 = 0x0F
    }

    /// T.81 B.2.3: a sequential scan codes coefficients 0 to 63 with no
    /// successive approximation.
    private enum SequentialScan {
        static let spectralEnd = 63
    }

    /// Ids of the components' letters, which some encoders of RGB JPEG
    /// write instead of an APP14 segment, as libjpeg reads them.
    private static let rgbComponentIDs: [UInt8] = [0x52, 0x47, 0x42]
    private static let adobeSignature: [UInt8] = Array("Adobe".utf8)
    /// APP14: "Adobe", version (2), flags0 (2), flags1 (2), transform.
    private static let adobeTransformOffset = 11

    /// RGBA's four bytes a pixel, the last alpha.
    private static let channels = 4
    private static let opaque: UInt8 = 255

    private let maximumPixelCount: Int

    init(bytes: [UInt8], maximumPixelCount: Int) {
        self.bytes = bytes
        self.maximumPixelCount = maximumPixelCount
    }

    mutating func decode() throws(ImageDecodeError) -> ImageBuffer {
        while true {
            let marker = try nextMarker()
            switch marker {
            case JPEGMarker.endOfImage:
                return try finish()
            case JPEGMarker.startOfImage, JPEGMarker.temporary, JPEGMarker.restartRange:
                continue
            case JPEGMarker.baseline, JPEGMarker.extendedSequential:
                try readFrame(try segment())
            case JPEGMarker.progressive:
                throw .malformedData(reason: "progressive JPEG is not supported")
            case JPEGMarker.arithmeticConditioning:
                throw .malformedData(reason: "arithmetic-coded JPEG is not supported")
            case let code where JPEGMarker.otherFrames.contains(code):
                throw .malformedData(reason: "lossless, hierarchical and arithmetic-coded JPEG are not supported")
            case JPEGMarker.quantisationTables:
                try readQuantisationTables(try segment())
            case JPEGMarker.huffmanTables:
                try readHuffmanTables(try segment())
            case JPEGMarker.restartInterval:
                let body = try segment()
                guard body.count >= Limits.lengthFieldSize else {
                    throw .malformedData(reason: "a DRI segment is too short")
                }
                restartInterval = Int(bytes[body.lowerBound]) << UInt8.bitWidth | Int(bytes[body.lowerBound + 1])
            case JPEGMarker.numberOfLines:
                throw .malformedData(reason: "a height given by a DNL marker is not supported")
            case JPEGMarker.adobe:
                readAdobe(try segment())
            case JPEGMarker.startOfScan:
                try readScan(try segment())
            default:
                _ = try segment()
            }
        }
    }

    // MARK: - Markers and segments

    /// The code of the next marker, past any fill bytes (B.1.1.2) and any
    /// stray data before it.
    private mutating func nextMarker() throws(ImageDecodeError) -> UInt8 {
        while true {
            while position < bytes.count, bytes[position] != JPEGMarker.prefix {
                position += 1
            }
            while position < bytes.count, bytes[position] == JPEGMarker.prefix {
                position += 1
            }
            guard position < bytes.count else {
                throw .malformedData(reason: "the image ends before its EOI marker")
            }
            let code = bytes[position]
            position += 1
            if code != JPEGMarker.stuffedZero { return code }
        }
    }

    /// The body of the segment the marker just read begins, after its
    /// length (B.1.1.4), which counts itself.
    private mutating func segment() throws(ImageDecodeError) -> Range<Int> {
        guard position + Limits.lengthFieldSize <= bytes.count else {
            throw .malformedData(reason: "a marker segment is truncated")
        }
        let length = Int(bytes[position]) << UInt8.bitWidth | Int(bytes[position + 1])
        guard length >= Limits.lengthFieldSize, position + length <= bytes.count else {
            throw .malformedData(reason: "a marker segment's length runs past the data")
        }
        let body = (position + Limits.lengthFieldSize)..<(position + length)
        position += length
        return body
    }

    // MARK: - Tables

    /// B.2.4.1: one or more tables, each a Pq/Tq byte and 64 entries in
    /// zig-zag order.
    private mutating func readQuantisationTables(_ body: Range<Int>) throws(ImageDecodeError) {
        var cursor = body.lowerBound
        while cursor < body.upperBound {
            let precision = Int(bytes[cursor] >> Limits.nibbleBits)
            let destination = Int(bytes[cursor] & Limits.lowNibble)
            cursor += 1
            guard precision <= Limits.wideTableEntries, destination < Limits.tables else {
                throw .malformedData(reason: "a quantisation table has an unknown precision or destination")
            }
            let entrySize = precision == Limits.wideTableEntries ? 2 : 1
            guard body.upperBound - cursor >= JPEGBlock.count * entrySize else {
                throw .malformedData(reason: "a quantisation table is truncated")
            }
            var table = [Float](repeating: 0, count: JPEGBlock.count)
            for index in 0..<JPEGBlock.count {
                if entrySize == 2 {
                    table[index] = Float(Int(bytes[cursor]) << UInt8.bitWidth | Int(bytes[cursor + 1]))
                } else {
                    table[index] = Float(bytes[cursor])
                }
                cursor += entrySize
            }
            quantisation[destination] = table
        }
    }

    /// B.2.4.2: one or more tables, each a Tc/Th byte, 16 counts and the
    /// symbols.
    private mutating func readHuffmanTables(_ body: Range<Int>) throws(ImageDecodeError) {
        var cursor = body.lowerBound
        while cursor < body.upperBound {
            let tableClass = Int(bytes[cursor] >> Limits.nibbleBits)
            let destination = Int(bytes[cursor] & Limits.lowNibble)
            cursor += 1
            guard tableClass <= Limits.acTableClass, destination < Limits.tables else {
                throw .malformedData(reason: "a Huffman table has an unknown class or destination")
            }
            guard body.upperBound - cursor >= JPEGHuffmanTable.longestCode else {
                throw .malformedData(reason: "a Huffman table is truncated")
            }
            let counts = bytes[cursor..<(cursor + JPEGHuffmanTable.longestCode)].map(Int.init)
            cursor += JPEGHuffmanTable.longestCode
            let symbolCount = counts.reduce(0, +)
            guard body.upperBound - cursor >= symbolCount else {
                throw .malformedData(reason: "a Huffman table is truncated")
            }
            let table = try JPEGHuffmanTable(counts: counts, symbols: Array(bytes[cursor..<(cursor + symbolCount)]))
            cursor += symbolCount
            if tableClass == Limits.acTableClass {
                acTables[destination] = table
            } else {
                dcTables[destination] = table
            }
        }
    }

    private mutating func readAdobe(_ body: Range<Int>) {
        let signature = Self.adobeSignature
        guard body.count > Self.adobeTransformOffset,
              Array(bytes[body.lowerBound..<(body.lowerBound + signature.count)]) == signature else { return }
        adobeTransform = bytes[body.lowerBound + Self.adobeTransformOffset]
    }

    // MARK: - Frame

    /// B.2.2: precision, height, width, then each component's id,
    /// sampling factors and quantisation table.
    private mutating func readFrame(_ body: Range<Int>) throws(ImageDecodeError) {
        guard frame == nil else { throw .malformedData(reason: "the image has more than one frame") }
        let headerSize = HeaderLayout.frameFields, componentSize = HeaderLayout.frameComponent
        guard body.count >= headerSize else { throw .malformedData(reason: "a frame header is truncated") }
        let start = body.lowerBound
        guard Int(bytes[start]) == Limits.samplePrecision else {
            throw .malformedData(reason: "only 8-bit samples are supported")
        }
        let height = Int(bytes[start + 1]) << UInt8.bitWidth | Int(bytes[start + 2])
        let width = Int(bytes[start + 3]) << UInt8.bitWidth | Int(bytes[start + 4])
        let count = Int(bytes[start + 5])
        guard height > 0 else { throw .malformedData(reason: "a height given by a DNL marker is not supported") }
        guard width > 0 else { throw .malformedData(reason: "the image has no width") }
        guard width * height <= maximumPixelCount else {
            throw .tooManyPixels(format: "JPEG", width: width, height: height, maximum: maximumPixelCount)
        }
        guard Limits.componentCounts.contains(count) else {
            throw .malformedData(reason: count == Limits.cmykComponents ? "CMYK JPEG is not supported"
                                 : "only greyscale and three-component JPEG are supported")
        }
        guard body.count >= headerSize + count * componentSize else {
            throw .malformedData(reason: "a frame header is truncated")
        }
        var components: [JPEGComponent] = []
        for index in 0..<count {
            let offset = start + headerSize + index * componentSize
            let horizontal = Int(bytes[offset + 1] >> Limits.nibbleBits)
            let vertical = Int(bytes[offset + 1] & Limits.lowNibble)
            let table = Int(bytes[offset + 2])
            guard Limits.samplingFactors.contains(horizontal), Limits.samplingFactors.contains(vertical) else {
                throw .malformedData(reason: "a component's sampling factors are out of range")
            }
            guard table < Limits.tables else {
                throw .malformedData(reason: "a component names an unknown quantisation table")
            }
            guard !components.contains(where: { $0.id == bytes[offset] }) else {
                throw .malformedData(reason: "two components share an id")
            }
            components.append(JPEGComponent(id: bytes[offset], horizontal: horizontal, vertical: vertical,
                                            quantisationTable: table))
        }
        let largestHorizontal = components.map(\.horizontal).max() ?? 1
        let largestVertical = components.map(\.vertical).max() ?? 1
        guard components.allSatisfy({ largestHorizontal % $0.horizontal == 0
                                        && largestVertical % $0.vertical == 0 }) else {
            throw .malformedData(reason: "sampling factors that do not divide the largest are not supported")
        }
        // A.2.4: an interleaved MCU is each component's H × V blocks.
        let mcuWidth = JPEGBlock.side * largestHorizontal, mcuHeight = JPEGBlock.side * largestVertical
        let mcusAcross = (width + mcuWidth - 1) / mcuWidth
        let mcusDown = (height + mcuHeight - 1) / mcuHeight
        for index in components.indices {
            let horizontal = components[index].horizontal, vertical = components[index].vertical
            components[index].stride = mcusAcross * horizontal * JPEGBlock.side
            components[index].plane = [UInt8](repeating: 0,
                                              count: components[index].stride * mcusDown * vertical * JPEGBlock.side)
            // A.1.1: x_i = ⌈X · H_i / H_max⌉, and likewise down.
            components[index].samplesAcross = (width * horizontal + largestHorizontal - 1) / largestHorizontal
            components[index].samplesDown = (height * vertical + largestVertical - 1) / largestVertical
            components[index].blocksAcross = (components[index].samplesAcross + JPEGBlock.side - 1) / JPEGBlock.side
            components[index].blocksDown = (components[index].samplesDown + JPEGBlock.side - 1) / JPEGBlock.side
        }
        frame = JPEGFrame(width: width, height: height, components: components,
                          largestHorizontal: largestHorizontal, largestVertical: largestVertical,
                          mcusAcross: mcusAcross, mcusDown: mcusDown)
    }

    // MARK: - Scan

    /// A component of a scan and the tables it decodes with.
    private struct ScanComponent {
        var index: Int
        var dc: JPEGHuffmanTable
        var ac: JPEGHuffmanTable
        var quantisation: [Float]
        var prediction = 0
    }

    /// B.2.3: the scan header, then its entropy-coded data, which runs to
    /// the next marker that is not a restart.
    private mutating func readScan(_ body: Range<Int>) throws(ImageDecodeError) {
        guard var frame else { throw .malformedData(reason: "a scan comes before the frame header") }
        // Taken out, so its planes have one owner and the scan writes them
        // in place rather than copying each on its first write; put back
        // at the end. A scan that throws ends the decode.
        self.frame = nil
        let componentSize = HeaderLayout.scanComponent, trailerSize = HeaderLayout.scanTrailer
        guard let count = body.isEmpty ? nil : Int(bytes[body.lowerBound]),
              (1...frame.components.count).contains(count),
              body.count >= 1 + count * componentSize + trailerSize else {
            throw .malformedData(reason: "a scan header is malformed")
        }
        var scanComponents: [ScanComponent] = []
        for order in 0..<count {
            let offset = body.lowerBound + 1 + order * componentSize
            guard let index = frame.components.firstIndex(where: { $0.id == bytes[offset] }),
                  !scanComponents.contains(where: { $0.index == index }) else {
                throw .malformedData(reason: "a scan names a component the frame does not have")
            }
            guard !frame.components[index].isDecoded else {
                throw .malformedData(reason: "a component is coded in more than one scan")
            }
            let dcIndex = Int(bytes[offset + 1] >> Limits.nibbleBits)
            let acIndex = Int(bytes[offset + 1] & Limits.lowNibble)
            guard dcIndex < Limits.tables, acIndex < Limits.tables,
                  let dc = dcTables[dcIndex], let ac = acTables[acIndex] else {
                throw .malformedData(reason: "a scan uses a Huffman table that was never defined")
            }
            guard let table = quantisation[frame.components[index].quantisationTable] else {
                throw .malformedData(reason: "a component uses a quantisation table that was never defined")
            }
            scanComponents.append(ScanComponent(index: index, dc: dc, ac: ac, quantisation: table))
        }
        let trailer = body.lowerBound + 1 + count * componentSize
        guard bytes[trailer] == 0, Int(bytes[trailer + 1]) == SequentialScan.spectralEnd,
              bytes[trailer + 2] == 0 else {
            throw .malformedData(reason: "a scan of part of the spectrum: progressive JPEG is not supported")
        }

        var reader = JPEGEntropyReader(bytes: bytes, position: position)
        // A.2.2: a scan of one component codes its blocks one at a time,
        // left to right and top to bottom; A.2.3: a scan of several codes
        // MCUs of each one's H × V blocks.
        let interleaved = count > 1
        let unitsAcross = interleaved ? frame.mcusAcross : frame.components[scanComponents[0].index].blocksAcross
        let unitsDown = interleaved ? frame.mcusDown : frame.components[scanComponents[0].index].blocksDown
        var coefficients = [Float](repeating: 0, count: JPEGBlock.count)
        var rowPass = [Float](repeating: 0, count: JPEGBlock.count)
        var unitsInInterval = 0
        var restartIndex = 0
        for unitRow in 0..<unitsDown {
            for unitColumn in 0..<unitsAcross {
                if restartInterval > 0, unitsInInterval == restartInterval {
                    try reader.restart(expecting: restartIndex)
                    restartIndex += 1
                    unitsInInterval = 0
                    for index in scanComponents.indices { scanComponents[index].prediction = 0 }
                }
                unitsInInterval += 1
                for order in scanComponents.indices {
                    let index = scanComponents[order].index
                    let blocksAcross = interleaved ? frame.components[index].horizontal : 1
                    let blocksDown = interleaved ? frame.components[index].vertical : 1
                    for blockRow in 0..<blocksDown {
                        for blockColumn in 0..<blocksAcross {
                            let hasAC = try Self.decodeBlock(&scanComponents[order], from: &reader,
                                                             into: &coefficients)
                            let row = unitRow * blocksDown + blockRow
                            let column = unitColumn * blocksAcross + blockColumn
                            let stride = frame.components[index].stride
                            JPEGBlock.inverseTransform(coefficients, hasAC: hasAC, rows: &rowPass,
                                                       into: &frame.components[index].plane,
                                                       offset: row * JPEGBlock.side * stride + column * JPEGBlock.side,
                                                       stride: stride)
                        }
                    }
                }
            }
        }
        for component in scanComponents { frame.components[component.index].isDecoded = true }
        self.frame = frame
        position = reader.position
    }

    /// T.81 F.2.2: one block's DC difference and AC run/size pairs,
    /// dequantised into `coefficients` in natural order. Returns whether
    /// any AC coefficient was coded.
    private static func decodeBlock(_ component: inout ScanComponent, from reader: inout JPEGEntropyReader,
                                    into coefficients: inout [Float]) throws(ImageDecodeError) -> Bool {
        coefficients.replaceSubrange(0..<JPEGBlock.count, with: repeatElement(0, count: JPEGBlock.count))
        let size = Int(try component.dc.decode(from: &reader))
        component.prediction += try reader.receiveExtended(size)
        coefficients[0] = Float(component.prediction) * component.quantisation[0]
        var hasAC = false
        var index = 1
        while index < JPEGBlock.count {
            let symbol = try component.ac.decode(from: &reader)
            let run = Int(symbol >> Limits.nibbleBits), bits = Int(symbol & Limits.lowNibble)
            if bits == 0 {
                // F.1.2.2: (15, 0) is a run of sixteen zeros, any other
                // run with no bits ends the block.
                guard run == ACSymbol.zeroRunLength else { break }
                index += ACSymbol.zeroRun
                continue
            }
            index += run
            guard index < JPEGBlock.count else {
                throw .malformedData(reason: "a block's coefficients run past its 64")
            }
            coefficients[JPEGBlock.zigZag[index]] = Float(try reader.receiveExtended(bits))
                * component.quantisation[index]
            hasAC = true
            index += 1
        }
        return hasAC
    }

    /// B.2.2 and B.2.3: the fixed fields of the frame and scan headers.
    private enum HeaderLayout {
        /// P, Y (2), X (2), Nf.
        static let frameFields = 6
        /// C, H/V, Tq.
        static let frameComponent = 3
        /// Cs, Td/Ta.
        static let scanComponent = 2
        /// Ss, Se, Ah/Al.
        static let scanTrailer = 3
    }

    private enum ACSymbol {
        /// F.1.2.2.1: ZRL, the symbol 0xF0.
        static let zeroRunLength = 15
        static let zeroRun = 16
    }

    // MARK: - Output

    private func finish() throws(ImageDecodeError) -> ImageBuffer {
        guard let frame else { throw .malformedData(reason: "the image has no frame header") }
        guard frame.components.allSatisfy(\.isDecoded) else {
            throw .malformedData(reason: "the image ends before every component is coded")
        }
        let width = frame.width, height = frame.height
        var rgba = [UInt8](repeating: Self.opaque, count: width * height * Self.channels)
        let axes = frame.components.map { component in
            (across: JPEGUpsamplingAxis(outputCount: width, factor: frame.largestHorizontal / component.horizontal,
                                        sampleCount: component.samplesAcross),
             down: JPEGUpsamplingAxis(outputCount: height, factor: frame.largestVertical / component.vertical,
                                      sampleCount: component.samplesDown))
        }
        let isGrey = frame.components.count == 1
        let isRGB = !isGrey && (adobeTransform == 0
                                || (adobeTransform == nil && frame.components.map(\.id) == Self.rgbComponentIDs))
        var rows = Array(repeating: [Float](repeating: 0, count: width), count: frame.components.count)
        var vertical = [Float](repeating: 0, count: frame.components.map(\.samplesAcross).max() ?? 0)
        for y in 0..<height {
            for index in frame.components.indices {
                JPEGUpsampling.row(y, of: frame.components[index].plane, stride: frame.components[index].stride,
                                   across: axes[index].across, down: axes[index].down,
                                   vertical: &vertical, into: &rows[index])
            }
            var offset = y * width * Self.channels
            var x = 0
            while x < width {
                if isGrey {
                    let grey = JPEGBlock.clamped(rows[0][x])
                    rgba[offset] = grey
                    rgba[offset + 1] = grey
                    rgba[offset + 2] = grey
                } else if isRGB {
                    rgba[offset] = JPEGBlock.clamped(rows[0][x])
                    rgba[offset + 1] = JPEGBlock.clamped(rows[1][x])
                    rgba[offset + 2] = JPEGBlock.clamped(rows[2][x])
                } else {
                    let (red, green, blue) = JFIFColour.rgb(luma: rows[0][x], blueDifference: rows[1][x],
                                                           redDifference: rows[2][x])
                    rgba[offset] = red
                    rgba[offset + 1] = green
                    rgba[offset + 2] = blue
                }
                offset += Self.channels
                x += 1
            }
        }
        do {
            return try ImageBuffer(rgba: rgba, width: width, height: height)
        } catch {
            throw .malformedData(reason: "the decoded pixels do not fill the image")
        }
    }
}
