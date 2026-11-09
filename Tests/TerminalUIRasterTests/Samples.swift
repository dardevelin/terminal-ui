import Foundation
import Testing
@testable import TerminalUIRaster

// The inputs every golden is made from. `tools/tests/test_raster_encoders.py`
// rebuilds each of them independently, from the same formulas, to check the
// committed fixtures with Python's zlib and a GIF decoder of its own — so a
// change here is a change there.

/// Knuth's MMIX linear congruential generator, its top byte taken: trivial
/// to restate in Python, and the same sequence on every platform.
struct SampleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextByte() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 56)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in nextByte() }
    }
}

enum Samples {
    static let randomSeed: UInt64 = 2026
    static let textSeed: UInt64 = 1950
    static let noiseSeed: UInt64 = 89

    static let words = ["the", "framework", "records", "its", "own", "pictures", "terminal",
                        "cell", "frame", "glyph", "border", "focus", "render", "a", "of", "to"]

    static func random(_ count: Int) -> [UInt8] {
        var generator = SampleRandom(seed: randomSeed)
        return generator.bytes(count)
    }

    /// Words drawn at random and joined by spaces, a line break every
    /// twelfth word: repetitive the way prose and terminal frames are.
    static func text(wordCount: Int) -> [UInt8] {
        var generator = SampleRandom(seed: textSeed)
        var output: [UInt8] = []
        for index in 0..<wordCount {
            output += Array(words[Int(generator.nextByte()) % words.count].utf8)
            output.append(index % 12 == 11 ? 0x0A : 0x20)
        }
        return output
    }

    static let repetitive = Array("abcabcabcabcabcabcabcabcabcabc".utf8)

    static func rgbCanvas() -> PixelCanvas {
        var canvas = PixelCanvas(width: 5, height: 4)
        for y in 0..<4 {
            for x in 0..<5 {
                canvas[x, y] = RGBA(UInt8(40 * x + 15), UInt8(60 * y + 7), UInt8((x * y * 37) % 256))
            }
        }
        return canvas
    }

    static func rgbaCanvas() -> PixelCanvas {
        var canvas = PixelCanvas(width: 4, height: 3)
        for y in 0..<3 {
            for x in 0..<4 {
                canvas[x, y] = RGBA(UInt8(60 * x), UInt8(100 * y), 200, UInt8(255 - 60 * x - 20 * y))
            }
        }
        return canvas
    }

    static let indexedPalette = [
        RGBA(0x1E, 0x1E, 0x2E), RGBA(0xCB, 0xA6, 0xF7), RGBA(0xA6, 0xE3, 0xA1, 0x80),
        RGBA(0xF3, 0x8B, 0xA8), RGBA(0x89, 0xB4, 0xFA),
    ]

    static func indexedImage() -> IndexedImage {
        let indices: [UInt8] = (0..<30).map { offset in
            let x = offset % 6
            let y = offset / 6
            return UInt8((x + 2 * y) % 5)
        }
        return IndexedImage(width: 6, height: 5, indices: indices, palette: indexedPalette)
    }

    /// Two colours, nine pixels a row: one bit a pixel, and a row that ends
    /// partway through its second byte.
    static func twoColourImage() -> IndexedImage {
        let indices: [UInt8] = (0..<27).map { offset in UInt8((offset % 9 + offset / 9) % 2) }
        return IndexedImage(width: 9, height: 3, indices: indices, palette: [RGBA(0, 0, 0), RGBA(255, 255, 255)])
    }

    static let gifGlobalPalette = [RGBA(0, 0, 0), RGBA(255, 255, 255), RGBA(255, 0, 0), RGBA(0, 0, 255)]
    static let gifLocalPalette = [RGBA(0, 255, 0), RGBA(255, 255, 0), RGBA(0, 255, 255)]

    /// An 8×6 screen drawn whole, then a 3×2 rectangle at (2, 1) in its own
    /// colours, its index 1 transparent so the first frame shows through.
    static func twoFrameGIF() -> [UInt8] {
        let diagonals: [UInt8] = (0..<48).map { offset in UInt8((offset % 8 + offset / 8) % 4) }
        var writer = GIFWriter(width: 8, height: 6, globalPalette: gifGlobalPalette, loopCount: 0)
        writer.append(GIFFrame(left: 0, top: 0, width: 8, height: 6, indices: diagonals,
                               delayCentiseconds: 50, disposal: .keep))
        writer.append(GIFFrame(left: 2, top: 1, width: 3, height: 2,
                               indices: [0, 1, 2, 2, 1, 0],
                               localPalette: gifLocalPalette,
                               delayCentiseconds: 125, disposal: .keep, transparentIndex: 1))
        return writer.finish()
    }

    /// 96×64 pixels of 256-colour noise: more codes than one LZW table holds.
    static func noiseGIF() -> [UInt8] {
        var generator = SampleRandom(seed: noiseSeed)
        let palette: [RGBA] = (0..<256).map { (value: Int) -> RGBA in
            RGBA(UInt8(value), UInt8(255 - value), UInt8(value * 7 % 256))
        }
        var writer = GIFWriter(width: 96, height: 64, globalPalette: palette, loopCount: nil)
        writer.append(GIFFrame(left: 0, top: 0, width: 96, height: 64,
                               indices: generator.bytes(96 * 64), delayCentiseconds: 0))
        return writer.finish()
    }
}

// MARK: - Goldens

/// Compares `bytes` with the committed fixture `name`. With
/// `TERMINALUI_UPDATE_GOLDENS=1` it writes the fixture instead, for a change
/// that means to alter the encoding; the Python oracle then says whether the
/// new file still decodes to the same picture.
func expectGolden(_ bytes: [UInt8], named name: String,
                  sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
    if ProcessInfo.processInfo.environment["TERMINALUI_UPDATE_GOLDENS"] == "1" {
        try Data(bytes).write(to: url)
        return
    }
    let golden = try [UInt8](Data(contentsOf: url))
    #expect(bytes == golden, "\(name): \(bytes.count) bytes against a golden of \(golden.count)",
            sourceLocation: sourceLocation)
}

/// The deflate stream inside a zlib stream (RFC 1950 §2.2): two header
/// bytes before it, the Adler-32 after.
func zlibBody(_ stream: [UInt8]) -> Data {
    Data(stream[2..<(stream.count - 4)])
}
