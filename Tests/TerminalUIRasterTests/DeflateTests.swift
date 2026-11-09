import Foundation
import Testing
import TerminalUIIO
@testable import TerminalUIRaster

@Suite("Deflate — RFC 1951 encoder and RFC 1950 wrapper")
struct DeflateTests {

    private func roundTrip(_ input: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let decoded = try Inflate.decode(Data(Deflate.compress(input)))
        #expect([UInt8](decoded) == input, "\(input.count) bytes", sourceLocation: sourceLocation)
    }

    // MARK: - Goldens

    // One final fixed block holding only end-of-block: 3 header bits and the
    // 7-bit code 256 — what zlib writes too.
    @Test("nothing compresses to an empty fixed block")
    func emptyInput() throws {
        #expect(Deflate.compress([]) == [0x03, 0x00])
        try roundTrip([])
    }

    @Test("one byte compresses to the same three bytes zlib writes")
    func singleByte() throws {
        #expect(Deflate.compress(Array("a".utf8)) == [0x4B, 0x04, 0x00])
    }

    // Three literals, then one match of 27 bytes three back: 48 bits.
    @Test("a short repeated pattern compresses to three literals and one match")
    func repetitiveGolden() {
        #expect(Deflate.compress(Samples.repetitive) == [0x4B, 0x4C, 0x4A, 0xC6, 0x83, 0x00])
    }

    @Test("zlib streams match their committed fixtures")
    func zlibGoldens() throws {
        try expectGolden(Deflate.zlibCompress([]), named: "empty.zlib")
        try expectGolden(Deflate.zlibCompress(Samples.repetitive), named: "repetitive.zlib")
        try expectGolden(Deflate.zlibCompress(Samples.text(wordCount: 800)), named: "text.zlib")
        try expectGolden(Deflate.zlibCompress(Samples.random(2048)), named: "random.zlib")
    }

    // MARK: - Round trips through TerminalUIIO's decoder

    @Test("tiny inputs round-trip", arguments: ["", "a", "ab", "abc", "aaaa", "Hello", "abababababab"])
    func tinyRoundTrips(_ text: String) throws {
        try roundTrip(Array(text.utf8))
    }

    @Test("random inputs round-trip", arguments: [1, 2, 3, 257, 1024, 70_000])
    func randomRoundTrips(_ count: Int) throws {
        try roundTrip(Samples.random(count))
    }

    @Test("text round-trips across many blocks and far back-references")
    func textRoundTrip() throws {
        try roundTrip(Samples.text(wordCount: 40_000))
    }

    @Test("a long run of one byte round-trips through distance-one matches")
    func longRun() throws {
        let input = [UInt8](repeating: 0x42, count: 100_000)
        try roundTrip(input)
        #expect(Deflate.compress(input).count < 300)
    }

    // A match reaches 32 768 bytes back and no further. Noise in sixteen
    // values repeats itself only in short matches, so a copy of it found
    // exactly a window back is taken in 258-byte matches, and one byte
    // further back is not found at all. (Sixteen values, not 256: the
    // decoder here walks its Huffman codes slowly for wide alphabets.)
    @Test("a repeat exactly a window back is matched, one byte further is not")
    func windowEdge() throws {
        let block = Samples.random(DeflateFormat.windowSize).map { $0 & 0x0F }
        let atEdge = block + block.prefix(1000)
        let pastEdge = block + [0] + block.prefix(1000)
        try roundTrip(atEdge)
        try roundTrip(pastEdge)
        #expect(LZ77.tokens(of: atEdge).contains { $0.distance == DeflateFormat.windowSize && $0.value == 258 })
        #expect(Deflate.compress(pastEdge).count > Deflate.compress(atEdge).count + 300)
    }

    // MARK: - Block choice

    @Test("incompressible input is stored")
    func incompressibleIsStored() {
        let encoded = Deflate.encode(Samples.random(4096))
        #expect(encoded.blockTypes == [.stored])
        #expect(encoded.bytes.count == 4096 + 5)
    }

    @Test("a short repetitive input takes the fixed code")
    func repetitiveIsFixed() {
        #expect(Deflate.encode(Samples.repetitive).blockTypes == [.fixed])
    }

    @Test("a page of text takes a dynamic code")
    func textIsDynamic() {
        let input = Samples.text(wordCount: 800)
        let encoded = Deflate.encode(input)
        #expect(encoded.blockTypes == [.dynamic])
        #expect(encoded.bytes.count * 3 < input.count)
    }

    // 140 000 random bytes are nearly all literals: three blocks of at most
    // 65 536 symbols, each stored.
    @Test("a block ends every 64 Ki symbols")
    func blocksSplit() throws {
        let input = Samples.random(140_000)
        let encoded = Deflate.encode(input)
        #expect(encoded.blockTypes == [.stored, .stored, .stored])
        try roundTrip(input)
    }

    // MARK: - zlib wrapper

    @Test("the zlib wrapper has a checked header and a big-endian Adler-32")
    func zlibWrapper() throws {
        let input = Samples.text(wordCount: 300)
        let stream = Deflate.zlibCompress(input)
        #expect(stream[0] == 0x78)
        #expect((Int(stream[0]) * 256 + Int(stream[1])) % 31 == 0)
        #expect(stream[1] & 0x20 == 0, "no preset dictionary")
        let adler = Adler32.checksum(input)
        #expect(Array(stream.suffix(4)) == [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF),
                                            UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        #expect([UInt8](try Inflate.decode(zlibBody(stream))) == input)
    }
}

@Suite("Huffman code lengths and canonical codes")
struct HuffmanCodeTests {

    @Test("unlimited lengths are Huffman's")
    func unlimited() {
        #expect(HuffmanCode.lengths(frequencies: [1, 1, 2, 4], limit: 15) == [3, 3, 2, 1])
    }

    @Test("a tight limit flattens the code")
    func limited() {
        #expect(HuffmanCode.lengths(frequencies: [1, 1, 2, 4], limit: 2) == [2, 2, 2, 2])
    }

    @Test("unused symbols get no code")
    func unused() {
        #expect(HuffmanCode.lengths(frequencies: [0, 5, 0, 3, 1], limit: 15) == [0, 1, 0, 2, 2])
    }

    // A code of one length-1 symbol is incomplete, which zlib accepts only
    // for distances; two codes of length 1 are valid everywhere.
    @Test("a lone symbol is paired with the lowest unused one")
    func lone() {
        #expect(HuffmanCode.lengths(frequencies: [0, 0, 9, 0], limit: 15) == [1, 0, 1, 0])
        #expect(HuffmanCode.lengths(frequencies: [0, 0, 0, 0], limit: 15) == [1, 1, 0, 0])
    }

    // Fibonacci weights are the worst case: Huffman's code for 30 of them is
    // 29 bits deep. Package-merge must hold it to 15 and keep it complete.
    @Test("Fibonacci frequencies are held to fifteen bits and stay complete")
    func fibonacci() {
        var frequencies = [1, 1]
        while frequencies.count < 30 { frequencies.append(frequencies[frequencies.count - 1] + frequencies[frequencies.count - 2]) }
        let lengths = HuffmanCode.lengths(frequencies: frequencies, limit: 15)
        #expect(lengths.max() == 15)
        #expect(lengths.reduce(0) { $0 + (1 << (15 - $1)) } == 1 << 15)
        #expect(HuffmanCode.lengths(frequencies: frequencies, limit: 29).max() == 29)
    }

    // RFC 1951 §3.2.2's own example: lengths (3, 3, 3, 3, 3, 2, 4, 4) for A–H.
    @Test("canonical codes are the RFC's example")
    func canonical() {
        #expect(HuffmanCode.canonicalCodes(lengths: [3, 3, 3, 3, 3, 2, 4, 4])
                == [0b010, 0b011, 0b100, 0b101, 0b110, 0b00, 0b1110, 0b1111])
    }
}
