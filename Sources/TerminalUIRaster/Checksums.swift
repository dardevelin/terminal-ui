/// CRC-32 as PNG defines it (PNG §5.5, ISO 3309 / ITU-T V.42): polynomial
/// 0x04C11DB7 processed least-significant bit first, so the reflected
/// 0xEDB88320, with the register preset to all ones and inverted at the end.
package enum CRC32 {
    private static let reflectedPolynomial: UInt32 = 0xEDB8_8320

    private static let table: [UInt32] = (0...UInt32(UInt8.max)).map { byte in
        var remainder = byte
        for _ in 0..<UInt8.bitWidth {
            remainder = remainder & 1 == 1 ? (remainder >> 1) ^ reflectedPolynomial : remainder >> 1
        }
        return remainder
    }

    /// The CRC of `bytes`, or of the bytes `previous` was the CRC of
    /// followed by `bytes`.
    package static func checksum(_ bytes: some Sequence<UInt8>, continuing previous: UInt32 = 0) -> UInt32 {
        var register = ~previous
        for byte in bytes {
            register = table[Int((register ^ UInt32(byte)) & 0xFF)] ^ (register >> 8)
        }
        return ~register
    }
}

/// Adler-32 (RFC 1950 §8.2): two sums modulo 65521, the largest prime
/// below 2^16, the second over the running first.
package enum Adler32 {
    private static let modulus: UInt32 = 65_521

    /// The most bytes whose sums cannot overflow 32 bits before the modulo
    /// is taken: the largest n with 255·n(n+1)/2 + (n+1)(modulus−1) < 2^32,
    /// zlib's NMAX.
    private static let bytesPerReduction = 5552

    /// The Adler-32 of `bytes`, or of the bytes `previous` was the Adler-32
    /// of followed by `bytes`. Of nothing, it is 1.
    package static func checksum(_ bytes: some Sequence<UInt8>, continuing previous: UInt32 = 1) -> UInt32 {
        var low = previous & 0xFFFF
        var high = previous >> 16
        var pending = 0
        for byte in bytes {
            low += UInt32(byte)
            high += low
            pending += 1
            if pending == bytesPerReduction {
                low %= modulus
                high %= modulus
                pending = 0
            }
        }
        return (high % modulus) << 16 | (low % modulus)
    }
}
