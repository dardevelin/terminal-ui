/// A Huffman table of a DHT segment, made ready to decode with (ITU-T T.81
/// Annex C for how the code is generated, F.2.2.3 for how it is decoded).
struct JPEGHuffmanTable: Sendable {
    /// The bits peeked at once: a code no longer than this decodes with
    /// one lookup, as libjpeg's decoder does; longer ones take the
    /// length-by-length search of F.2.2.3.
    static let lookupBits = 9
    /// T.81 B.2.4.2: code lengths run from 1 to 16 bits.
    static let longestCode = 16
    /// B.2.4.2: at most 256 symbols a table, one for each byte value.
    static let mostSymbols = 256

    /// Per peeked value: the code's length in the high byte and its symbol
    /// in the low, or zero where the code is longer than `lookupBits`.
    private var lookup: [UInt16]
    /// F.2.2.3's MAXCODE and the first code and symbol index of each
    /// length, indexed by length.
    private var maximumCode: [Int]
    private var firstCode: [Int]
    private var firstSymbol: [Int]
    private var symbols: [UInt8]

    private static let noCode = -1

    /// - Parameters:
    ///   - counts: BITS, the number of codes of each length 1 to 16.
    ///   - symbols: HUFFVAL, the symbols in code order.
    init(counts: [Int], symbols: [UInt8]) throws(ImageDecodeError) {
        guard counts.count == Self.longestCode, counts.reduce(0, +) == symbols.count,
              symbols.count <= Self.mostSymbols else {
            throw .malformedData(reason: "a Huffman table's code counts do not match its symbols")
        }
        lookup = [UInt16](repeating: 0, count: 1 << Self.lookupBits)
        maximumCode = [Int](repeating: Self.noCode, count: Self.longestCode + 1)
        firstCode = [Int](repeating: 0, count: Self.longestCode + 1)
        firstSymbol = [Int](repeating: 0, count: Self.longestCode + 1)
        self.symbols = symbols

        // Annex C, figures C.1 and C.2: codes of one length are consecutive,
        // and each longer length starts at the next code doubled.
        var code = 0
        var symbolIndex = 0
        for length in 1...Self.longestCode {
            let count = counts[length - 1]
            firstCode[length] = code
            firstSymbol[length] = symbolIndex
            if count > 0 {
                guard code + count <= 1 << length else {
                    throw .malformedData(reason: "a Huffman table has more codes than its lengths allow")
                }
                for offset in 0..<count where length <= Self.lookupBits {
                    let spare = Self.lookupBits - length
                    let start = (code + offset) << spare
                    let entry = UInt16(length) << UInt8.bitWidth | UInt16(symbols[symbolIndex + offset])
                    for slot in start..<(start + (1 << spare)) {
                        lookup[slot] = entry
                    }
                }
                code += count
                symbolIndex += count
                maximumCode[length] = code - 1
            }
            code <<= 1
        }
    }

    /// The next symbol in `reader`.
    func decode(from reader: inout JPEGEntropyReader) throws(ImageDecodeError) -> UInt8 {
        reader.fill()
        let entry = lookup[Int(reader.peek(Self.lookupBits))]
        if entry != 0 {
            try reader.consume(Int(entry >> UInt8.bitWidth))
            return UInt8(truncatingIfNeeded: entry)
        }
        for length in (Self.lookupBits + 1)...Self.longestCode {
            let code = Int(reader.peek(length))
            if code <= maximumCode[length], code >= firstCode[length] {
                try reader.consume(length)
                return symbols[firstSymbol[length] + code - firstCode[length]]
            }
        }
        throw .malformedData(reason: "a Huffman code in the image data is not in its table")
    }
}

/// Reads the entropy-coded segments of a scan bit by bit, most significant
/// bit first (T.81 F.2.2.5), taking each 0xFF 0x00 as a 0xFF of data
/// (B.1.1.5) and stopping at the first marker.
///
/// Past a marker, or past the end of the input, the reader supplies zero
/// bits so a lookahead never runs dry; consuming one of them means the
/// data ended before the scan did, and throws. A well-formed encoder pads
/// a segment's last byte with 1-bits of its own, so it never reaches them.
struct JPEGEntropyReader {
    private let bytes: [UInt8]
    /// The next byte not yet taken into the buffer.
    private(set) var position: Int
    /// The bits read and not consumed, right-aligned.
    private var buffer: UInt64 = 0
    private var bitCount = 0
    /// How many of `bitCount`'s least significant bits are the zeros
    /// supplied past the data's end.
    private var paddingBits = 0
    private var stopped = false

    /// Bytes are taken into the buffer while at most this many bits are in
    /// it, so a byte always fits in its 64.
    private static let refillThreshold = UInt64.bitWidth - UInt8.bitWidth

    init(bytes: [UInt8], position: Int) {
        self.bytes = bytes
        self.position = position
    }

    /// Top the buffer up to more than `refillThreshold` bits.
    mutating func fill() {
        while bitCount <= Self.refillThreshold {
            var byte: UInt8 = 0
            if stopped || position >= bytes.count {
                stopped = true
                paddingBits += UInt8.bitWidth
            } else if bytes[position] == JPEGMarker.prefix {
                let next = position + 1 < bytes.count ? bytes[position + 1] : nil
                if next == JPEGMarker.stuffedZero {
                    byte = JPEGMarker.prefix
                    position += 2
                } else if next == JPEGMarker.prefix {
                    // B.1.1.2: a marker may be preceded by any number of
                    // 0xFF fill bytes.
                    position += 1
                    continue
                } else {
                    stopped = true
                    paddingBits += UInt8.bitWidth
                }
            } else {
                byte = bytes[position]
                position += 1
            }
            buffer = buffer << UInt64(UInt8.bitWidth) | UInt64(byte)
            bitCount += UInt8.bitWidth
        }
    }

    /// The next `count` bits, 1 to 16, without consuming them. Call
    /// ``fill()`` first.
    func peek(_ count: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: (buffer >> UInt64(bitCount - count)) & ((1 << UInt64(count)) - 1))
    }

    mutating func consume(_ count: Int) throws(ImageDecodeError) {
        bitCount -= count
        guard bitCount >= paddingBits else {
            throw .malformedData(reason: position >= bytes.count
                                 ? "the image data is truncated"
                                 : "a scan's data ends before its last block")
        }
    }

    /// T.81 F.2.2.1 RECEIVE and EXTEND: `count` bits as a signed value
    /// whose leading bit gives its sign.
    mutating func receiveExtended(_ count: Int) throws(ImageDecodeError) -> Int {
        guard count > 0 else { return 0 }
        guard count <= JPEGHuffmanTable.longestCode else {
            throw .malformedData(reason: "a coefficient is wider than 16 bits")
        }
        fill()
        let value = Int(peek(count))
        try consume(count)
        return value < 1 << (count - 1) ? value - (1 << count) + 1 : value
    }

    /// T.81 F.2.1.3.1, E.2.4: at the end of a restart interval the coder
    /// is byte-aligned and the marker RSTm, m counting 0 to 7 round, comes
    /// next. Drop what is buffered and step over it.
    mutating func restart(expecting index: Int) throws(ImageDecodeError) {
        buffer = 0
        bitCount = 0
        paddingBits = 0
        stopped = false
        while position + 1 < bytes.count, bytes[position] == JPEGMarker.prefix,
              bytes[position + 1] == JPEGMarker.prefix {
            position += 1
        }
        guard position + 1 < bytes.count, bytes[position] == JPEGMarker.prefix,
              bytes[position + 1] == JPEGMarker.restart0 + UInt8(index % JPEGMarker.restartCount) else {
            throw .malformedData(reason: "a restart marker is missing or out of order")
        }
        position += 2
    }
}
