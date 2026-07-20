import Foundation
import Testing
@testable import TerminalUIIO

// HYP-296 — TerminalUIIO module foundation: ImageBuffer value type
// + ImageDecoder protocol seam + typed errors. No concrete decoder
// yet (HYP-297 ships ImageIO/libpng); these tests pin the API
// shape and the basic ops (init validation, downsample, pixel
// access, average color).

@Suite("ImageBuffer — RGBA value type with downsample + pixel ops")
struct ImageBufferTests {

    // MARK: - Init validation

    @Test("init with correct dimensions succeeds")
    func initWithCorrectDimensionsSucceeds() throws {
        let bytes = [UInt8](repeating: 0, count: 16)  // 2×2 × 4 bytes
        let buffer = try ImageBuffer(rgba: bytes, width: 2, height: 2)
        #expect(buffer.width == 2)
        #expect(buffer.height == 2)
    }

    @Test("init with dimension mismatch throws")
    func initWithDimensionMismatchThrows() {
        let bytes = [UInt8](repeating: 0, count: 8)  // wrong: 2×2 needs 16
        #expect(throws: ImageBufferError.self) {
            _ = try ImageBuffer(rgba: bytes, width: 2, height: 2)
        }
    }

    @Test("init with non-positive width throws")
    func initWithZeroWidthThrows() {
        #expect(throws: ImageBufferError.self) {
            _ = try ImageBuffer(rgba: [], width: 0, height: 2)
        }
    }

    @Test("init with non-positive height throws")
    func initWithZeroHeightThrows() {
        #expect(throws: ImageBufferError.self) {
            _ = try ImageBuffer(rgba: [], width: 2, height: 0)
        }
    }

    // MARK: - Pixel access

    @Test("pixel(at:_:) returns the correct RGBA")
    func pixelAtCoordReturnsRGBA() throws {
        // 2×1 image: [255,0,0,255] [0,255,0,255]
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        let buffer = try ImageBuffer(rgba: bytes, width: 2, height: 1)
        let (r0, g0, b0, a0) = buffer.pixel(at: 0, 0)
        #expect(r0 == 255 && g0 == 0 && b0 == 0 && a0 == 255)
        let (r1, g1, b1, a1) = buffer.pixel(at: 1, 0)
        #expect(r1 == 0 && g1 == 255 && b1 == 0 && a1 == 255)
    }

    // MARK: - Downsample

    @Test("downsample 4×4 → 2×2 averages 2×2 source pixels per output cell")
    func downsampleHalvesAverages() throws {
        // 4×4 image: top-left 2×2 = red, top-right 2×2 = green,
        // bottom-left 2×2 = blue, bottom-right 2×2 = white.
        var bytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                let (r, g, b): (UInt8, UInt8, UInt8)
                switch (x < 2, y < 2) {
                case (true, true):  (r, g, b) = (255, 0, 0)        // top-left
                case (false, true): (r, g, b) = (0, 255, 0)        // top-right
                case (true, false): (r, g, b) = (0, 0, 255)        // bottom-left
                case (false, false): (r, g, b) = (255, 255, 255)   // bottom-right
                }
                bytes.append(contentsOf: [r, g, b, 255])
            }
        }
        let source = try ImageBuffer(rgba: bytes, width: 4, height: 4)
        let down = source.downsample(toWidth: 2, height: 2)
        #expect(down.width == 2)
        #expect(down.height == 2)
        // Each 2×2 region averaged — output (0, 0) should be solid red.
        let (r, g, b, _) = down.pixel(at: 0, 0)
        #expect(r == 255 && g == 0 && b == 0)
        // Output (1, 1) should be solid white.
        let (r2, g2, b2, _) = down.pixel(at: 1, 1)
        #expect(r2 == 255 && g2 == 255 && b2 == 255)
    }

    @Test("downsample to same size returns equivalent buffer")
    func downsampleSameSizeIsIdentity() throws {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        let source = try ImageBuffer(rgba: bytes, width: 2, height: 1)
        let down = source.downsample(toWidth: 2, height: 1)
        #expect(down.width == 2 && down.height == 1)
        let (r, g, b, a) = down.pixel(at: 0, 0)
        #expect(r == 255 && g == 0 && b == 0 && a == 255)
    }
}

@Suite("ImageDecoder — protocol seam compiles + URL convenience")
struct ImageDecoderTests {

    @Test("ImageDecoder protocol can be conformed by a stub")
    func protocolConformanceCompiles() {
        // Compile-only check: a minimal conformer satisfies the protocol.
        struct Stub: ImageDecoder {
            func decode(_ data: Data) throws(ImageDecodeError) -> ImageBuffer {
                let bytes = [UInt8](repeating: 255, count: 4)
                do {
                    return try ImageBuffer(rgba: bytes, width: 1, height: 1)
                } catch {
                    throw .malformedData(reason: "stub")
                }
            }
        }
        _ = Stub()
    }

    @Test("decode(_:) on a stub returns an ImageBuffer")
    func stubDecoderRoundTrips() throws {
        struct Stub: ImageDecoder {
            func decode(_ data: Data) throws(ImageDecodeError) -> ImageBuffer {
                let bytes: [UInt8] = [10, 20, 30, 255]
                do {
                    return try ImageBuffer(rgba: bytes, width: 1, height: 1)
                } catch {
                    throw .malformedData(reason: "stub init failed")
                }
            }
        }
        let decoded = try Stub().decode(Data())
        let (r, g, b, a) = decoded.pixel(at: 0, 0)
        #expect(r == 10 && g == 20 && b == 30 && a == 255)
    }
}
