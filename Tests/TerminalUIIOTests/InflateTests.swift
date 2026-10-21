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
