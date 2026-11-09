/// GIF89a §23's disposal methods: what becomes of a frame's rectangle
/// before the next frame is drawn.
package enum GIFDisposal: UInt8, Sendable {
    /// 0: the decoder chooses.
    case unspecified = 0
    /// 1: left in place, so the next frame draws over it — what a frame
    /// of only the changed rectangle relies on.
    case keep = 1
    /// 2: cleared to the background colour.
    case restoreBackground = 2
    /// 3: returned to what was there before the frame.
    case restorePrevious = 3
}

/// One frame of an animation: a rectangle of the logical screen in palette
/// indices, drawn for `delayCentiseconds` before the next.
package struct GIFFrame: Sendable {
    package var left: Int
    package var top: Int
    package var width: Int
    package var height: Int
    package var indices: [UInt8]
    /// The frame's own colour table (§21), else the global one.
    package var localPalette: [RGBA]?
    /// §23: the delay is in hundredths of a second.
    package var delayCentiseconds: Int
    package var disposal: GIFDisposal
    /// An index that leaves the pixel beneath unchanged.
    package var transparentIndex: UInt8?

    package init(left: Int, top: Int, width: Int, height: Int, indices: [UInt8], localPalette: [RGBA]? = nil,
                 delayCentiseconds: Int, disposal: GIFDisposal = .unspecified, transparentIndex: UInt8? = nil) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.indices = indices
        self.localPalette = localPalette
        self.delayCentiseconds = delayCentiseconds
        self.disposal = disposal
        self.transparentIndex = transparentIndex
    }
}

/// A GIF89a encoder (the "Graphics Interchange Format, Version 89a"
/// specification, CompuServe 1990), section numbers below from it. Frames
/// arrive already in palette indices: choosing the colours is the caller's.
/// RGBA palette entries are written without their alpha.
package struct GIFWriter {
    private static let signature = Array("GIF89a".utf8)
    /// §18: colour resolution 7, i.e. 8 bits a primary in the source.
    private static let colourResolution: UInt8 = 7
    private static let tableFlag: UInt8 = 0x80
    /// §16: a zero-length sub-block ends a run of them.
    private static let blockTerminator: UInt8 = 0
    /// §15: a sub-block holds 1–255 bytes after its length byte.
    private static let maximumSubBlockLength = 255
    private static let extensionIntroducer: UInt8 = 0x21
    private static let graphicControlLabel: UInt8 = 0xF9
    private static let graphicControlLength: UInt8 = 4
    private static let applicationLabel: UInt8 = 0xFF
    private static let imageSeparator: UInt8 = 0x2C
    private static let trailer: UInt8 = 0x3B
    /// The Netscape application extension, which every browser honours for
    /// the loop count: identifier and authentication code, then sub-block 1
    /// holding the count, 0 meaning forever.
    private static let netscapeIdentifier = Array("NETSCAPE2.0".utf8)
    private static let loopSubBlockID: UInt8 = 1
    private static let loopSubBlockLength: UInt8 = 3
    /// §19: red, green, blue, a byte each.
    private static let bytesPerEntry = 3
    /// §20 and §23 store sizes, positions and delays in 16 bits.
    private static let maximumField = Int(UInt16.max)

    private let width: Int
    private let height: Int
    private let globalTableSize: Int?
    private var bytes: [UInt8]

    /// `loopCount` nil writes no loop extension, so the animation plays
    /// once; 0 loops forever.
    package init(width: Int, height: Int, globalPalette: [RGBA]?, loopCount: Int?) {
        precondition((1...Self.maximumField).contains(width) && (1...Self.maximumField).contains(height),
                     "a \(width)×\(height) screen")
        self.width = width
        self.height = height
        globalTableSize = globalPalette.map { Self.tableSize(for: $0) }
        bytes = Self.signature + Self.littleEndian(width) + Self.littleEndian(height)
        // §18: global table flag, colour resolution, sort flag 0, the
        // table's size; then background index 0 and no aspect ratio.
        if let globalPalette {
            bytes += [Self.tableFlag | Self.colourResolution << 4 | Self.sizeField(for: globalPalette), 0, 0]
            bytes += Self.table(globalPalette)
        } else {
            bytes += [Self.colourResolution << 4, 0, 0]
        }
        if let loopCount {
            precondition((0...Self.maximumField).contains(loopCount), "loop count \(loopCount)")
            bytes += [Self.extensionIntroducer, Self.applicationLabel, UInt8(Self.netscapeIdentifier.count)]
                + Self.netscapeIdentifier
                + [Self.loopSubBlockLength, Self.loopSubBlockID] + Self.littleEndian(loopCount) + [Self.blockTerminator]
        }
    }

    package mutating func append(_ frame: GIFFrame) {
        precondition(frame.width > 0 && frame.height > 0 && frame.left >= 0 && frame.top >= 0
                     && frame.left + frame.width <= width && frame.top + frame.height <= height,
                     "a \(frame.width)×\(frame.height) frame at (\(frame.left), \(frame.top)) on \(width)×\(height)")
        precondition(frame.indices.count == frame.width * frame.height, "\(frame.indices.count) indices")
        precondition((0...Self.maximumField).contains(frame.delayCentiseconds), "delay \(frame.delayCentiseconds)")
        guard let tableSize = frame.localPalette.map({ Self.tableSize(for: $0) }) ?? globalTableSize else {
            preconditionFailure("a frame with no local table and no global one")
        }
        precondition(frame.transparentIndex.map { Int($0) < tableSize } ?? true, "a transparent index past the table")
        let codeSize = max(LZW.codeSizes.lowerBound, tableSize.trailingZeroBitCount)

        // §23: reserved bits, disposal in bits 2–4, no user input, then the
        // transparency flag.
        let packed = frame.disposal.rawValue << 2 | (frame.transparentIndex == nil ? 0 : 1)
        bytes += [Self.extensionIntroducer, Self.graphicControlLabel, Self.graphicControlLength, packed]
            + Self.littleEndian(frame.delayCentiseconds)
            + [frame.transparentIndex ?? 0, Self.blockTerminator]

        // §20: position, size, then the local table flag and size; not
        // interlaced, not sorted.
        bytes.append(Self.imageSeparator)
        bytes += [frame.left, frame.top, frame.width, frame.height].flatMap(Self.littleEndian)
        if let localPalette = frame.localPalette {
            bytes.append(Self.tableFlag | Self.sizeField(for: localPalette))
            bytes += Self.table(localPalette)
        } else {
            bytes.append(0)
        }

        // §22: the minimum code size, then the codes in sub-blocks.
        bytes.append(UInt8(codeSize))
        let codes = LZW.encode(frame.indices, minimumCodeSize: codeSize)
        for start in stride(from: 0, to: codes.count, by: Self.maximumSubBlockLength) {
            let end = min(start + Self.maximumSubBlockLength, codes.count)
            bytes.append(UInt8(end - start))
            bytes += codes[start..<end]
        }
        bytes.append(Self.blockTerminator)
    }

    /// The file, ended with the trailer (§27).
    package consuming func finish() -> [UInt8] {
        bytes.append(Self.trailer)
        return bytes
    }

    /// §19, §21: a table holds 2^(n+1) entries, n 0–7, so a palette is
    /// padded to the next power of two, at least 2.
    private static func tableSize(for palette: [RGBA]) -> Int {
        precondition((1...IndexedImage.maximumPaletteCount).contains(palette.count), "a palette of \(palette.count)")
        var size = 2
        while size < palette.count { size *= 2 }
        return size
    }

    private static func sizeField(for palette: [RGBA]) -> UInt8 {
        UInt8(tableSize(for: palette).trailingZeroBitCount - 1)
    }

    /// The padding entries are black.
    private static func table(_ palette: [RGBA]) -> [UInt8] {
        palette.flatMap { [$0.red, $0.green, $0.blue] }
            + [UInt8](repeating: 0, count: bytesPerEntry * (tableSize(for: palette) - palette.count))
    }

    /// §4: GIF's integers are little-endian.
    private static func littleEndian(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}
