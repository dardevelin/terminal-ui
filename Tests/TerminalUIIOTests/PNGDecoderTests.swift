import Foundation
import Testing
@testable import TerminalUIIO

/// The fixtures are written by `tools/scripts/make_png_fixtures.py`, which
/// computes each `.rgba` from its pixel model rather than by decoding, and
/// ImageMagick decodes every one of them to the same bytes: the decoder is
/// checked against two readings that are not its own.
@Suite("PNG decoder")
struct PNGDecoderTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent("png")

    private static var fixtureNames: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(".png".count)) }.sorted()
    }

    private static func fixture(_ name: String, _ suffix: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).\(suffix)"))
    }

    @Test("every colour type, depth, filter, interlace and tRNS decodes to its pixels",
          arguments: PNGDecoderTests.fixtureNames)
    func decodesFixture(_ name: String) throws {
        let image = try PNGDecoder().decode(try Self.fixture(name, "png"))
        #expect(image.width == 13)
        #expect(image.height == 11)
        #expect(image.rgba == [UInt8](try Self.fixture(name, "rgba")))
    }

    @Test("the fixtures cover every colour type and depth the specification allows")
    func coverage() {
        let names = Set(Self.fixtureNames)
        for (type, depths) in [(0, [1, 2, 4, 8, 16]), (2, [8, 16]), (3, [1, 2, 4, 8]), (4, [8, 16]), (6, [8, 16])] {
            for depth in depths {
                #expect(names.contains("type\(type)-depth\(depth)"))
                #expect(names.contains("type\(type)-depth\(depth)-adam7"))
            }
        }
        #expect(names.filter { $0.hasSuffix("-trns") }.count == 11)
    }

    @Test("bytes that are not a PNG are an unsupported format")
    func notPNG() {
        #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data([0xFF, 0xD8, 0xFF, 0xE0])) }
        do {
            _ = try PNGDecoder().decode(Data("GIF89a".utf8))
            Issue.record("a GIF decoded")
        } catch {
            guard case .unsupportedFormat(let magic) = error else {
                Issue.record("expected unsupportedFormat, got \(error)")
                return
            }
            #expect(magic == Array("GIF89a".utf8))
        }
    }

    @Test("a file cut short anywhere throws rather than traps")
    func truncation() throws {
        let whole = [UInt8](try Self.fixture("type6-depth16-adam7", "png"))
        for length in 0..<whole.count {
            #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(whole[0..<length])) }
        }
    }

    @Test("a flipped byte anywhere is caught by a CRC or throws; it never traps")
    func corruption() throws {
        let whole = [UInt8](try Self.fixture("type3-depth4-trns", "png"))
        for offset in 0..<whole.count {
            var damaged = whole
            damaged[offset] ^= 0x5A
            #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(damaged)) }
        }
    }

    @Test("a stream that inflates past the rows the header promises is refused")
    func decompressionBomb() throws {
        // A 1×1 greyscale image needs two inflated bytes; this stream holds a
        // megabyte of zeros.
        let rows = PNGTestImage.zlibStored([UInt8](repeating: 0, count: 1 << 20))
        let bytes = PNGTestImage.file(width: 1, height: 1, depth: 8, colourType: 0, imageData: rows)
        #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(bytes)) }
    }

    @Test("dimensions beyond the pixel limit are refused before any inflating")
    func tooLarge() {
        let bytes = PNGTestImage.file(width: 1 << 14, height: 1 << 14, depth: 8, colourType: 0,
                                      imageData: PNGTestImage.zlibStored([0]))
        #expect(refusal(bytes)?.contains("more pixels than the decoder allows") == true)
        // The largest dimensions a header can state, whose buffers' sizes
        // would not fit in an Int even with no limit.
        let largest = PNGTestImage.file(width: Int(Int32.max), height: Int(Int32.max), depth: 16, colourType: 6,
                                        imageData: PNGTestImage.zlibStored([0]))
        #expect(refusal(largest, PNGDecoder(maximumPixelCount: .max))?.contains("more pixels") == true)
    }

    @Test("a decoder's own pixel limit is the one it holds images to")
    func ownLimit() {
        let bytes = PNGTestImage.file(width: 2, height: 2, depth: 8, colourType: 0,
                                      imageData: PNGTestImage.zlibStored([0, 1, 2, 0, 3, 4]))
        #expect(refusal(bytes, PNGDecoder(maximumPixelCount: 3))?.contains("more pixels") == true)
        #expect((try? PNGDecoder(maximumPixelCount: 4).decode(Data(bytes)))?.rgba.count == 16)
    }

    @Test("chunks out of the order §5.6 sets are refused", arguments: ChunkOrder.allCases)
    func chunkOrder(_ order: ChunkOrder) {
        #expect(refusal(order.file)?.contains(order.expected) == true, "\(order)")
    }

    enum ChunkOrder: CaseIterable {
        case paletteAfterImageData, splitImageData, noImageData, headerNotFirst, secondHeader

        var file: [UInt8] {
            let header = PNGTestImage.header(width: 1, height: 1, depth: 8, colourType: 3)
            let data = PNGTestImage.zlibStored([0, 0])
            let palette = PNGTestImage.chunk("PLTE", [10, 20, 30])
            let text = PNGTestImage.chunk("tEXt", Array("a\u{0}b".utf8))
            let chunks: [[UInt8]] = switch self {
            case .paletteAfterImageData: [header, PNGTestImage.chunk("IDAT", data), palette]
            case .splitImageData:
                [header, palette, PNGTestImage.chunk("IDAT", Array(data.prefix(3))), text,
                 PNGTestImage.chunk("IDAT", Array(data.dropFirst(3)))]
            case .noImageData: [header, palette]
            case .headerNotFirst: [palette, header, PNGTestImage.chunk("IDAT", data)]
            case .secondHeader: [header, header, palette, PNGTestImage.chunk("IDAT", data)]
            }
            return PNGTestImage.signature + chunks.joined() + PNGTestImage.chunk("IEND", [])
        }

        var expected: String {
            switch self {
            case .paletteAfterImageData: "PLTE out of order"
            case .splitImageData: "not consecutive"
            case .noImageData: "no IDAT"
            case .headerNotFirst: "IHDR is not the first"
            case .secondHeader: "a second IHDR"
            }
        }
    }

    @Test("a damaged byte behind a recomputed CRC throws or decodes; it never traps",
          arguments: ["type2-depth16-adam7", "type3-depth2-trns", "type0-depth1", "type6-depth8"])
    func corruptionPastTheCRC(_ name: String) throws {
        // A CRC turns away almost every flipped byte at the chunk; with it
        // recomputed, the damage reaches the header, the palette, inflate
        // and the filters.
        let whole = [UInt8](try Self.fixture(name, "png"))
        for offset in Signature.length..<whole.count {
            for replacement in [0x00, 0xFF, whole[offset] ^ 0x5A] as [UInt8] {
                var damaged = whole
                damaged[offset] = replacement
                PNGTestImage.recomputeCRCs(&damaged)
                if let image = try? PNGDecoder().decode(Data(damaged)) {
                    #expect(image.rgba.count == image.width * image.height * 4)
                }
            }
        }
    }

    private enum Signature {
        static let length = 8
    }

    @Test("an unknown filter type, colour type or depth throws")
    func badHeaderAndFilter() {
        let badFilter = PNGTestImage.file(width: 1, height: 1, depth: 8, colourType: 0,
                                          imageData: PNGTestImage.zlibStored([9, 0]))
        #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(badFilter)) }
        let badDepth = PNGTestImage.file(width: 1, height: 1, depth: 3, colourType: 0,
                                         imageData: PNGTestImage.zlibStored([0, 0]))
        #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(badDepth)) }
        let noPalette = PNGTestImage.file(width: 1, height: 1, depth: 8, colourType: 3,
                                          imageData: PNGTestImage.zlibStored([0, 0]))
        #expect(throws: ImageDecodeError.self) { try PNGDecoder().decode(Data(noPalette)) }
        let good = PNGTestImage.file(width: 1, height: 1, depth: 8, colourType: 0,
                                     imageData: PNGTestImage.zlibStored([0, 200]))
        #expect((try? PNGDecoder().decode(Data(good)))?.rgba == [200, 200, 200, 255])
    }
}

/// PNG files assembled in the test, for the cases a fixture would only
/// obscure: a stored zlib stream, so the bytes are what they say.
enum PNGTestImage {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func file(width: Int, height: Int, depth: UInt8, colourType: UInt8, imageData: [UInt8]) -> [UInt8] {
        signature + header(width: width, height: height, depth: depth, colourType: colourType)
            + chunk("IDAT", imageData) + chunk("IEND", [])
    }

    /// An IHDR chunk: deflate, the adaptive filters, no interlacing.
    static func header(width: Int, height: Int, depth: UInt8, colourType: UInt8) -> [UInt8] {
        chunk("IHDR", word(UInt32(width)) + word(UInt32(height)) + [depth, colourType, 0, 0, 0])
    }

    /// Rewrite every chunk's CRC to match its type and data, as far as the
    /// lengths still frame chunks.
    static func recomputeCRCs(_ bytes: inout [UInt8]) {
        var position = signature.count
        while position + 12 <= bytes.count {
            let length = bytes[position..<(position + 4)].reduce(0) { $0 << 8 | Int($1) }
            let crcAt = position + 8 + length
            guard crcAt + 4 <= bytes.count else { return }
            bytes.replaceSubrange(crcAt..<(crcAt + 4), with: word(CRC32.checksum(bytes[(position + 4)..<crcAt])))
            position = crcAt + 4
        }
    }

    /// RFC 1950 around RFC 1951 stored blocks of at most 65 535 bytes.
    static func zlibStored(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var start = 0
        repeat {
            let end = min(start + Int(UInt16.max), bytes.count)
            let length = UInt16(end - start)
            out.append(end == bytes.count ? 1 : 0)
            out += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
            out += bytes[start..<end]
            start = end
        } while start < bytes.count
        return out + word(Adler32.checksum(bytes))
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return word(UInt32(data.count)) + typeBytes + data + word(CRC32.checksum((typeBytes + data)[...]))
    }

    private static func word(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

private func refusal(_ bytes: [UInt8], _ decoder: PNGDecoder = PNGDecoder()) -> String? {
    do {
        _ = try decoder.decode(Data(bytes))
        return nil
    } catch {
        switch error {
        case .malformedData(let reason): return reason
        case .unsupportedFormat: return "unsupported format"
        }
    }
}
