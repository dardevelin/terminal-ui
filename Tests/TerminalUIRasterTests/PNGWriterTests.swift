import Foundation
import Testing
import TerminalUIIO
@testable import TerminalUIRaster

/// A PNG's chunks, each checked against its CRC as it is read (PNG §5.3).
private struct Chunk {
    let type: String
    let data: [UInt8]
}

private func chunks(of png: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) -> [Chunk] {
    #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "signature", sourceLocation: sourceLocation)
    var result: [Chunk] = []
    var offset = 8
    while offset + 12 <= png.count {
        let length = bigEndian(png, at: offset)
        let typeAndData = Array(png[(offset + 4)..<(offset + 8 + length)])
        #expect(bigEndian(png, at: offset + 8 + length) == Int(CRC32.checksum(typeAndData)),
                "CRC", sourceLocation: sourceLocation)
        result.append(Chunk(type: String(decoding: typeAndData.prefix(4), as: UTF8.self),
                            data: Array(typeAndData.dropFirst(4))))
        offset += 12 + length
    }
    #expect(offset == png.count, "trailing bytes", sourceLocation: sourceLocation)
    return result
}

private func bigEndian(_ bytes: [UInt8], at offset: Int) -> Int {
    bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
}

/// The filtered scanlines, each its filter byte and then its bytes.
private func scanlines(of found: [Chunk]) throws -> [UInt8] {
    let stream = found.filter { $0.type == "IDAT" }.flatMap(\.data)
    return [UInt8](try Inflate.decode(zlibBody(stream)))
}

@Suite("PNG writer")
struct PNGWriterTests {

    @Test("an RGB canvas matches its golden, alpha dropped")
    func rgbGolden() throws {
        let png = PNGWriter.encode(Samples.rgbCanvas(), colourType: .rgb)
        try expectGolden(png, named: "rgb-5x4.png")
        let found = chunks(of: png)
        #expect(found.map(\.type) == ["IHDR", "sRGB", "IDAT", "IEND"])
        // Width, height, bit depth 8, colour type 2, then compression,
        // filter and interlace methods 0 (PNG §11.2.2).
        #expect(found[0].data == [0, 0, 0, 5, 0, 0, 0, 4, 8, 2, 0, 0, 0])
        #expect(found[1].data == [0], "perceptual rendering intent")
        #expect(found[3].data.isEmpty)
        #expect(try scanlines(of: found).count == 4 * (1 + 5 * 3))
    }

    @Test("an RGBA canvas matches its golden")
    func rgbaGolden() throws {
        let png = PNGWriter.encode(Samples.rgbaCanvas(), colourType: .rgba)
        try expectGolden(png, named: "rgba-4x3.png")
        let found = chunks(of: png)
        #expect(found.map(\.type) == ["IHDR", "sRGB", "IDAT", "IEND"])
        #expect(found[0].data == [0, 0, 0, 4, 0, 0, 0, 3, 8, 6, 0, 0, 0])
        #expect(try scanlines(of: found).count == 3 * (1 + 4 * 4))
    }

    // Five entries take four bits a pixel; tRNS stops after the last entry
    // that is not opaque (PNG §11.3.2.1).
    @Test("an indexed image matches its golden, with PLTE and a trimmed tRNS")
    func indexedGolden() throws {
        let png = PNGWriter.encode(Samples.indexedImage())
        try expectGolden(png, named: "indexed-6x5.png")
        let found = chunks(of: png)
        #expect(found.map(\.type) == ["IHDR", "sRGB", "PLTE", "tRNS", "IDAT", "IEND"])
        #expect(found[0].data == [0, 0, 0, 6, 0, 0, 0, 5, 4, 3, 0, 0, 0])
        #expect(found[2].data == Samples.indexedPalette.flatMap { [$0.red, $0.green, $0.blue] })
        #expect(found[3].data == [0xFF, 0xFF, 0x80])
        let lines = try scanlines(of: found)
        #expect(lines.count == 5 * (1 + 3))
        #expect(stride(from: 0, to: lines.count, by: 4).allSatisfy { lines[$0] == 0 }, "filter 0 throughout")
        // Row 0 is indices 0 1 2 3 4 0, high nibble first.
        #expect(Array(lines[1..<4]) == [0x01, 0x23, 0x40])
    }

    @Test("a two-colour image packs one bit a pixel, no tRNS when opaque")
    func oneBitGolden() throws {
        let png = PNGWriter.encode(Samples.twoColourImage())
        try expectGolden(png, named: "indexed-9x3.png")
        let found = chunks(of: png)
        #expect(found.map(\.type) == ["IHDR", "sRGB", "PLTE", "IDAT", "IEND"])
        #expect(found[0].data[8] == 1)
        // Row 0 is 0 1 0 1 0 1 0 1 0, most significant bit first, padded.
        #expect(Array(try scanlines(of: found)[0..<3]) == [0, 0b0101_0101, 0])
    }

    // PNG §12.8: the heuristic picks, per row, the filter whose output has the
    // smallest sum of absolute values as signed bytes; a tie goes to the
    // lower filter type. On a first row Paeth predicts from the left alone,
    // as Sub does, and where rows differ by a constant it predicts from
    // above, as Up does — so these ties are what the order decides.
    @Test("a ramp along the row is filtered Sub, one down the columns Up, black None")
    func adaptiveFilters() throws {
        func filterTypes(_ canvas: PixelCanvas) throws -> [UInt8] {
            let lines = try scanlines(of: chunks(of: PNGWriter.encode(canvas, colourType: .rgb)))
            return stride(from: 0, to: lines.count, by: 1 + canvas.width * 3).map { lines[$0] }
        }
        var horizontal = PixelCanvas(width: 32, height: 1)
        var vertical = PixelCanvas(width: 32, height: 4)
        for x in 0..<32 {
            horizontal[x, 0] = RGBA(UInt8(x * 7), UInt8(x * 3), UInt8(x))
            for y in 0..<4 {
                vertical[x, y] = RGBA(UInt8(37 * x % 251 + y), UInt8(91 * x % 241 + y), UInt8(53 * x % 239 + y))
            }
        }
        #expect(try filterTypes(horizontal) == [1])
        #expect(try filterTypes(vertical).dropFirst() == [2, 2, 2])
        #expect(try filterTypes(PixelCanvas(width: 8, height: 3, fill: RGBA(0, 0, 0))) == [0, 0, 0])
    }

    @Test("image data is split into IDAT chunks of 32 KiB")
    func idatSplit() throws {
        var generator = SampleRandom(seed: Samples.noiseSeed)
        var canvas = PixelCanvas(width: 128, height: 96)
        for y in 0..<96 {
            for x in 0..<128 {
                canvas[x, y] = RGBA(generator.nextByte(), generator.nextByte(), generator.nextByte())
            }
        }
        let found = chunks(of: PNGWriter.encode(canvas, colourType: .rgb))
        let idat = found.filter { $0.type == "IDAT" }
        #expect(idat.count == 2)
        #expect(idat[0].data.count == 32_768)
        #expect(try scanlines(of: found).count == 96 * (1 + 128 * 3))
    }
}

@Suite("Pixel canvas")
struct PixelCanvasTests {

    @Test("a pixel set is the pixel got, and lands in its row")
    func setAndGet() {
        var canvas = PixelCanvas(width: 3, height: 2, fill: RGBA(1, 2, 3, 4))
        canvas[2, 1] = RGBA(9, 8, 7, 6)
        #expect(canvas[2, 1] == RGBA(9, 8, 7, 6))
        #expect(canvas[0, 0] == RGBA(1, 2, 3, 4))
        #expect(Array(canvas.row(1)) == [1, 2, 3, 4, 1, 2, 3, 4, 9, 8, 7, 6])
    }

    @Test("a new canvas is transparent")
    func transparent() {
        #expect(PixelCanvas(width: 2, height: 2).bytes == [UInt8](repeating: 0, count: 16))
    }
}
