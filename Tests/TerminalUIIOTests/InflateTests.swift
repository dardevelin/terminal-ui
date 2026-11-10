import Foundation
import Testing
@testable import TerminalUIIO

// Pure-Swift RFC 1951 deflate decoder.
// Tests use fixtures pre-generated on macOS via Apple's Compression
// framework (raw deflate format, no zlib wrapping). Decoder runs
// identically on macOS + Linux Docker.

@Suite("Inflate — RFC 1951 deflate decoder")
struct InflateTests {

    // MARK: - Block types

    @Test("empty stream produces empty output")
    func emptyStream() throws {
        let fixture = try fixtureData(named: "empty.deflate")
        let output = try Inflate.decode(fixture)
        #expect(output.isEmpty)
    }

    @Test("single-byte fixed-Huffman block round-trips")
    func singleByteFixedHuffman() throws {
        let fixture = try fixtureData(named: "single-byte.deflate")
        let output = try Inflate.decode(fixture)
        #expect(output == Data([0x41]))  // 'A'
    }

    @Test("short ASCII string (Hello) decodes")
    func helloAscii() throws {
        let fixture = try fixtureData(named: "hello.deflate")
        let output = try Inflate.decode(fixture)
        #expect(output == "Hello".data(using: .utf8)!)
    }

    // MARK: - Back-references / sliding window

    @Test("repeated bytes decode via back-references")
    func repeatedBytesBackref() throws {
        let fixture = try fixtureData(named: "repeat-256.deflate")
        let output = try Inflate.decode(fixture)
        #expect(output == Data(repeating: 0x42, count: 256))
    }

    @Test("random 1024 bytes round-trip exactly")
    func random1024RoundTrip() throws {
        let fixture = try fixtureData(named: "random-1024.deflate")
        let original = try fixtureData(named: "random-1024.bin")
        let output = try Inflate.decode(fixture)
        #expect(output == original)
    }

    @Test("100KB pattern exercises sliding-window wraparound > 32KB")
    func longPatternSlidingWindow() throws {
        let fixture = try fixtureData(named: "long-pattern.deflate")
        let original = try fixtureData(named: "long-pattern.bin")
        let output = try Inflate.decode(fixture)
        #expect(output.count == original.count)
        #expect(output == original)
    }

    // MARK: - Error paths

    @Test("truncated stream throws truncatedInput")
    func truncatedStreamThrows() {
        // Take a known-good fixture and lop off the trailing bytes.
        guard let fixture = try? fixtureData(named: "hello.deflate") else {
            Issue.record("fixture missing")
            return
        }
        let truncated = fixture.prefix(2)
        #expect(throws: InflateError.self) {
            _ = try Inflate.decode(truncated)
        }
    }

    @Test("entirely empty input throws truncatedInput")
    func emptyInputThrows() {
        #expect(throws: InflateError.self) {
            _ = try Inflate.decode(Data())
        }
    }

    // MARK: - Stored block (uncompressed)

    @Test("stored block with valid LEN/~LEN round-trips")
    func storedBlockRoundTrip() throws {
        // Hand-crafted stored block:
        // BFINAL=1, BTYPE=00 (stored) → first byte = 0b00000001 = 0x01
        // After header byte, must skip to byte boundary, then LEN(LSB),
        // LEN(MSB), ~LEN(LSB), ~LEN(MSB), then LEN bytes of literal data.
        // LEN = 5 ("World"). ~LEN = 0xFFFA.
        var data = Data()
        data.append(0x01)              // BFINAL=1, BTYPE=00
        data.append(0x05)              // LEN low
        data.append(0x00)              // LEN high
        data.append(0xFA)              // ~LEN low
        data.append(0xFF)              // ~LEN high
        data.append(contentsOf: "World".utf8)

        let output = try Inflate.decode(data)
        #expect(output == "World".data(using: .utf8)!)
    }

    @Test("stored block with invalid LEN/~LEN throws")
    func storedBlockInvalidLengthThrows() {
        var data = Data()
        data.append(0x01)              // BFINAL=1, BTYPE=00
        data.append(0x05)              // LEN low
        data.append(0x00)              // LEN high
        data.append(0xFF)              // ~LEN low (wrong; should be 0xFA)
        data.append(0xFF)              // ~LEN high
        data.append(contentsOf: "World".utf8)

        #expect(throws: InflateError.self) {
            _ = try Inflate.decode(data)
        }
    }

    // MARK: - Multi-block

    @Test("multiple blocks (non-final + final) concatenate output")
    func multipleBlocksConcatenate() throws {
        // Two stored blocks: "Hi " then "world".
        var data = Data()
        // Block 1: BFINAL=0, BTYPE=00
        data.append(0x00)
        data.append(0x03)              // LEN = 3
        data.append(0x00)
        data.append(0xFC)              // ~LEN = 0xFFFC
        data.append(0xFF)
        data.append(contentsOf: "Hi ".utf8)
        // Block 2: BFINAL=1, BTYPE=00
        data.append(0x01)
        data.append(0x05)              // LEN = 5
        data.append(0x00)
        data.append(0xFA)              // ~LEN = 0xFFFA
        data.append(0xFF)
        data.append(contentsOf: "world".utf8)

        let output = try Inflate.decode(data)
        #expect(output == "Hi world".data(using: .utf8)!)
    }

    // MARK: - A bound on the output

    @Test("a bounded decode returns a stream that fits, to the byte")
    func boundedFits() throws {
        let fixture = try fixtureData(named: "long-pattern.deflate")
        let original = try fixtureData(named: "long-pattern.bin")
        #expect(try Inflate.decode(fixture, outputLimit: original.count) == original)
    }

    @Test("a bounded decode stops at the limit and says so",
          arguments: ["long-pattern.deflate", "repeat-256.deflate", "random-1024.deflate"])
    func boundedRefuses(name: String) throws {
        let fixture = try fixtureData(named: name)
        let whole = try Inflate.decode(fixture)
        #expect(throws: BoundedInflateError.outputLimitExceeded(limit: whole.count - 1)) {
            try Inflate.decode(fixture, outputLimit: whole.count - 1)
        }
    }

    @Test("a bounded decode of a malformed stream says why")
    func boundedMalformed() throws {
        #expect(throws: BoundedInflateError.malformed(.truncatedInput)) {
            try Inflate.decode(Data(), outputLimit: 10)
        }
        // BFINAL=1, BTYPE=11: the reserved block type.
        #expect(throws: BoundedInflateError.malformed(.invalidBlockType)) {
            try Inflate.decode(Data([0x07]), outputLimit: 10)
        }
    }

    // MARK: - Code lengths deflate does not allow

    @Test("code lengths that claim more codes than their bits hold are refused")
    func overSubscribed() {
        // Three codes of one bit.
        #expect(throws: InflateError.invalidHuffmanCode) { try HuffmanTree(codeLengths: [1, 1, 1]) }
        #expect((try? HuffmanTree(codeLengths: [1, 2, 2])) != nil)
        // An incomplete set is allowed, as zlib allows it.
        #expect((try? HuffmanTree(codeLengths: [2, 2, 2])) != nil)
    }

    @Test("a dynamic block that declares more than 286 literal codes is refused")
    func tooManyLiteralCodes() {
        // BFINAL=1, BTYPE=10, then HLIT=31 (288 codes): bits 1, 0 1, 11111.
        #expect(throws: InflateError.invalidHuffmanCode) { try Inflate.decode(Data([0xFD, 0x00, 0x00])) }
    }

    // MARK: - Cost

    // A count-based decoder takes one step a bit of code it reads — one
    // lookup for a short code, one more and then one a bit for a long one —
    // so its steps stay within twice the input's bits. A decoder that
    // searched the symbols for each code would take tens to hundreds a bit.

    @Test("decoding takes at most two steps a bit of input", arguments: ["long-pattern", "repeat-256", "hello"])
    func linearInInput(name: String) throws {
        let fixture = [UInt8](try fixtureData(named: "\(name).deflate"))
        var statistics = InflateStatistics()
        _ = try Inflate.inflate(fixture, from: 0, limit: .max, statistics: &statistics)
        #expect(statistics.codeSteps > 0)
        #expect(statistics.codeSteps <= 2 * fixture.count * UInt8.bitWidth, "\(statistics.codeSteps) steps")
    }

    @Test("codes longer than the lookup table decode a step a bit")
    func longCodes() throws {
        // Lengths 1 to 15 and a second 15: a complete code whose longest
        // codes are well past the table's nine bits.
        let lengths = Array(1...15) + [15]
        let tree = try HuffmanTree(codeLengths: lengths)
        let (stream, bits) = HuffmanTestStream.encode(symbols: Array(lengths.indices), lengths: lengths)
        var reader = BitReader(bytes: stream)
        for symbol in lengths.indices {
            #expect(try tree.decode(reader: &reader) == symbol)
        }
        #expect(reader.codeSteps <= bits + lengths.count, "\(reader.codeSteps) steps for \(bits) bits")
    }
}

/// Canonical Huffman codes (RFC 1951 §3.2.2) written into a bit stream as
/// deflate packs them, for tests that need codes of chosen lengths.
enum HuffmanTestStream {
    static func encode(symbols: [Int], lengths: [Int]) -> (bytes: [UInt8], bits: Int) {
        let longest = lengths.max() ?? 0
        var counts = [Int](repeating: 0, count: longest + 1)
        for length in lengths where length > 0 { counts[length] += 1 }
        var next = [Int](repeating: 0, count: longest + 1)
        var code = 0
        for length in stride(from: 1, through: longest, by: 1) {
            code = (code + counts[length - 1]) << 1
            next[length] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            codes[symbol] = next[length]
            next[length] += 1
        }
        var bytes: [UInt8] = []
        var bitCount = 0
        for symbol in symbols {
            // Most significant bit of the code first, each into the next
            // least significant free bit of the stream.
            for bit in stride(from: lengths[symbol] - 1, through: 0, by: -1) {
                if bitCount % UInt8.bitWidth == 0 { bytes.append(0) }
                bytes[bytes.count - 1] |= UInt8((codes[symbol] >> bit) & 1) << UInt8(bitCount % UInt8.bitWidth)
                bitCount += 1
            }
        }
        return (bytes, bitCount)
    }
}

// MARK: - Fixture loader

private func fixtureData(named name: String) throws -> Data {
    let url = fixtureURL(named: name)
    return try Data(contentsOf: url)
}

private func fixtureURL(named name: String) -> URL {
    // Tests run from package root (`swift test`) on both macOS
    // local + Linux Docker. Path is relative to repo root.
    let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("inflate")
    return base.appendingPathComponent(name)
}
