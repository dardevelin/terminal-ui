import Testing
@testable import TerminalUIRaster

@Suite("CRC-32 and Adler-32")
struct ChecksumTests {

    // The check value of CRC-32/ISO-HDLC, the variant PNG and zlib use.
    @Test("CRC-32 of 123456789 is its check value")
    func crcCheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("CRC-32 of nothing is zero, and of a sentence matches zlib")
    func crcVectors() {
        #expect(CRC32.checksum([]) == 0)
        #expect(CRC32.checksum(Array("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test("CRC-32 continued over two halves equals it over the whole")
    func crcContinues() {
        let bytes = Samples.random(1000)
        let first = CRC32.checksum(bytes[..<333])
        #expect(CRC32.checksum(bytes[333...], continuing: first) == CRC32.checksum(bytes))
    }

    @Test("Adler-32 of Wikipedia is 11E60398")
    func adlerVector() {
        #expect(Adler32.checksum(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test("Adler-32 of nothing is one")
    func adlerEmpty() {
        #expect(Adler32.checksum([]) == 1)
    }

    // A million 0xFF bytes overflows a 32-bit sum unless the modulo is taken
    // in time; the value is zlib's.
    @Test("Adler-32 of a million 0xFF bytes matches zlib")
    func adlerLong() {
        #expect(Adler32.checksum([UInt8](repeating: 0xFF, count: 1_000_000)) == 0x3843_E1BE)
    }

    @Test("Adler-32 continued over two halves equals it over the whole")
    func adlerContinues() {
        let bytes = Samples.random(20_000)
        let first = Adler32.checksum(bytes[..<7777])
        #expect(Adler32.checksum(bytes[7777...], continuing: first) == Adler32.checksum(bytes))
    }
}
