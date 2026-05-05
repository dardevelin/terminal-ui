import Foundation

// HYP-304 (Slice 297a) — pure-Swift RFC 1951 deflate decoder. Used
// by the PNG decoder (Slice 297b) for IDAT-chunk decompression.
// Zero external dependencies: works identically on macOS + Linux.
//
// Algorithm (RFC 1951):
//   - Bit-level reader (LSB-first within bytes).
//   - Three block types: stored / fixed-Huffman / dynamic-Huffman.
//   - LZ77 back-references with 32KB sliding window.
//   - Length codes 257-285 + distance codes 0-29 per spec tables.
//
// API: `Inflate.decode(data) throws(InflateError) -> Data`.
// Caller is responsible for stripping zlib wrapping if present
// (PNG IDAT data is zlib-wrapped; the wrapper sits above this).

public enum Inflate {

    /// Decode a raw deflate stream into the original bytes.
    /// Input is the deflate stream itself (no zlib wrapping).
    public static func decode(_ data: Data) throws(InflateError) -> Data {
        var reader = BitReader(data: data)
        var output = Data()
        var window = SlidingWindow()

        while true {
            let bfinal = try reader.readBits(1)
            let btype = try reader.readBits(2)

            switch btype {
            case 0:
                try readStoredBlock(reader: &reader, output: &output, window: &window)
            case 1:
                try readHuffmanBlock(
                    reader: &reader,
                    output: &output,
                    window: &window,
                    literalTree: FixedHuffman.literal,
                    distanceTree: FixedHuffman.distance
                )
            case 2:
                let (literal, distance) = try readDynamicHuffmanTrees(reader: &reader)
                try readHuffmanBlock(
                    reader: &reader,
                    output: &output,
                    window: &window,
                    literalTree: literal,
                    distanceTree: distance
                )
            default:
                throw .invalidBlockType
            }

            if bfinal == 1 { break }
        }

        return output
    }

    // MARK: - Stored block

    private static func readStoredBlock(
        reader: inout BitReader,
        output: inout Data,
        window: inout SlidingWindow
    ) throws(InflateError) {
        reader.alignToByte()
        let len = try reader.readU16LE()
        let nlen = try reader.readU16LE()
        guard (len ^ 0xFFFF) == nlen else { throw .invalidStoredLength }
        for _ in 0..<len {
            let byte = try reader.readByte()
            output.append(byte)
            window.append(byte)
        }
    }

    // MARK: - Huffman block

    private static func readHuffmanBlock(
        reader: inout BitReader,
        output: inout Data,
        window: inout SlidingWindow,
        literalTree: HuffmanTree,
        distanceTree: HuffmanTree
    ) throws(InflateError) {
        while true {
            let symbol = try literalTree.decode(reader: &reader)
            if symbol < 256 {
                let byte = UInt8(symbol)
                output.append(byte)
                window.append(byte)
            } else if symbol == 256 {
                // End of block.
                return
            } else if symbol <= 285 {
                let length = try readLength(symbol: symbol, reader: &reader)
                let distSymbol = try distanceTree.decode(reader: &reader)
                let distance = try readDistance(symbol: distSymbol, reader: &reader)
                guard distance >= 1 && distance <= 32768 else {
                    throw .invalidDistance(distance)
                }
                guard length >= 3 && length <= 258 else {
                    throw .invalidLength(length)
                }
                for _ in 0..<length {
                    let byte = try window.readBack(distance: distance)
                    output.append(byte)
                    window.append(byte)
                }
            } else {
                throw .invalidHuffmanCode
            }
        }
    }

    // MARK: - Length / distance tables (RFC 1951 §3.2.5)

    private static func readLength(symbol: Int, reader: inout BitReader) throws(InflateError) -> Int {
        // Symbols 257..285. Each row: (extra-bits, base-length).
        let table: [(extraBits: Int, baseLength: Int)] = [
            (0, 3),  (0, 4),  (0, 5),   (0, 6),   (0, 7),   (0, 8),
            (0, 9),  (0, 10), (1, 11),  (1, 13),  (1, 15),  (1, 17),
            (2, 19), (2, 23), (2, 27),  (2, 31),  (3, 35),  (3, 43),
            (3, 51), (3, 59), (4, 67),  (4, 83),  (4, 99),  (4, 115),
            (5, 131), (5, 163), (5, 195), (5, 227), (0, 258)
        ]
        let index = symbol - 257
        guard index >= 0 && index < table.count else { throw .invalidHuffmanCode }
        let entry = table[index]
        let extra = entry.extraBits == 0 ? 0 : try reader.readBits(entry.extraBits)
        return entry.baseLength + extra
    }

    private static func readDistance(symbol: Int, reader: inout BitReader) throws(InflateError) -> Int {
        // Symbols 0..29. Each row: (extra-bits, base-distance).
        let table: [(extraBits: Int, baseDistance: Int)] = [
            (0, 1),     (0, 2),     (0, 3),     (0, 4),     (1, 5),
            (1, 7),     (2, 9),     (2, 13),    (3, 17),    (3, 25),
            (4, 33),    (4, 49),    (5, 65),    (5, 97),    (6, 129),
            (6, 193),   (7, 257),   (7, 385),   (8, 513),   (8, 769),
            (9, 1025),  (9, 1537),  (10, 2049), (10, 3073), (11, 4097),
            (11, 6145), (12, 8193), (12, 12289), (13, 16385), (13, 24577)
        ]
        guard symbol >= 0 && symbol < table.count else { throw .invalidHuffmanCode }
        let entry = table[symbol]
        let extra = entry.extraBits == 0 ? 0 : try reader.readBits(entry.extraBits)
        return entry.baseDistance + extra
    }

    // MARK: - Dynamic Huffman tree construction (RFC 1951 §3.2.7)

    private static func readDynamicHuffmanTrees(
        reader: inout BitReader
    ) throws(InflateError) -> (literal: HuffmanTree, distance: HuffmanTree) {
        let hlit = try reader.readBits(5) + 257   // # of literal/length codes
        let hdist = try reader.readBits(5) + 1    // # of distance codes
        let hclen = try reader.readBits(4) + 4    // # of code-length codes

        // Read the code-length code lengths (3 bits each, in special order).
        let codeLengthOrder: [Int] = [
            16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
        ]
        var codeLengthLens = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            codeLengthLens[codeLengthOrder[i]] = try reader.readBits(3)
        }
        let codeLengthTree = try HuffmanTree(codeLengths: codeLengthLens)

        // Decode literal/length + distance code lengths together (they
        // share the same encoding via the code-length tree).
        var combined = [Int](repeating: 0, count: hlit + hdist)
        var i = 0
        while i < combined.count {
            let symbol = try codeLengthTree.decode(reader: &reader)
            if symbol < 16 {
                combined[i] = symbol
                i += 1
            } else if symbol == 16 {
                guard i > 0 else { throw .invalidHuffmanCode }
                let repeatCount = try reader.readBits(2) + 3
                for _ in 0..<repeatCount {
                    guard i < combined.count else { throw .invalidHuffmanCode }
                    combined[i] = combined[i - 1]
                    i += 1
                }
            } else if symbol == 17 {
                let repeatCount = try reader.readBits(3) + 3
                for _ in 0..<repeatCount {
                    guard i < combined.count else { throw .invalidHuffmanCode }
                    combined[i] = 0
                    i += 1
                }
            } else if symbol == 18 {
                let repeatCount = try reader.readBits(7) + 11
                for _ in 0..<repeatCount {
                    guard i < combined.count else { throw .invalidHuffmanCode }
                    combined[i] = 0
                    i += 1
                }
            } else {
                throw .invalidHuffmanCode
            }
        }

        let literalLens = Array(combined[0..<hlit])
        let distanceLens = Array(combined[hlit..<combined.count])
        let literalTree = try HuffmanTree(codeLengths: literalLens)
        let distanceTree = try HuffmanTree(codeLengths: distanceLens)
        return (literalTree, distanceTree)
    }
}

// MARK: - Errors

public enum InflateError: Error, Sendable, Equatable {
    case truncatedInput
    case malformedHeader
    case invalidBlockType
    case invalidStoredLength
    case invalidHuffmanCode
    case invalidDistance(Int)
    case invalidLength(Int)
    case unexpectedEndOfStream
}

// MARK: - Bit reader

/// Reads bits LSB-first from a byte stream, per RFC 1951 §3.1.1.
struct BitReader {
    private let data: Data
    private var byteIndex: Int = 0
    private var bitOffset: Int = 0  // 0..7, position within current byte

    init(data: Data) {
        self.data = data
    }

    /// Read `n` bits (1..16) LSB-first. Bits are accumulated low-to-high
    /// across byte boundaries.
    mutating func readBits(_ n: Int) throws(InflateError) -> Int {
        var result = 0
        var consumed = 0
        while consumed < n {
            if byteIndex >= data.count {
                throw .truncatedInput
            }
            let available = 8 - bitOffset
            let take = min(n - consumed, available)
            let mask = (1 << take) - 1
            let bits = (Int(data[byteIndex]) >> bitOffset) & mask
            result |= bits << consumed
            consumed += take
            bitOffset += take
            if bitOffset == 8 {
                bitOffset = 0
                byteIndex += 1
            }
        }
        return result
    }

    /// Skip remaining bits in the current byte to align to the next byte.
    mutating func alignToByte() {
        if bitOffset != 0 {
            bitOffset = 0
            byteIndex += 1
        }
    }

    /// Read one full byte (must be byte-aligned).
    mutating func readByte() throws(InflateError) -> UInt8 {
        precondition(bitOffset == 0, "must alignToByte() before readByte()")
        guard byteIndex < data.count else { throw .truncatedInput }
        let byte = data[byteIndex]
        byteIndex += 1
        return byte
    }

    /// Read 16-bit little-endian value (must be byte-aligned).
    mutating func readU16LE() throws(InflateError) -> Int {
        let low = try readByte()
        let high = try readByte()
        return Int(low) | (Int(high) << 8)
    }
}

// MARK: - Sliding window

/// 32KB ring buffer for LZ77 back-references. Output bytes append
/// here AND to the user's output buffer; back-reference reads
/// pull from this window.
struct SlidingWindow {
    private static let size = 32768
    private var buffer = [UInt8](repeating: 0, count: SlidingWindow.size)
    private var position: Int = 0
    private var filled: Int = 0  // number of bytes written so far (capped at size)

    mutating func append(_ byte: UInt8) {
        buffer[position] = byte
        position = (position + 1) % SlidingWindow.size
        if filled < SlidingWindow.size {
            filled += 1
        }
    }

    /// Read a byte `distance` bytes back. `distance` must be in 1...filled
    /// range; caller validates against bounds before invoking.
    func readBack(distance: Int) throws(InflateError) -> UInt8 {
        guard distance >= 1 && distance <= filled else {
            throw .invalidDistance(distance)
        }
        var index = position - distance
        if index < 0 { index += SlidingWindow.size }
        return buffer[index]
    }
}

// MARK: - Huffman tree

/// Canonical Huffman tree for deflate. Built from a code-lengths
/// array per RFC 1951 §3.2.2. Decode walks bit-by-bit.
struct HuffmanTree {
    /// codeLengths[symbol] = bit-length of the code for that symbol.
    /// 0 means symbol is unused.
    private let codeLengths: [Int]
    /// codes[symbol] = canonical Huffman code for that symbol, packed
    /// MSB-aligned within `codeLengths[symbol]` bits. Used for lookup.
    private let codes: [Int]
    private let maxCodeLength: Int

    init(codeLengths: [Int]) throws(InflateError) {
        self.codeLengths = codeLengths
        var maxLen = 0
        for length in codeLengths where length > maxLen {
            maxLen = length
        }
        self.maxCodeLength = maxLen

        guard maxLen > 0 else {
            // Degenerate: no symbols. Tree is empty; decode will throw.
            self.codes = []
            return
        }

        // Canonical Huffman code construction (RFC 1951 §3.2.2).
        // Step 1: count codes per length.
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for length in codeLengths where length > 0 {
            blCount[length] += 1
        }
        // Step 2: compute next-code per length.
        var nextCode = [Int](repeating: 0, count: maxLen + 1)
        var code = 0
        for bits in 1...maxLen {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        // Step 3: assign each symbol its canonical code.
        var assigned = [Int](repeating: 0, count: codeLengths.count)
        for symbol in 0..<codeLengths.count {
            let length = codeLengths[symbol]
            if length > 0 {
                assigned[symbol] = nextCode[length]
                nextCode[length] += 1
            }
        }
        self.codes = assigned
    }

    /// Decode one symbol by reading bits MSB-first into a code.
    /// Walks one bit at a time; for each accumulated code, scans
    /// for a matching symbol with that exact length.
    func decode(reader: inout BitReader) throws(InflateError) -> Int {
        guard maxCodeLength > 0 else { throw .invalidHuffmanCode }
        var code = 0
        for length in 1...maxCodeLength {
            // Deflate Huffman codes are packed MSB-first within their
            // length, but the bit-stream is LSB-first. We read one bit
            // and prepend it to our accumulator (shift left, OR).
            let bit = try reader.readBits(1)
            code = (code << 1) | bit
            for symbol in 0..<codeLengths.count {
                if codeLengths[symbol] == length && codes[symbol] == code {
                    return symbol
                }
            }
        }
        throw .invalidHuffmanCode
    }
}

// MARK: - Fixed Huffman trees (RFC 1951 §3.2.6)

enum FixedHuffman {
    static let literal: HuffmanTree = {
        // Literals 0..143: 8 bits; 144..255: 9 bits;
        // 256..279: 7 bits; 280..287: 8 bits.
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0...143 { lengths[i] = 8 }
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        for i in 280...287 { lengths[i] = 8 }
        // Force-try acceptable: lengths are spec-defined and valid.
        return try! HuffmanTree(codeLengths: lengths)
    }()

    static let distance: HuffmanTree = {
        // All 30 distance codes are 5 bits each.
        let lengths = [Int](repeating: 5, count: 30)
        return try! HuffmanTree(codeLengths: lengths)
    }()
}
