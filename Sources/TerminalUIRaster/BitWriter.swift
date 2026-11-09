/// Packs values into bytes least-significant bit first: deflate's order
/// (RFC 1951 §3.1.1, "starting with the least-significant bit of the data
/// element") and GIF's for LZW codes (GIF89a Appendix F).
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var pending: UInt64 = 0
    private var pendingCount = 0

    /// Bits written so far, the partial last byte included.
    var bitCount: Int { bytes.count * UInt8.bitWidth + pendingCount }

    /// Writes the low `count` bits of `value`, its lowest bit first.
    mutating func write(_ value: UInt32, bits count: Int) {
        precondition(count >= 0 && count <= UInt32.bitWidth, "\(count) bits")
        let mask = count == UInt32.bitWidth ? UInt64(UInt32.max) : (UInt64(1) << UInt64(count)) - 1
        pending |= (UInt64(value) & mask) << UInt64(pendingCount)
        pendingCount += count
        while pendingCount >= UInt8.bitWidth {
            bytes.append(UInt8(truncatingIfNeeded: pending))
            pending >>= UInt64(UInt8.bitWidth)
            pendingCount -= UInt8.bitWidth
        }
    }

    /// Pads with zero bits to the next byte boundary.
    mutating func alignToByte() {
        if pendingCount > 0 { write(0, bits: UInt8.bitWidth - pendingCount) }
    }

    /// Appends whole bytes; the writer must be at a byte boundary.
    mutating func append(contentsOf whole: ArraySlice<UInt8>) {
        precondition(pendingCount == 0, "bytes appended mid-byte")
        bytes.append(contentsOf: whole)
    }

    /// The bytes written, the last padded with zero bits.
    consuming func finish() -> [UInt8] {
        alignToByte()
        return bytes
    }
}

extension UInt32 {
    /// Most significant byte first, the order of zlib's Adler-32 (RFC 1950
    /// §2.1) and of every PNG integer (PNG §7.1).
    var bigEndianBytes: [UInt8] {
        stride(from: UInt32.bitWidth - UInt8.bitWidth, through: 0, by: -UInt8.bitWidth).map {
            UInt8(truncatingIfNeeded: self >> UInt32($0))
        }
    }
}
