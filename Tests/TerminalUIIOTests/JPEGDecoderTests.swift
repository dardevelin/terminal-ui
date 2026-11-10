import Foundation
import Testing
@testable import TerminalUIIO

// The fixtures are libjpeg-turbo's cjpeg output, each beside the RGBA two
// independent decoders make of it: macOS ImageIO (`<name>.rgba`) and
// libjpeg-turbo's djpeg (`<name>.djpeg.rgba`) — see
// tools/scripts/make_jpeg_fixtures.py and the README beside them.
//
// Decoders legitimately differ. T.81 A.3.3 defines the IDCT mathematically
// and leaves its arithmetic to the implementation, and chroma upsampling is
// not specified at all. libjpeg upsamples as this decoder does, by linear
// interpolation between sample centres, so the two agree within the
// rounding of their IDCTs. ImageIO upsamples another way, and where a
// sharp edge of colour crosses subsampled chroma the two references
// themselves disagree by tens of levels (up to 74 on these fixtures) while
// agreeing closely on average. So libjpeg's decode holds this one to a
// tight bound everywhere, and ImageIO's to a mean.

@Suite("JPEGDecoder — baseline JPEG")
struct JPEGDecoderTests {

    /// How far a decode may stray from libjpeg-turbo's, per channel: 3
    /// levels at most and 0.34 on average as measured — a float IDCT
    /// against libjpeg's integer one, and its upsampling's fixed-point
    /// rounding.
    static let libjpegMaximum = 3
    static let libjpegMean = 0.5

    /// How far it may stray from ImageIO's on average: 2.06 at most as
    /// measured, where libjpeg's own decode of the same file is 2.00.
    static let imageIOMean = 2.5

    static let compared = [
        "odd-444", "odd-422", "odd-420", "odd-440", "odd-grey", "restart-420", "restart-rows-444",
        "optimised-420", "coarse-16bit-tables", "separate-scans-420",
    ]

    @Test("every fixture decodes as libjpeg-turbo decodes it, within its IDCT's rounding",
          arguments: JPEGDecoderTests.compared)
    func matchesLibjpeg(name: String) throws {
        let image = try JPEGDecoder().decode(try fixture("\(name).jpg"))
        let difference = Self.difference(image.rgba, [UInt8](try fixture("\(name).djpeg.rgba")))
        #expect(difference.maximum <= Self.libjpegMaximum, "\(name): largest \(difference.maximum)")
        #expect(difference.mean <= Self.libjpegMean, "\(name): mean \(difference.mean)")
    }

    @Test("every fixture decodes close to what ImageIO decodes it to", arguments: JPEGDecoderTests.compared)
    func matchesImageIO(name: String) throws {
        let image = try JPEGDecoder().decode(try fixture("\(name).jpg"))
        let difference = Self.difference(image.rgba, [UInt8](try fixture("\(name).rgba")))
        #expect(difference.mean <= Self.imageIOMean, "\(name): mean \(difference.mean)")
    }

    @Test("an image of a size no multiple of a block or MCU keeps its size")
    func oddSize() throws {
        let image = try JPEGDecoder().decode(try fixture("odd-420.jpg"))
        #expect(image.width == 37)
        #expect(image.height == 29)
        #expect(stride(from: 3, to: image.rgba.count, by: 4).allSatisfy { image.rgba[$0] == 255 })
    }

    @Test("greyscale decodes to equal channels")
    func greyscale() throws {
        let image = try JPEGDecoder().decode(try fixture("odd-grey.jpg"))
        for pixel in stride(from: 0, to: image.rgba.count, by: 4) {
            #expect(image.rgba[pixel] == image.rgba[pixel + 1] && image.rgba[pixel] == image.rgba[pixel + 2])
        }
    }

    @Test("a whole 256-pixel 4:2:0 tile decodes")
    func tile() throws {
        let image = try JPEGDecoder().decode(try fixture("tile-256-420.jpg"))
        #expect(image.width == 256 && image.height == 256)
    }

    // MARK: - Refusals

    @Test("progressive JPEG is refused, saying so")
    func progressive() throws {
        let reason = refusal(try fixture("progressive.jpg"))
        #expect(reason?.contains("progressive JPEG is not supported") == true, "\(String(describing: reason))")
    }

    @Test("bytes that are not a JPEG are an unsupported format")
    func notJPEG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        #expect(throws: ImageDecodeError.self) { try JPEGDecoder().decode(png) }
        do {
            _ = try JPEGDecoder().decode(png)
        } catch {
            guard case .unsupportedFormat(let magic) = error else {
                Issue.record("expected unsupportedFormat, got \(error)")
                return
            }
            #expect(magic == [0x89, 0x50, 0x4E, 0x47])
        }
        #expect(throws: ImageDecodeError.self) { try JPEGDecoder().decode(Data()) }
    }

    @Test("a frame header out of range is refused", arguments: FrameEdit.allCases)
    func frameHeader(edit: FrameEdit) throws {
        var bytes = [UInt8](try fixture("odd-420.jpg"))
        let frame = try #require(Self.offset(of: JPEGMarker.baseline, in: bytes)) + 4
        edit.apply(to: &bytes, frame: frame)
        let reason = refusal(Data(bytes))
        #expect(reason?.contains(edit.expected) == true, "\(edit): \(String(describing: reason))")
    }

    enum FrameEdit: CaseIterable, CustomStringConvertible {
        case twelveBit, zeroWidth, zeroHeight, tooManyPixels, zeroSampling, wideSampling, cmyk, quantisationTable

        var description: String { "\(self.expected)" }

        /// `frame` is the offset of the SOF's first field, P.
        func apply(to bytes: inout [UInt8], frame: Int) {
            switch self {
            case .twelveBit: bytes[frame] = 12
            case .zeroWidth: (bytes[frame + 3], bytes[frame + 4]) = (0, 0)
            case .zeroHeight: (bytes[frame + 1], bytes[frame + 2]) = (0, 0)
            case .tooManyPixels:
                (bytes[frame + 1], bytes[frame + 2], bytes[frame + 3], bytes[frame + 4]) = (0xFF, 0xFF, 0xFF, 0xFF)
            case .zeroSampling: bytes[frame + 7] = 0x01
            case .wideSampling: bytes[frame + 7] = 0x51
            case .cmyk: bytes[frame + 5] = 4
            case .quantisationTable: bytes[frame + 8] = 7
            }
        }

        var expected: String {
            switch self {
            case .twelveBit: "8-bit"
            case .zeroWidth: "no width"
            case .zeroHeight: "DNL"
            case .tooManyPixels: "more pixels"
            case .zeroSampling, .wideSampling: "sampling factors"
            case .cmyk: "CMYK"
            case .quantisationTable: "quantisation table"
            }
        }
    }

    @Test("a decoder's own pixel limit is the one it holds images to")
    func ownLimit() throws {
        let bytes = try fixture("odd-420.jpg")
        let pixels = 37 * 29
        let reason = refusal(bytes, JPEGDecoder(maximumPixelCount: pixels - 1))
        #expect(reason?.contains("more pixels than the decoder allows") == true, "\(String(describing: reason))")
        #expect((try? JPEGDecoder(maximumPixelCount: pixels).decode(bytes))?.width == 37)
    }

    @Test("a scan that uses a Huffman table never defined is refused")
    func missingHuffmanTable() throws {
        var bytes = [UInt8](try fixture("odd-420.jpg"))
        let scan = try #require(Self.offset(of: JPEGMarker.startOfScan, in: bytes)) + 4
        bytes[scan + 2] = 0x33
        #expect(refusal(Data(bytes))?.contains("never defined") == true)
    }

    @Test("a missing restart marker is refused")
    func missingRestart() throws {
        var bytes = [UInt8](try fixture("restart-420.jpg"))
        let restart = try #require((2..<bytes.count - 1).first {
            bytes[$0] == JPEGMarker.prefix && JPEGMarker.restartRange.contains(bytes[$0 + 1])
        })
        bytes[restart + 1] = JPEGMarker.restart0 + 5
        #expect(refusal(Data(bytes))?.contains("restart marker") == true)
    }

    // MARK: - Malformed input never traps

    // Every byte of the markers and tables is cut at and corrupted, the
    // part a malformed header can do most with; of the entropy-coded data,
    // a byte in every `dataStride`, which a whole fixture's worth of
    // decodes in a debug build would take minutes over.

    @Test("every truncation throws", arguments: ["odd-420", "restart-420", "separate-scans-420", "odd-grey"])
    func truncated(name: String) throws {
        let bytes = [UInt8](try fixture("\(name).jpg"))
        for length in Self.offsets(in: bytes) {
            #expect(throws: ImageDecodeError.self, "\(name) cut to \(length) bytes") {
                try JPEGDecoder().decode(Data(bytes[..<length]))
            }
        }
    }

    @Test("a corrupted byte anywhere throws or decodes, never traps",
          arguments: ["odd-420", "restart-420", "coarse-16bit-tables", "separate-scans-420"])
    func corrupted(name: String) throws {
        let bytes = [UInt8](try fixture("\(name).jpg"))
        let headerEnd = Self.headerEnd(of: bytes)
        for offset in Self.offsets(in: bytes) {
            let replacements: [UInt8] = offset < headerEnd
                ? [0x00, 0xFF, bytes[offset] ^ Self.flippedBits] : [bytes[offset] ^ Self.flippedBits]
            for replacement in replacements {
                var corrupted = bytes
                corrupted[offset] = replacement
                _ = try? JPEGDecoder().decode(Data(corrupted))
            }
        }
    }

    static let dataStride = 5
    static let flippedBits: UInt8 = 0x5A

    /// Every offset up to the end of the first scan header, then one in
    /// every `dataStride`.
    static func offsets(in bytes: [UInt8]) -> [Int] {
        let headerEnd = headerEnd(of: bytes)
        return Array(0..<headerEnd) + Array(stride(from: headerEnd, to: bytes.count, by: dataStride))
    }

    /// Where the first scan's entropy-coded data begins.
    static func headerEnd(of bytes: [UInt8]) -> Int {
        guard let scan = offset(of: JPEGMarker.startOfScan, in: bytes), scan + 3 < bytes.count else {
            return bytes.count
        }
        let markerSize = 2
        let length = Int(bytes[scan + 2]) << UInt8.bitWidth | Int(bytes[scan + 3])
        return min(bytes.count, scan + markerSize + length)
    }

    // MARK: - Helpers

    static func difference(_ decoded: [UInt8], _ reference: [UInt8]) -> (mean: Double, maximum: Int) {
        guard decoded.count == reference.count, !decoded.isEmpty else { return (.infinity, .max) }
        var total = 0, largest = 0, channels = 0
        for index in decoded.indices where index % 4 != 3 {
            let gap = abs(Int(decoded[index]) - Int(reference[index]))
            total += gap
            largest = max(largest, gap)
            channels += 1
        }
        return (Double(total) / Double(channels), largest)
    }

    /// The first segment of `marker`'s offset, its 0xFF.
    static func offset(of marker: UInt8, in bytes: [UInt8]) -> Int? {
        (0..<bytes.count - 1).first { bytes[$0] == JPEGMarker.prefix && bytes[$0 + 1] == marker }
    }
}

private func refusal(_ data: Data, _ decoder: JPEGDecoder = JPEGDecoder()) -> String? {
    do {
        _ = try decoder.decode(data)
        return nil
    } catch {
        switch error {
        case .malformedData(let reason): return reason
        case .unsupportedFormat: return "unsupported format"
        }
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("jpeg")
        .appendingPathComponent(name)
    return try Data(contentsOf: url)
}
