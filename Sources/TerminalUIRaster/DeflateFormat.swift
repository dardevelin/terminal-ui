/// The constants and tables of the deflate format, RFC 1951.
enum DeflateFormat {
    /// §3.2.3: a block's header is BFINAL, then two bits of BTYPE.
    enum BlockType: UInt32, Sendable {
        case stored = 0
        case fixed = 1
        case dynamic = 2
    }

    static let blockHeaderBits = 3

    /// §3.2.4: a stored block's LEN and NLEN, 16 bits each.
    static let storedLengthBits = 32
    static let maximumStoredLength = Int(UInt16.max)

    /// §3.2.5: matches of 3 to 258 bytes, up to 32 768 bytes back.
    static let minimumMatchLength = 3
    static let maximumMatchLength = 258
    static let windowSize = 32_768

    /// §3.2.5: literals 0–255, end-of-block 256, length codes 257–285.
    static let endOfBlock = 256
    static let firstLengthSymbol = 257
    static let literalLengthSymbolCount = 286
    static let distanceSymbolCount = 30

    /// §3.2.7: code lengths are 0–15, and the code-length code's own
    /// lengths are written in 3 bits, so 0–7.
    static let maximumCodeLength = 15
    static let maximumCodeLengthCodeLength = 7

    /// §3.2.7: HLIT, HDIST and HCLEN field widths and their offsets.
    static let literalCountBits = 5
    static let distanceCountBits = 5
    static let codeLengthCountBits = 4
    static let codeLengthLengthBits = 3
    static let minimumLiteralCount = 257
    static let minimumDistanceCount = 1
    static let minimumCodeLengthCount = 4

    /// §3.2.7: the order the code-length code's lengths are written in.
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    static let codeLengthSymbolCount = 19

    /// §3.2.7: a code-length symbol that repeats, `minimum` to `maximum`
    /// times, its count less `minimum` in `extraBits` after it.
    struct RepeatSymbol: Sendable {
        let symbol: Int
        let minimum: Int
        let maximum: Int
        let extraBits: Int
    }

    /// 16 copies the previous length 3–6 times; 17 writes 3–10 zeros, 18
    /// writes 11–138.
    static let repeatPrevious = RepeatSymbol(symbol: 16, minimum: 3, maximum: 6, extraBits: 2)
    static let repeatShortZeros = RepeatSymbol(symbol: 17, minimum: 3, maximum: 10, extraBits: 3)
    static let repeatLongZeros = RepeatSymbol(symbol: 18, minimum: 11, maximum: 138, extraBits: 7)

    /// §3.2.5: each length code's first length and extra bits, codes
    /// 257–285 in order.
    static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                              35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

    /// §3.2.5: each distance code's first distance and extra bits, codes
    /// 0–29 in order.
    static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                8193, 12_289, 16_385, 24_577]
    static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// The length code (0-based, so 257 is 0) for every length 0–258.
    static let lengthCode: [UInt8] = codeTable(bases: lengthBases, through: maximumMatchLength)

    /// The distance code for every distance 0–32 768.
    static let distanceCode: [UInt8] = codeTable(bases: distanceBases, through: windowSize)

    /// §3.2.6: the fixed code's lengths — literals 0–143 take 8 bits,
    /// 144–255 take 9, 256–279 take 7, 280–287 take 8 — and 5 bits for
    /// every distance.
    static let fixedLiteralLengths: [Int] = (0..<288).map { symbol in
        switch symbol {
        case 0...143: 8
        case 144...255: 9
        case 256...279: 7
        default: 8
        }
    }
    static let fixedDistanceLengths = [Int](repeating: 5, count: 32)

    private static func codeTable(bases: [Int], through last: Int) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: last + 1)
        var code = 0
        for value in bases[0]...last {
            if code + 1 < bases.count, value >= bases[code + 1] { code += 1 }
            table[value] = UInt8(code)
        }
        return table
    }
}
