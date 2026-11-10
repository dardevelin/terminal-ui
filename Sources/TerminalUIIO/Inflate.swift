import Foundation

// Pure-Swift RFC 1951 deflate decoder, the decompression PNG IDAT
// chunks need; PNGDecoder reads them with it.
// Zero external dependencies: works identically on macOS + Linux.
//
// Algorithm (RFC 1951):
//   - Bit-level reader (LSB-first within bytes).
//   - Three block types: stored / fixed-Huffman / dynamic-Huffman.
//   - LZ77 back-references reaching up to 32 KB back into the output.
//   - Length codes 257-285 + distance codes 0-29 per spec tables.
//
// Caller is responsible for stripping zlib wrapping if present
// (PNG IDAT data is zlib-wrapped; the wrapper sits above this).

/// A decoder of raw deflate streams (RFC 1951), in pure Swift.
///
/// The input is the deflate data itself, without the zlib (RFC 1950) or
/// gzip (RFC 1952) wrapping around it. Malformed input throws; it never
/// traps.
///
/// ```swift
/// let bytes = try Inflate.decode(deflated)
/// let bounded = try Inflate.decode(deflated, outputLimit: 1 << 20)
/// ```
public enum Inflate {

    /// Decode a raw deflate stream into the original bytes.
    ///
    /// Deflate expands as much as 1032 to 1 — RFC 1951's longest match,
    /// 258 bytes, can take as little as two bits — so input from
    /// somewhere untrusted is better decoded with
    /// ``decode(_:outputLimit:)``, which stops at a bound.
    public static func decode(_ data: Data) throws(InflateError) -> Data {
        guard let output = try inflate([UInt8](data), from: 0, limit: Int.max) else {
            // No array holds more than `Int.max` bytes, so the limit is
            // never what stops it.
            throw .invalidLength(Int.max)
        }
        return Data(output)
    }

    /// Decode a raw deflate stream into at most `outputLimit` bytes,
    /// refusing a stream that holds more instead of inflating it.
    ///
    /// A reader that knows how much it expects — an image's rows, a
    /// file's stated size — passes that, and a stream built to fill memory
    /// stops there.
    ///
    /// - Throws: ``BoundedInflateError/outputLimitExceeded(limit:)`` once
    ///   the stream would produce more than `outputLimit` bytes, and
    ///   ``BoundedInflateError/malformed(_:)`` for a stream that is not
    ///   valid deflate.
    public static func decode(_ data: Data, outputLimit: Int) throws(BoundedInflateError) -> Data {
        let output: [UInt8]?
        do {
            output = try inflate([UInt8](data), from: 0, limit: max(0, outputLimit))
        } catch {
            throw .malformed(error)
        }
        guard let output else { throw .outputLimitExceeded(limit: outputLimit) }
        return Data(output)
    }

    /// The bytes the deflate stream starting at `start` holds, or `nil`
    /// when they would number more than `limit`.
    static func inflate(_ bytes: [UInt8], from start: Int, limit: Int,
                        statistics: inout InflateStatistics) throws(InflateError) -> [UInt8]? {
        var reader = BitReader(bytes: bytes, position: start)
        // A limit the input could reach is most likely the size the caller
        // expects, and is taken at once, with no copy as the output grows;
        // one it could not reach is not trusted, and a guess at a typical
        // ratio stands in.
        let inputCount = bytes.count - start
        var output: [UInt8] = []
        output.reserveCapacity(limit <= inputCount * Self.largestRatio ? limit
                               : min(limit, inputCount * Self.typicalRatio))
        defer { statistics.codeSteps += reader.codeSteps }

        while true {
            let isFinal = try reader.readBits(BlockHeader.finalBits) == 1
            switch try reader.readBits(BlockHeader.typeBits) {
            case BlockHeader.stored:
                guard try readStoredBlock(reader: &reader, output: &output, limit: limit) else { return nil }
            case BlockHeader.fixedHuffman:
                guard try readHuffmanBlock(reader: &reader, output: &output, literalTree: FixedHuffman.literal,
                                           distanceTree: FixedHuffman.distance, limit: limit) else { return nil }
            case BlockHeader.dynamicHuffman:
                let (literal, distance) = try readDynamicHuffmanTrees(reader: &reader)
                guard try readHuffmanBlock(reader: &reader, output: &output, literalTree: literal,
                                           distanceTree: distance, limit: limit) else { return nil }
            default:
                throw .invalidBlockType
            }
            if isFinal { return output }
        }
    }

    static func inflate(_ bytes: [UInt8], from start: Int, limit: Int) throws(InflateError) -> [UInt8]? {
        var statistics = InflateStatistics()
        return try inflate(bytes, from: start, limit: limit, statistics: &statistics)
    }

    private static let typicalRatio = 4
    /// RFC 1951 §3.2.5: a 258-byte match in as few as two bits, so 1032
    /// bytes out for each byte in, at most.
    private static let largestRatio = 1032

    /// RFC 1951 §3.2.3: BFINAL, then BTYPE.
    private enum BlockHeader {
        static let finalBits = 1
        static let typeBits = 2
        static let stored = 0
        static let fixedHuffman = 1
        static let dynamicHuffman = 2
    }

    /// RFC 1951 §3.2.5: the furthest a distance reaches back.
    private static let windowSize = 32_768
    /// RFC 1951 §3.2.5: literal/length symbol 256 ends a block, and
    /// 257 to 285 are lengths.
    private static let endOfBlock = 256
    private static let lastLengthSymbol = 285

    // MARK: - Stored block (§3.2.4)

    /// Whether the block fitted within `limit`.
    private static func readStoredBlock(reader: inout BitReader, output: inout [UInt8],
                                        limit: Int) throws(InflateError) -> Bool {
        reader.alignToByte()
        let length = try reader.readU16LE()
        let complement = try reader.readU16LE()
        guard length ^ Int(UInt16.max) == complement else { throw .invalidStoredLength }
        guard length <= limit - output.count else { return false }
        makeRoom(for: length, in: &output, limit: limit)
        try reader.copyBytes(length, into: &output)
        return true
    }

    /// Grow `output` to take `count` more bytes, doubling as an array does
    /// but never past `limit`: left to itself, an array one byte past a
    /// power of two allocates the next, so a 512 MB limit could end at a
    /// 1 GB buffer, the 512 MB one still held while it copies.
    private static func makeRoom(for count: Int, in output: inout [UInt8], limit: Int) {
        let needed = output.count + count
        guard needed > output.capacity else { return }
        output.reserveCapacity(min(limit, max(needed, output.capacity * 2)))
    }

    // MARK: - Huffman block (§3.2.5)

    /// Whether the block fitted within `limit`.
    private static func readHuffmanBlock(reader: inout BitReader, output: inout [UInt8],
                                         literalTree: HuffmanTree, distanceTree: HuffmanTree,
                                         limit: Int) throws(InflateError) -> Bool {
        while true {
            let symbol = try literalTree.decode(reader: &reader)
            if symbol < endOfBlock {
                guard output.count < limit else { return false }
                makeRoom(for: 1, in: &output, limit: limit)
                output.append(UInt8(truncatingIfNeeded: symbol))
            } else if symbol == endOfBlock {
                return true
            } else if symbol <= lastLengthSymbol {
                let length = try readLength(symbol: symbol, reader: &reader)
                let distance = try readDistance(symbol: try distanceTree.decode(reader: &reader), reader: &reader)
                guard distance <= output.count, distance <= windowSize else { throw .invalidDistance(distance) }
                guard length <= limit - output.count else { return false }
                makeRoom(for: length, in: &output, limit: limit)
                // A match may overlap what it writes — distance 1 repeats
                // the last byte `length` times — so it copies a byte at a
                // time, each one there before the next is read.
                var source = output.count - distance
                let end = source + length
                while source < end {
                    output.append(output[source])
                    source += 1
                }
            } else {
                throw .invalidHuffmanCode
            }
        }
    }

    // MARK: - Length / distance tables (RFC 1951 §3.2.5)

    /// Symbols 257 to 285: the extra bits each reads and the length they
    /// add to.
    private static let lengthTable: [(extraBits: Int, base: Int)] = [
        (0, 3),  (0, 4),  (0, 5),   (0, 6),   (0, 7),   (0, 8),
        (0, 9),  (0, 10), (1, 11),  (1, 13),  (1, 15),  (1, 17),
        (2, 19), (2, 23), (2, 27),  (2, 31),  (3, 35),  (3, 43),
        (3, 51), (3, 59), (4, 67),  (4, 83),  (4, 99),  (4, 115),
        (5, 131), (5, 163), (5, 195), (5, 227), (0, 258)
    ]

    /// Distance symbols 0 to 29; 30 and 31 never occur in valid data.
    private static let distanceTable: [(extraBits: Int, base: Int)] = [
        (0, 1),     (0, 2),     (0, 3),     (0, 4),     (1, 5),
        (1, 7),     (2, 9),     (2, 13),    (3, 17),    (3, 25),
        (4, 33),    (4, 49),    (5, 65),    (5, 97),    (6, 129),
        (6, 193),   (7, 257),   (7, 385),   (8, 513),   (8, 769),
        (9, 1025),  (9, 1537),  (10, 2049), (10, 3073), (11, 4097),
        (11, 6145), (12, 8193), (12, 12289), (13, 16385), (13, 24577)
    ]

    private static func readLength(symbol: Int, reader: inout BitReader) throws(InflateError) -> Int {
        let index = symbol - (endOfBlock + 1)
        guard index >= 0 && index < lengthTable.count else { throw .invalidHuffmanCode }
        let entry = lengthTable[index]
        return entry.base + (entry.extraBits == 0 ? 0 : try reader.readBits(entry.extraBits))
    }

    private static func readDistance(symbol: Int, reader: inout BitReader) throws(InflateError) -> Int {
        guard symbol >= 0 && symbol < distanceTable.count else { throw .invalidHuffmanCode }
        let entry = distanceTable[symbol]
        return entry.base + (entry.extraBits == 0 ? 0 : try reader.readBits(entry.extraBits))
    }

    // MARK: - Dynamic Huffman tree construction (RFC 1951 §3.2.7)

    private enum DynamicHeader {
        /// HLIT, HDIST and HCLEN's widths and the counts they add to.
        static let literalCountBits = 5
        static let distanceCountBits = 5
        static let codeLengthCountBits = 4
        static let literalCountBase = 257
        static let distanceCountBase = 1
        static let codeLengthCountBase = 4
        /// HLIT can say 288 and HDIST 32, but only 286 and 30 codes exist.
        static let mostLiteralCodes = 286
        static let mostDistanceCodes = 30
        static let codeLengthBits = 3
        /// The order the code length code lengths come in.
        static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        /// Code length symbols 0 to 15 are lengths; 16 repeats the last
        /// 3–6 times (2 extra bits), 17 a zero 3–10 times (3), 18 a zero
        /// 11–138 times (7).
        static let repeatPrevious = 16
        static let repeatZero = 17
        static let repeatZeroLong = 18
        static let repeats: [(extraBits: Int, base: Int)] = [(2, 3), (3, 3), (7, 11)]
    }

    private static func readDynamicHuffmanTrees(
        reader: inout BitReader
    ) throws(InflateError) -> (literal: HuffmanTree, distance: HuffmanTree) {
        let literalCount = try reader.readBits(DynamicHeader.literalCountBits) + DynamicHeader.literalCountBase
        let distanceCount = try reader.readBits(DynamicHeader.distanceCountBits) + DynamicHeader.distanceCountBase
        let codeLengthCount = try reader.readBits(DynamicHeader.codeLengthCountBits)
            + DynamicHeader.codeLengthCountBase
        guard literalCount <= DynamicHeader.mostLiteralCodes, distanceCount <= DynamicHeader.mostDistanceCodes else {
            throw .invalidHuffmanCode
        }

        var codeLengthLengths = [Int](repeating: 0, count: DynamicHeader.codeLengthOrder.count)
        for order in 0..<codeLengthCount {
            codeLengthLengths[DynamicHeader.codeLengthOrder[order]] = try reader.readBits(DynamicHeader.codeLengthBits)
        }
        let codeLengthTree = try HuffmanTree(codeLengths: codeLengthLengths)

        // The literal/length and distance code lengths are one sequence: a
        // repeat may run from the one into the other.
        var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = try codeLengthTree.decode(reader: &reader)
            if symbol < DynamicHeader.repeatPrevious {
                lengths[index] = symbol
                index += 1
                continue
            }
            guard symbol <= DynamicHeader.repeatZeroLong else { throw .invalidHuffmanCode }
            let rule = DynamicHeader.repeats[symbol - DynamicHeader.repeatPrevious]
            let count = try reader.readBits(rule.extraBits) + rule.base
            let value: Int
            if symbol == DynamicHeader.repeatPrevious {
                guard index > 0 else { throw .invalidHuffmanCode }
                value = lengths[index - 1]
            } else {
                value = 0
            }
            guard count <= lengths.count - index else { throw .invalidHuffmanCode }
            for _ in 0..<count {
                lengths[index] = value
                index += 1
            }
        }
        // A block has to be able to end (zlib's "missing end-of-block").
        guard lengths[endOfBlock] > 0 else { throw .invalidHuffmanCode }
        let literalTree = try HuffmanTree(codeLengths: Array(lengths[0..<literalCount]))
        let distanceTree = try HuffmanTree(codeLengths: Array(lengths[literalCount...]))
        return (literalTree, distanceTree)
    }
}

// MARK: - Errors

/// Why a deflate stream could not be decoded.
public enum InflateError: Error, Sendable, Equatable {
    /// The input ended before the stream's last block did.
    case truncatedInput
    /// A header field holds a value deflate does not define.
    case malformedHeader
    /// A block's type is 3, which RFC 1951 reserves.
    case invalidBlockType
    /// A stored block's length and its complement disagree.
    case invalidStoredLength
    /// A Huffman code, or a set of code lengths, that cannot be decoded.
    case invalidHuffmanCode
    /// A back-reference to before the start of the output, or further
    /// than 32 KB back.
    case invalidDistance(Int)
    /// A match length outside 3 to 258.
    case invalidLength(Int)
    /// The stream ended where more was required.
    case unexpectedEndOfStream
}

/// Why ``Inflate/decode(_:outputLimit:)`` could not decode a stream.
public enum BoundedInflateError: Error, Sendable, Equatable {
    /// The stream is not valid deflate.
    case malformed(InflateError)
    /// The stream holds more than `limit` bytes; decoding stopped there.
    case outputLimitExceeded(limit: Int)
}

/// What decoding a stream cost, counted where the work is: a test bounds
/// it to keep the decoder linear in its input.
struct InflateStatistics {
    /// Code lengths tried while decoding Huffman codes, one a bit read.
    var codeSteps = 0
}

// MARK: - Bit reader

/// Reads bits LSB-first from a byte stream, per RFC 1951 §3.1.1.
struct BitReader {
    private let bytes: [UInt8]
    private var position: Int
    /// Bits taken from `bytes` and not yet read, the next one lowest.
    private var buffer: UInt64 = 0
    private var bitCount = 0
    /// See ``InflateStatistics/codeSteps``.
    var codeSteps = 0

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    /// Read `count` bits (0 to 16), the first read the lowest.
    mutating func readBits(_ count: Int) throws(InflateError) -> Int {
        while bitCount < count {
            guard position < bytes.count else { throw .truncatedInput }
            buffer |= UInt64(bytes[position]) << UInt64(bitCount)
            position += 1
            bitCount += UInt8.bitWidth
        }
        let value = Int(truncatingIfNeeded: buffer & ((1 << UInt64(count)) - 1))
        buffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    /// The next `count` bits (at most 32) without reading them, or nil
    /// when the input holds fewer.
    mutating func peek(_ count: Int) -> Int? {
        while bitCount < count {
            guard position < bytes.count else { return nil }
            buffer |= UInt64(bytes[position]) << UInt64(bitCount)
            position += 1
            bitCount += UInt8.bitWidth
        }
        return Int(truncatingIfNeeded: buffer & ((1 << UInt64(count)) - 1))
    }

    /// Pass over `count` bits a ``peek(_:)`` returned.
    mutating func skip(_ count: Int) {
        buffer >>= UInt64(count)
        bitCount -= count
    }

    mutating func readBit() throws(InflateError) -> Int {
        if bitCount == 0 {
            guard position < bytes.count else { throw .truncatedInput }
            buffer = UInt64(bytes[position])
            position += 1
            bitCount = UInt8.bitWidth
        }
        let bit = Int(truncatingIfNeeded: buffer & 1)
        buffer >>= 1
        bitCount -= 1
        return bit
    }

    /// Skip the rest of the current byte (§3.2.4). The buffer then holds
    /// whole bytes only.
    mutating func alignToByte() {
        let partial = bitCount % UInt8.bitWidth
        buffer >>= UInt64(partial)
        bitCount -= partial
    }

    /// A 16-bit little-endian value; aligned first.
    mutating func readU16LE() throws(InflateError) -> Int {
        try readBits(UInt16.bitWidth)
    }

    /// Append the next `count` bytes to `output`; aligned first.
    mutating func copyBytes(_ count: Int, into output: inout [UInt8]) throws(InflateError) {
        var remaining = count
        while remaining > 0, bitCount > 0 {
            output.append(UInt8(truncatingIfNeeded: try readBits(UInt8.bitWidth)))
            remaining -= 1
        }
        guard remaining <= bytes.count - position else { throw .truncatedInput }
        output.append(contentsOf: bytes[position..<(position + remaining)])
        position += remaining
    }
}

// MARK: - Huffman tree

/// Canonical Huffman code for deflate, built from a code-lengths array per
/// RFC 1951 §3.2.2 and decoded as Mark Adler's puff.c (zlib's
/// contrib/puff) does: canonical codes of one length are consecutive
/// integers, in symbol order, so a tree is only how many codes each length
/// has and the symbols sorted by (length, symbol). Reading a code a bit at a
/// time, the code is the n-th of its length exactly when it falls below the
/// first code of that length plus the count — one comparison a bit, no
/// search over the symbols.
///
/// Ahead of that, as zlib's inflate does, a table indexed by the next
/// `fastBits` of the stream gives every code that short in one lookup:
/// nearly every code in practice, since deflate gives the frequent symbols
/// the short codes.
struct HuffmanTree {
    /// counts[length] = how many symbols have a code of that many bits.
    private let counts: [Int]
    /// The used symbols, by code length and then by symbol value.
    private let symbols: [Int]
    private let maxCodeLength: Int
    /// Per value of the next `fastBits` bits, read as the stream gives
    /// them: the symbol whose code they start with, above its length in
    /// the low `lengthFieldBits`; zero where the code is longer.
    private let fast: [UInt16]

    static let fastBits = 9
    private static let lengthFieldBits = 4
    private static let lengthFieldMask: UInt16 = (1 << lengthFieldBits) - 1

    /// - Throws: `invalidHuffmanCode` for lengths that claim more codes
    ///   than their bits can tell apart (an over-subscribed set). A set
    ///   that leaves codes unused is accepted, as zlib accepts one, and
    ///   reading an unused code throws.
    init(codeLengths: [Int]) throws(InflateError) {
        maxCodeLength = max(0, codeLengths.max() ?? 0)
        var counts = [Int](repeating: 0, count: maxCodeLength + 1)
        for length in codeLengths where length > 0 {
            counts[length] += 1
        }
        // Each length doubles the codes left to give out, and its own use
        // some; running out is over-subscription (puff's `left < 0`).
        var available = 1
        for length in stride(from: 1, through: maxCodeLength, by: 1) {
            available = available * 2 - counts[length]
            guard available >= 0 else { throw .invalidHuffmanCode }
        }
        var offsets = [Int](repeating: 0, count: maxCodeLength + 1)
        for length in stride(from: 1, to: maxCodeLength, by: 1) {
            offsets[length + 1] = offsets[length] + counts[length]
        }
        var symbols = [Int](repeating: 0, count: counts.dropFirst().reduce(0, +))
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
        self.counts = counts
        self.symbols = symbols
        fast = Self.fastTable(counts: counts, symbols: symbols)
    }

    /// §3.2.2's codes for the lengths up to `fastBits`: each length's first
    /// code follows the last length's, doubled. A code is packed most
    /// significant bit first while the stream is read least significant
    /// first, so the table is indexed by each code bit-reversed, and by
    /// every value of the bits after it.
    private static func fastTable(counts: [Int], symbols: [Int]) -> [UInt16] {
        var table = [UInt16](repeating: 0, count: 1 << fastBits)
        var code = 0
        var index = 0
        for length in stride(from: 1, through: min(fastBits, counts.count - 1), by: 1) {
            for _ in 0..<counts[length] {
                var reversed = 0
                for bit in 0..<length where code >> bit & 1 == 1 {
                    reversed |= 1 << (length - 1 - bit)
                }
                let entry = UInt16(symbols[index]) << lengthFieldBits | UInt16(length)
                for slot in stride(from: reversed, to: 1 << fastBits, by: 1 << length) {
                    table[slot] = entry
                }
                code += 1
                index += 1
            }
            code <<= 1
        }
        return table
    }

    /// Decode one symbol: from the table when its code is short and the
    /// stream has `fastBits` left, and otherwise a bit at a time.
    func decode(reader: inout BitReader) throws(InflateError) -> Int {
        if let next = reader.peek(Self.fastBits) {
            reader.codeSteps += 1
            let entry = fast[next]
            if entry != 0 {
                reader.skip(Int(entry & Self.lengthFieldMask))
                return Int(entry >> Self.lengthFieldBits)
            }
        }
        return try decodeBitByBit(reader: &reader)
    }

    /// Each bit read is appended below the code so far, the code being
    /// packed most significant bit first.
    private func decodeBitByBit(reader: inout BitReader) throws(InflateError) -> Int {
        var code = 0
        var first = 0
        var index = 0
        var length = 1
        while length <= maxCodeLength {
            code |= try reader.readBit()
            reader.codeSteps += 1
            let count = counts[length]
            if code - first < count {
                return symbols[index + code - first]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
            length += 1
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
