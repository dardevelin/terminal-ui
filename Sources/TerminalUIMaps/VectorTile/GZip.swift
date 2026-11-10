import Foundation
import TerminalUIIO
import TerminalUIRaster

/// Why gzip bytes could not be inflated.
public enum GZipError: Error, Sendable, Equatable {
    /// Shorter than a header and trailer.
    case truncated
    /// Not the gzip magic, or a method other than deflate.
    case notGzip
    /// A header flag RFC 1952 reserves.
    case reservedFlags
    /// The deflate data inside would not inflate.
    case inflate(InflateError)
    /// The trailer's CRC-32 or length does not match what inflated.
    case checksumMismatch
}

/// RFC 1952 gzip: a header, a raw deflate stream (RFC 1951), and a trailer
/// of the CRC-32 and the length mod 2^32 of what it holds, both
/// little-endian. TerminalUIIO's `Inflate` reads the deflate stream;
/// this is the framing around it.
public enum GZip {
    /// RFC 1952 §2.3.1: ID1, ID2, then CM, where 8 is deflate.
    private enum Header {
        static let firstMagic: UInt8 = 0x1F
        static let secondMagic: UInt8 = 0x8B
        static let deflateMethod: UInt8 = 8
        /// ID1, ID2, CM, FLG, MTIME (4), XFL, OS.
        static let fixedLength = 10
        static let flagsOffset = 3
        /// The OS byte for "unknown", which a writer that does not care sets.
        static let unknownOperatingSystem: UInt8 = 255
    }

    /// RFC 1952 §2.3.1 FLG bits.
    private enum Flag {
        static let headerCRC: UInt8 = 1 << 1
        static let extra: UInt8 = 1 << 2
        static let name: UInt8 = 1 << 3
        static let comment: UInt8 = 1 << 4
        static let reserved: UInt8 = 0b1110_0000
    }

    /// CRC32 and ISIZE, four bytes each.
    private static let trailerLength = 8
    private static let headerCRCLength = 2
    private static let extraLengthBytes = 2

    /// Whether `bytes` start with the gzip magic.
    public static func isCompressed(_ bytes: some Collection<UInt8>) -> Bool {
        var iterator = bytes.makeIterator()
        return iterator.next() == Header.firstMagic && iterator.next() == Header.secondMagic
    }

    /// The bytes one gzip member holds.
    public static func decompress(_ bytes: [UInt8]) throws(GZipError) -> [UInt8] {
        guard bytes.count >= Header.fixedLength + trailerLength else { throw .truncated }
        guard bytes[0] == Header.firstMagic, bytes[1] == Header.secondMagic,
              bytes[2] == Header.deflateMethod else { throw .notGzip }
        let flags = bytes[Header.flagsOffset]
        guard flags & Flag.reserved == 0 else { throw .reservedFlags }

        let trailerStart = bytes.count - trailerLength
        var position = Header.fixedLength
        if flags & Flag.extra != 0 {
            guard trailerStart - position >= extraLengthBytes else { throw .truncated }
            let extraLength = Int(bytes[position]) | Int(bytes[position + 1]) << UInt8.bitWidth
            position += extraLengthBytes
            guard trailerStart - position >= extraLength else { throw .truncated }
            position += extraLength
        }
        for flag in [Flag.name, Flag.comment] where flags & flag != 0 {
            guard let terminator = bytes[position..<trailerStart].firstIndex(of: 0) else { throw .truncated }
            position = terminator + 1
        }
        if flags & Flag.headerCRC != 0 {
            guard trailerStart - position >= headerCRCLength else { throw .truncated }
            position += headerCRCLength
        }

        let inflated: [UInt8]
        do {
            inflated = Array(try Inflate.decode(Data(bytes[position..<trailerStart])))
        } catch {
            throw .inflate(error)
        }
        let expectedCRC = littleEndianWord(bytes, at: trailerStart)
        let expectedLength = littleEndianWord(bytes, at: trailerStart + trailerLength / 2)
        guard CRC32.checksum(inflated) == expectedCRC,
              UInt32(truncatingIfNeeded: inflated.count) == expectedLength else { throw .checksumMismatch }
        return inflated
    }

    /// `bytes` as one gzip member with the minimal header: no name, no
    /// time, unknown system.
    package static func compress(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [Header.firstMagic, Header.secondMagic, Header.deflateMethod, 0, 0, 0, 0, 0, 0,
                               Header.unknownOperatingSystem]
        output += Deflate.compress(bytes)
        appendLittleEndianWord(CRC32.checksum(bytes), to: &output)
        appendLittleEndianWord(UInt32(truncatingIfNeeded: bytes.count), to: &output)
        return output
    }

    private static func littleEndianWord(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<MemoryLayout<UInt32>.size).reduce(UInt32(0)) { word, index in
            word | UInt32(bytes[offset + index]) << UInt32(index * UInt8.bitWidth)
        }
    }

    private static func appendLittleEndianWord(_ word: UInt32, to output: inout [UInt8]) {
        for index in 0..<MemoryLayout<UInt32>.size {
            output.append(UInt8(truncatingIfNeeded: word >> UInt32(index * UInt8.bitWidth)))
        }
    }
}
