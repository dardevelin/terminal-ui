/// A deflate encoder (RFC 1951) and its zlib wrapper (RFC 1950).
///
/// The input is cut into blocks of at most 64 Ki symbols, and each block is
/// written whichever way costs fewest bits, counted exactly: stored, the
/// fixed Huffman code, or a dynamic code made for it. Nothing depends on
/// anything but the input, so the output is the same bytes everywhere.
package enum Deflate {
    /// How many literals and matches one block holds at most. A block's
    /// dynamic code fits the statistics of its stretch of input; zlib's
    /// default level ends a block at 16 Ki symbols, and 64 Ki trades a
    /// little of that fit for fewer code headers.
    static let symbolsPerBlock = 65_536

    /// The raw deflate stream of `input`.
    package static func compress(_ input: [UInt8]) -> [UInt8] {
        encode(input).bytes
    }

    /// `input` as a zlib stream (RFC 1950 §2.2): the two header bytes, the
    /// deflate stream, then the Adler-32 of `input`, most significant byte
    /// first.
    package static func zlibCompress(_ input: [UInt8]) -> [UInt8] {
        ZlibHeader.bytes + compress(input) + Adler32.checksum(input).bigEndianBytes
    }

    /// The stream and, in order, how each block was written.
    static func encode(_ input: [UInt8]) -> (bytes: [UInt8], blockTypes: [DeflateFormat.BlockType]) {
        let tokens = LZ77.tokens(of: input)
        var writer = BitWriter()
        var blockTypes: [DeflateFormat.BlockType] = []
        var tokenStart = 0
        var inputStart = 0
        repeat {
            let tokenEnd = min(tokenStart + symbolsPerBlock, tokens.count)
            let block = tokens[tokenStart..<tokenEnd]
            let inputEnd = inputStart + block.reduce(0) { $0 + ($1.isLiteral ? 1 : Int($1.value)) }
            blockTypes.append(writeBlock(block, covering: input[inputStart..<inputEnd],
                                         isFinal: tokenEnd == tokens.count, into: &writer))
            tokenStart = tokenEnd
            inputStart = inputEnd
        } while tokenStart < tokens.count
        return (writer.finish(), blockTypes)
    }

    // MARK: - Choosing a block type

    private static func writeBlock(_ tokens: ArraySlice<LZ77Token>, covering input: ArraySlice<UInt8>,
                                   isFinal: Bool, into writer: inout BitWriter) -> DeflateFormat.BlockType {
        var literalFrequencies = [Int](repeating: 0, count: DeflateFormat.literalLengthSymbolCount)
        var distanceFrequencies = [Int](repeating: 0, count: DeflateFormat.distanceSymbolCount)
        var extraBits = 0
        for token in tokens {
            if token.isLiteral {
                literalFrequencies[Int(token.value)] += 1
            } else {
                let lengthCode = Int(DeflateFormat.lengthCode[Int(token.value)])
                let distanceCode = Int(DeflateFormat.distanceCode[Int(token.distance)])
                literalFrequencies[DeflateFormat.firstLengthSymbol + lengthCode] += 1
                distanceFrequencies[distanceCode] += 1
                extraBits += DeflateFormat.lengthExtraBits[lengthCode] + DeflateFormat.distanceExtraBits[distanceCode]
            }
        }
        literalFrequencies[DeflateFormat.endOfBlock] = 1

        func cost(_ literal: PrefixCode, _ distance: PrefixCode) -> Int {
            DeflateFormat.blockHeaderBits + extraBits
                + zip(literalFrequencies, literal.lengths).reduce(0) { $0 + $1.0 * $1.1 }
                + zip(distanceFrequencies, distance.lengths).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let dynamic = DynamicCode(literalFrequencies: literalFrequencies, distanceFrequencies: distanceFrequencies)
        let storedCost = storedBits(length: input.count, startingAt: writer.bitCount)
        let fixedCost = cost(PrefixCode.fixedLiteral, PrefixCode.fixedDistance)
        let dynamicCost = cost(dynamic.literal, dynamic.distance) + dynamic.headerBits

        // A tie goes to the simpler block.
        let type: DeflateFormat.BlockType = storedCost <= min(fixedCost, dynamicCost) ? .stored
            : fixedCost <= dynamicCost ? .fixed : .dynamic
        switch type {
        case .stored:
            writeStored(input, isFinal: isFinal, into: &writer)
        case .fixed:
            writeBlockHeader(type, isFinal: isFinal, into: &writer)
            writeSymbols(tokens, literal: .fixedLiteral, distance: .fixedDistance, into: &writer)
        case .dynamic:
            writeBlockHeader(type, isFinal: isFinal, into: &writer)
            dynamic.writeHeader(into: &writer)
            writeSymbols(tokens, literal: dynamic.literal, distance: dynamic.distance, into: &writer)
        }
        return type
    }

    private static func writeBlockHeader(_ type: DeflateFormat.BlockType, isFinal: Bool,
                                         into writer: inout BitWriter) {
        writer.write((isFinal ? 1 : 0) | type.rawValue << 1, bits: DeflateFormat.blockHeaderBits)
    }

    // MARK: - Stored blocks (§3.2.4)

    /// A stored block holds at most 65 535 bytes, so a longer stretch is
    /// several. The first pads from its header to a byte boundary; each
    /// later one starts on a boundary, so pads the 5 bits after its header.
    private static func storedBits(length: Int, startingAt bitPosition: Int) -> Int {
        let byteBits = UInt8.bitWidth
        let pieces = max(1, (length + DeflateFormat.maximumStoredLength - 1) / DeflateFormat.maximumStoredLength)
        let firstPadding = (byteBits - (bitPosition + DeflateFormat.blockHeaderBits) % byteBits) % byteBits
        let laterPadding = byteBits - DeflateFormat.blockHeaderBits
        return pieces * (DeflateFormat.blockHeaderBits + DeflateFormat.storedLengthBits)
            + firstPadding + (pieces - 1) * laterPadding + byteBits * length
    }

    private static func writeStored(_ input: ArraySlice<UInt8>, isFinal: Bool, into writer: inout BitWriter) {
        var start = input.startIndex
        repeat {
            let end = min(start + DeflateFormat.maximumStoredLength, input.endIndex)
            writeBlockHeader(.stored, isFinal: end == input.endIndex && isFinal, into: &writer)
            writer.alignToByte()
            let length = UInt32(end - start)
            writer.write(length, bits: UInt16.bitWidth)
            writer.write(~length & UInt32(UInt16.max), bits: UInt16.bitWidth)
            writer.append(contentsOf: input[start..<end])
            start = end
        } while start < input.endIndex
    }

    // MARK: - Huffman blocks (§3.2.5)

    private static func writeSymbols(_ tokens: ArraySlice<LZ77Token>, literal: PrefixCode, distance: PrefixCode,
                                     into writer: inout BitWriter) {
        for token in tokens {
            if token.isLiteral {
                literal.write(Int(token.value), into: &writer)
                continue
            }
            let length = Int(token.value)
            let lengthCode = Int(DeflateFormat.lengthCode[length])
            literal.write(DeflateFormat.firstLengthSymbol + lengthCode, into: &writer)
            writer.write(UInt32(length - DeflateFormat.lengthBases[lengthCode]),
                         bits: DeflateFormat.lengthExtraBits[lengthCode])
            let offset = Int(token.distance)
            let distanceCode = Int(DeflateFormat.distanceCode[offset])
            distance.write(distanceCode, into: &writer)
            writer.write(UInt32(offset - DeflateFormat.distanceBases[distanceCode]),
                         bits: DeflateFormat.distanceExtraBits[distanceCode])
        }
        literal.write(DeflateFormat.endOfBlock, into: &writer)
    }
}

/// RFC 1950 §2.2's two header bytes for this encoder.
private enum ZlibHeader {
    /// CM 8 is deflate; CINFO 7 a 2^(7+8) = 32 KiB window.
    private static let compressionMethodAndInfo: UInt8 = 0x78
    /// FLEVEL 2, "default algorithm": hash chains of 128 and lazy matching
    /// are zlib's default level. FDICT 0, no preset dictionary.
    private static let levelFlags: UInt8 = 2 << 6
    /// FCHECK makes CMF·256 + FLG a multiple of 31.
    private static let checkModulus = 31

    static let bytes: [UInt8] = {
        let remainder = (Int(compressionMethodAndInfo) << 8 | Int(levelFlags)) % checkModulus
        let check = remainder == 0 ? 0 : checkModulus - remainder
        return [compressionMethodAndInfo, levelFlags | UInt8(check)]
    }()
}

/// A prefix code ready to write: each symbol's length, and its code
/// bit-reversed for the least-significant-first stream.
struct PrefixCode: Sendable {
    let lengths: [Int]
    private let reversedCodes: [UInt32]

    init(lengths: [Int]) {
        self.lengths = lengths
        reversedCodes = zip(HuffmanCode.canonicalCodes(lengths: lengths), lengths).map {
            HuffmanCode.reversed($0, length: $1)
        }
    }

    func write(_ symbol: Int, into writer: inout BitWriter) {
        writer.write(reversedCodes[symbol], bits: lengths[symbol])
    }

    static let fixedLiteral = PrefixCode(lengths: DeflateFormat.fixedLiteralLengths)
    static let fixedDistance = PrefixCode(lengths: DeflateFormat.fixedDistanceLengths)
}

/// A dynamic block's codes and the header that describes them (§3.2.7):
/// the literal/length and distance code lengths, run-length coded with
/// symbols 16–18 as one sequence, themselves Huffman coded.
struct DynamicCode {
    let literal: PrefixCode
    let distance: PrefixCode
    private let literalCount: Int
    private let distanceCount: Int
    private let codeLengthCode: PrefixCode
    private let codeLengthCount: Int
    private let runs: [CodeLengthRun]

    /// The header's length in bits, after the 3-bit block header.
    let headerBits: Int

    init(literalFrequencies: [Int], distanceFrequencies: [Int]) {
        let literalLengths = HuffmanCode.lengths(frequencies: literalFrequencies,
                                                 limit: DeflateFormat.maximumCodeLength)
        let distanceLengths = HuffmanCode.lengths(frequencies: distanceFrequencies,
                                                  limit: DeflateFormat.maximumCodeLength)
        literal = PrefixCode(lengths: literalLengths)
        distance = PrefixCode(lengths: distanceLengths)
        literalCount = max(DeflateFormat.minimumLiteralCount, (literalLengths.lastIndex { $0 > 0 } ?? 0) + 1)
        distanceCount = max(DeflateFormat.minimumDistanceCount, (distanceLengths.lastIndex { $0 > 0 } ?? 0) + 1)

        // The repeat codes may run across from the literal lengths into the
        // distance lengths (§3.2.7), so the two are coded as one sequence.
        runs = Self.runLengths(Array(literalLengths[..<literalCount] + distanceLengths[..<distanceCount]))
        var codeLengthFrequencies = [Int](repeating: 0, count: DeflateFormat.codeLengthSymbolCount)
        for run in runs { codeLengthFrequencies[run.symbol] += 1 }
        let codeLengthLengths = HuffmanCode.lengths(frequencies: codeLengthFrequencies,
                                                    limit: DeflateFormat.maximumCodeLengthCodeLength)
        codeLengthCode = PrefixCode(lengths: codeLengthLengths)
        codeLengthCount = max(DeflateFormat.minimumCodeLengthCount,
                              (DeflateFormat.codeLengthOrder.lastIndex { codeLengthLengths[$0] > 0 } ?? 0) + 1)

        headerBits = DeflateFormat.literalCountBits + DeflateFormat.distanceCountBits
            + DeflateFormat.codeLengthCountBits + codeLengthCount * DeflateFormat.codeLengthLengthBits
            + runs.reduce(0) { $0 + codeLengthLengths[$1.symbol] + $1.extraBits }
    }

    func writeHeader(into writer: inout BitWriter) {
        writer.write(UInt32(literalCount - DeflateFormat.minimumLiteralCount), bits: DeflateFormat.literalCountBits)
        writer.write(UInt32(distanceCount - DeflateFormat.minimumDistanceCount),
                     bits: DeflateFormat.distanceCountBits)
        writer.write(UInt32(codeLengthCount - DeflateFormat.minimumCodeLengthCount),
                     bits: DeflateFormat.codeLengthCountBits)
        for symbol in DeflateFormat.codeLengthOrder.prefix(codeLengthCount) {
            writer.write(UInt32(codeLengthCode.lengths[symbol]), bits: DeflateFormat.codeLengthLengthBits)
        }
        for run in runs {
            codeLengthCode.write(run.symbol, into: &writer)
            writer.write(run.extra, bits: run.extraBits)
        }
    }

    /// `lengths` in the code-length alphabet: a run of zeros as 18s then a
    /// 17, a length repeated as itself then 16s, each repeat as long as it
    /// goes; what is left over too short to repeat, written as is.
    private static func runLengths(_ lengths: [Int]) -> [CodeLengthRun] {
        var runs: [CodeLengthRun] = []
        func repeats(_ code: DeflateFormat.RepeatSymbol, _ count: inout Int) {
            while count >= code.minimum {
                let taken = min(count, code.maximum)
                runs.append(CodeLengthRun(code, count: taken))
                count -= taken
            }
        }
        var index = 0
        while index < lengths.count {
            let length = lengths[index]
            var count = 1
            while index + count < lengths.count, lengths[index + count] == length { count += 1 }
            index += count
            if length == 0 {
                repeats(DeflateFormat.repeatLongZeros, &count)
                repeats(DeflateFormat.repeatShortZeros, &count)
            } else {
                runs.append(CodeLengthRun(length: length))
                count -= 1
                repeats(DeflateFormat.repeatPrevious, &count)
            }
            runs += repeatElement(CodeLengthRun(length: length), count: count)
        }
        return runs
    }
}

/// One symbol of a dynamic header's code-length sequence (§3.2.7) and its
/// extra bits.
private struct CodeLengthRun {
    let symbol: Int
    let extra: UInt32
    let extraBits: Int

    /// A code length 0–15, written as itself.
    init(length: Int) {
        symbol = length
        extra = 0
        extraBits = 0
    }

    init(_ code: DeflateFormat.RepeatSymbol, count: Int) {
        symbol = code.symbol
        extra = UInt32(count - code.minimum)
        extraBits = code.extraBits
    }
}
