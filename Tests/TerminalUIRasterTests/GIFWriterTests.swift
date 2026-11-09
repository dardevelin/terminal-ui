import Testing
@testable import TerminalUIRaster

/// A GIF LZW decoder written from GIF89a Appendix F, apart from the
/// encoder: it notes how many entries its table held at each clear code
/// after the first.
private struct LZWDecoding {
    var indices: [UInt8] = []
    var tableSizesAtClear: [Int] = []
}

private func lzwDecode(_ bytes: [UInt8], minimumCodeSize: Int) -> LZWDecoding? {
    let clearCode = 1 << minimumCodeSize
    let initial: [[UInt8]] = (0..<clearCode).map { [UInt8($0)] } + [[], []]
    var result = LZWDecoding()
    var table = initial
    var width = minimumCodeSize + 1
    var previous: [UInt8]?
    var bitPosition = 0
    var sawClear = false
    while true {
        guard bitPosition + width <= bytes.count * 8 else { return nil }
        var code = 0
        for bit in 0..<width where bytes[(bitPosition + bit) / 8] & (1 << ((bitPosition + bit) % 8)) != 0 {
            code |= 1 << bit
        }
        bitPosition += width
        if code == clearCode {
            if sawClear { result.tableSizesAtClear.append(table.count) }
            sawClear = true
            table = initial
            width = minimumCodeSize + 1
            previous = nil
            continue
        }
        if code == clearCode + 1 { return result }
        let entry: [UInt8]
        if code < table.count {
            entry = table[code]
        } else if code == table.count, let previous {
            entry = previous + [previous[0]]
        } else {
            return nil
        }
        result.indices += entry
        if let previous, table.count < 4096 { table.append(previous + [entry[0]]) }
        previous = entry
        if table.count == 1 << width, width < 12 { width += 1 }
    }
}

private func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
    guard needle.count <= bytes.count else { return false }
    return (0...(bytes.count - needle.count)).contains { Array(bytes[$0..<($0 + needle.count)]) == needle }
}

@Suite("LZW — GIF89a Appendix F")
struct LZWTests {

    @Test("random indices round-trip at every code size", arguments: 2...8)
    func roundTrips(_ minimumCodeSize: Int) throws {
        var generator = SampleRandom(seed: UInt64(minimumCodeSize))
        let indices = generator.bytes(5000).map { $0 & UInt8((1 << minimumCodeSize) - 1) }
        let decoded = try #require(lzwDecode(LZW.encode(indices, minimumCodeSize: minimumCodeSize),
                                             minimumCodeSize: minimumCodeSize))
        #expect(decoded.indices == indices)
    }

    @Test("a single pixel and a long run round-trip", arguments: [[3], [UInt8](repeating: 0, count: 50_000)])
    func edges(_ indices: [UInt8]) throws {
        let decoded = try #require(lzwDecode(LZW.encode(indices, minimumCodeSize: 2), minimumCodeSize: 2))
        #expect(decoded.indices == indices)
    }

    // Clear, then 0 (3 bits), 0 0 as code 6, 1, 1 1 as code 8 (4 bits from
    // here), 2, then end-of-information.
    @Test("a tiny input encodes to its golden bytes")
    func golden() {
        #expect(LZW.encode([0, 0, 0, 1, 1, 1, 2], minimumCodeSize: 2) == [0x84, 0x83, 0x52])
    }

    // The encoder clears when its table holds 4096 entries; the decoder,
    // one entry behind it, holds 4095 then. Noise fills a table in about
    // 3800 codes, so 20 000 pixels clear several times.
    @Test("the table is cleared exactly when it reaches 4096 entries")
    func resetAt4096() throws {
        let indices = Samples.random(20_000)
        let decoded = try #require(lzwDecode(LZW.encode(indices, minimumCodeSize: 8), minimumCodeSize: 8))
        #expect(decoded.indices == indices)
        #expect(decoded.tableSizesAtClear.count >= 4)
        #expect(decoded.tableSizesAtClear.allSatisfy { $0 == 4095 })
    }
}

@Suite("GIF writer")
struct GIFWriterTests {

    @Test("a two-frame animation matches its golden")
    func twoFrameGolden() throws {
        try expectGolden(Samples.twoFrameGIF(), named: "two-frames.gif")
    }

    @Test("noise in 256 colours matches its golden")
    func noiseGolden() throws {
        try expectGolden(Samples.noiseGIF(), named: "noise.gif")
    }

    @Test("the header, screen and global table are GIF89a's")
    func screen() {
        let gif = Samples.twoFrameGIF()
        #expect(Array(gif.prefix(6)) == Array("GIF89a".utf8))
        // 8×6; a global table of 2^(1+1) entries at 8 bits a primary.
        #expect(Array(gif[6..<13]) == [8, 0, 6, 0, 0xF1, 0, 0])
        #expect(Array(gif[13..<25]) == Samples.gifGlobalPalette.flatMap { [$0.red, $0.green, $0.blue] })
        #expect(gif.last == 0x3B)
    }

    @Test("a loop count of zero writes NETSCAPE2.0 looping forever")
    func loops() {
        let netscape = [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        #expect(Array(Samples.twoFrameGIF()[25..<44]) == netscape)
        #expect(!contains(Samples.noiseGIF(), Array("NETSCAPE".utf8)))
    }

    // Disposal sits in bits 2–4, the transparency flag in bit 0, and the
    // delay is little-endian centiseconds (GIF89a §23).
    @Test("each frame's control extension carries disposal, delay and transparency")
    func controlExtensions() {
        let gif = Samples.twoFrameGIF()
        #expect(contains(gif, [0x21, 0xF9, 0x04, 0x04, 50, 0, 0, 0]))
        #expect(contains(gif, [0x21, 0xF9, 0x04, 0x05, 125, 0, 1, 0]))
    }

    // Three colours take a table of four, padded with black (GIF89a §21).
    @Test("a dirty rectangle sits at its place with its own table")
    func dirtyRectangle() {
        let gif = Samples.twoFrameGIF()
        let local: [UInt8] = Samples.gifLocalPalette.flatMap { [$0.red, $0.green, $0.blue] } + [0, 0, 0]
        #expect(contains(gif, [0x2C, 2, 0, 1, 0, 3, 0, 2, 0, 0x81] as [UInt8] + local + [2]))
    }

    @Test("image data is in sub-blocks of 255 bytes and decodes to the frame")
    func subBlocks() throws {
        let gif = Samples.noiseGIF()
        // Header and screen, a 256-entry table, one control extension, one
        // image descriptor: the minimum code size follows.
        var offset = 13 + 768 + 8 + 10
        #expect(gif[offset] == 8)
        offset += 1
        var data: [UInt8] = []
        var lengths: [Int] = []
        while gif[offset] != 0 {
            lengths.append(Int(gif[offset]))
            data += gif[(offset + 1)..<(offset + 1 + Int(gif[offset]))]
            offset += 1 + Int(gif[offset])
        }
        #expect(lengths.dropLast().allSatisfy { $0 == 255 })
        #expect(lengths.count > 20)
        #expect(Array(gif[(offset + 1)...]) == [0x3B])
        var generator = SampleRandom(seed: Samples.noiseSeed)
        #expect(try #require(lzwDecode(data, minimumCodeSize: 8)).indices == generator.bytes(96 * 64))
    }
}
