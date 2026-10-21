import Foundation
import Testing
import TerminalUI
@testable import TerminalUIIO

// Half-block renderer is the universal floor of the
// render ladder. Maps an ImageBuffer to ▀ characters with 24-bit
// fg/bg colours: top pixel → foreground, bottom pixel →
// background. Each cell carries 2 vertical pixels of source.

@Suite("HalfBlockRenderer — ▀ + 24-bit fg/bg per cell")
struct HalfBlockRendererTests {

    @Test("renderer's supported protocol is .halfBlock")
    func supportedProtocol() {
        let renderer = HalfBlockRenderer()
        #expect(renderer.supportedProtocol == .halfBlock)
    }

    @Test("render produces ▀ glyphs across the rect")
    func renderProducesHalfBlockGlyphs() throws {
        // 2×2 image — 1 cell of output (since half-block packs 2
        // pixels per cell vertically, 2 wide × 2 tall = 2×1 cells).
        let bytes: [UInt8] = [
            255, 0, 0, 255,    // (0,0) red
            255, 0, 0, 255,    // (1,0) red
            0, 0, 255, 255,    // (0,1) blue
            0, 0, 255, 255,    // (1,1) blue
        ]
        let image = try ImageBuffer(rgba: bytes, width: 2, height: 2)

        var buffer = CellBuffer(width: 4, height: 2)
        let renderer = HalfBlockRenderer()
        renderer.render(image, in: Rect(x: 0, y: 0, width: 2, height: 1), into: &buffer)

        // Cell (0, 0) and (1, 0) should both be ▀.
        #expect(buffer[0, 0].character == "▀")
        #expect(buffer[1, 0].character == "▀")
    }

    @Test("top pixel becomes foreground, bottom pixel becomes background")
    func topPixelToFgBottomToBg() throws {
        // 1×2 image: red on top, blue on bottom → 1 cell output.
        let bytes: [UInt8] = [
            255, 0, 0, 255,    // top pixel
            0, 0, 255, 255,    // bottom pixel
        ]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 2)
        var buffer = CellBuffer(width: 1, height: 1)
        HalfBlockRenderer().render(image, in: Rect(x: 0, y: 0, width: 1, height: 1), into: &buffer)

        #expect(buffer[0, 0].character == "▀")
        #expect(buffer[0, 0].style.foreground == .rgb(255, 0, 0))
        #expect(buffer[0, 0].style.background == .rgb(0, 0, 255))
    }

    @Test("renderer downsamples when source is larger than rect")
    func renderDownsamples() throws {
        // 4×4 image rendered into a 2×1 rect. Half-block packs 2
        // pixels per cell vertically, so 2×1 rect = 2 horizontal × 2
        // vertical pixels = 2×2 effective. Source 4×4 averages to
        // 2×2 via downsample.
        var bytes: [UInt8] = []
        for _ in 0..<16 {
            bytes.append(contentsOf: [128, 128, 128, 255])
        }
        let image = try ImageBuffer(rgba: bytes, width: 4, height: 4)

        var buffer = CellBuffer(width: 2, height: 1)
        HalfBlockRenderer().render(image, in: Rect(x: 0, y: 0, width: 2, height: 1), into: &buffer)

        // After downsample to 2×2 + half-block render, all cells
        // should have fg = bg = (128, 128, 128).
        #expect(buffer[0, 0].character == "▀")
        #expect(buffer[0, 0].style.foreground == .rgb(128, 128, 128))
        #expect(buffer[0, 0].style.background == .rgb(128, 128, 128))
    }

    @Test("empty rect produces no writes")
    func emptyRectNoWrites() throws {
        let bytes: [UInt8] = [255, 0, 0, 255]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 1)
        var buffer = CellBuffer(width: 4, height: 4)
        HalfBlockRenderer().render(image, in: Rect(x: 0, y: 0, width: 0, height: 0), into: &buffer)
        // Buffer should be untouched (default-empty cells).
        #expect(buffer[0, 0].character == " ")
    }
}

@Suite("ImageRenderingPipeline — dispatch + render-ladder strategy resolution")
@MainActor
struct ImageRenderingPipelineTests {

    @Test("automatic strategy resolves via runtime capabilities → halfBlock when default env")
    func automaticUsesCapabilitiesHalfBlock() throws {
        let caps = TerminalCapabilities.detect(environment: ["TERM": "xterm-256color"])
        let pipeline = ImageRenderingPipeline(renderers: [HalfBlockRenderer()])

        let bytes: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255,
        ]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 2)
        var buffer = CellBuffer(width: 1, height: 1)
        pipeline.render(
            image,
            in: Rect(x: 0, y: 0, width: 1, height: 1),
            into: &buffer,
            strategy: .automatic,
            capabilities: caps
        )
        #expect(buffer[0, 0].character == "▀")
    }

    @Test("halfBlock strategy forces half-block regardless of capabilities")
    func halfBlockStrategyForces() throws {
        // Capabilities say kitty, but strategy says halfBlock.
        let caps = TerminalCapabilities.detect(environment: ["TERM": "xterm-kitty"])
        let pipeline = ImageRenderingPipeline(renderers: [HalfBlockRenderer()])

        let bytes: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255,
        ]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 2)
        var buffer = CellBuffer(width: 1, height: 1)
        pipeline.render(
            image,
            in: Rect(x: 0, y: 0, width: 1, height: 1),
            into: &buffer,
            strategy: .halfBlock,
            capabilities: caps
        )
        #expect(buffer[0, 0].character == "▀")
    }

    @Test("kittyOnly strategy falls to placeholder when kitty not available")
    func kittyOnlyFallsToPlaceholder() throws {
        let caps = TerminalCapabilities.detect(environment: ["TERM": "xterm-256color"])
        let pipeline = ImageRenderingPipeline(renderers: [HalfBlockRenderer()])

        let bytes: [UInt8] = [255, 0, 0, 255]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 1)
        var buffer = CellBuffer(width: 8, height: 1)
        pipeline.render(
            image,
            in: Rect(x: 0, y: 0, width: 8, height: 1),
            into: &buffer,
            strategy: .kittyOnly,
            capabilities: caps
        )
        // Placeholder writes "[image]" or similar text-rendered fallback.
        // The exact text doesn't matter; absence-of-▀ does.
        #expect(buffer[0, 0].character != "▀",
                "kittyOnly without kitty support should NOT render half-block")
    }

    @Test("placeholder strategy renders the placeholder text")
    func placeholderRenders() throws {
        let caps = TerminalCapabilities.detect(environment: ["TERM": "xterm-256color"])
        let pipeline = ImageRenderingPipeline(renderers: [HalfBlockRenderer()])

        let bytes: [UInt8] = [255, 0, 0, 255]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 1)
        var buffer = CellBuffer(width: 16, height: 1)
        pipeline.render(
            image,
            in: Rect(x: 0, y: 0, width: 16, height: 1),
            into: &buffer,
            strategy: .placeholder("alice"),
            capabilities: caps
        )
        // First cell should hold a printable character (some part
        // of the placeholder text).
        #expect(buffer[0, 0].character != " " || buffer[1, 0].character != " ",
                "placeholder strategy should write some text")
    }

    @Test("missing renderer for resolved protocol falls to placeholder")
    func missingRendererFallsToPlaceholder() throws {
        let caps = TerminalCapabilities.detect(environment: ["TERM": "xterm-kitty"])
        // Pipeline has only halfBlock; kitty is requested via capabilities.
        let pipeline = ImageRenderingPipeline(renderers: [HalfBlockRenderer()])

        let bytes: [UInt8] = [255, 0, 0, 255]
        let image = try ImageBuffer(rgba: bytes, width: 1, height: 1)
        var buffer = CellBuffer(width: 16, height: 1)
        pipeline.render(
            image,
            in: Rect(x: 0, y: 0, width: 16, height: 1),
            into: &buffer,
            strategy: .automatic,
            capabilities: caps
        )
        // No registered kitty renderer → graceful fall-through to halfBlock.
        // ladder: kitty → halfBlock when only halfBlock is registered.
        #expect(buffer[0, 0].character == "▀")
    }
}
