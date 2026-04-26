import Testing
@testable import TerminalUI

// BufferView blits an externally-populated CellBuffer into its
// allocated rect. Used for: PTY preview pane, terminal emulator views,
// any pre-rasterized content (syntax-highlighted code, image-to-cell
// converters). SwiftUI analog: Image(decorative: cgImage) — the view
// passes through a fully-formed pixel/cell raster without interaction.
//
// The view's natural size is the buffer's dimensions. Larger-than-rect
// content truncates to the rect; the view does not scroll itself
// (compose with ScrollView for that).

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

/// Build a 3x2 source buffer with distinct characters at every cell so
/// the assertion can pin position-by-position.
@MainActor
private func makeProbeBuffer(width: Int = 3, height: Int = 2) -> CellBuffer {
    var src = CellBuffer(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            // Use 'A'..'I' so a 3x2 buffer reads "ABC" / "DEF"
            let ch = Character(UnicodeScalar(65 + y * width + x)!)
            src[x, y] = Cell(character: ch, style: .plain)
        }
    }
    return src
}

@MainActor
private func renderBufferView(_ view: BufferView, into rect: Rect, canvasWidth: Int = 10, canvasHeight: Int = 10) -> CellBuffer {
    resetGraphContext()
    let graph = AttributeGraph()
    graph.update(from: view)
    let root = graph.root!
    root.rect = rect
    var canvas = CellBuffer(width: canvasWidth, height: canvasHeight)
    GraphRenderer.render(root, into: &canvas, context: RenderContext(style: .plain, rect: rect))
    return canvas
}

@Suite("BufferView — blit primitive")
@MainActor
struct BufferViewTests {

    @Test("BufferView is a public TerminalView accepting a CellBuffer")
    func bufferViewCompiles() {
        let src = makeProbeBuffer()
        let _: BufferView = BufferView(src)
    }

    @Test("renders source cells at the view's rect origin")
    func rendersAtRectOrigin() {
        let src = makeProbeBuffer()  // 3x2: "ABC" / "DEF"
        let canvas = renderBufferView(BufferView(src), into: Rect(x: 1, y: 1, width: 3, height: 2))
        // Row 1: . A B C . . . . . .
        #expect(canvas[1, 1].character == "A")
        #expect(canvas[2, 1].character == "B")
        #expect(canvas[3, 1].character == "C")
        // Row 2: . D E F
        #expect(canvas[1, 2].character == "D")
        #expect(canvas[2, 2].character == "E")
        #expect(canvas[3, 2].character == "F")
    }

    @Test("clips cells outside the rect's right edge")
    func clipsRectWidth() {
        // 5-wide source, 3-wide rect — cells 4 and 5 must NOT appear.
        var src = CellBuffer(width: 5, height: 1)
        for x in 0..<5 {
            src[x, 0] = Cell(character: Character(UnicodeScalar(65 + x)!), style: .plain)
        }
        let canvas = renderBufferView(BufferView(src), into: Rect(x: 0, y: 0, width: 3, height: 1))
        #expect(canvas[0, 0].character == "A")
        #expect(canvas[1, 0].character == "B")
        #expect(canvas[2, 0].character == "C")
        // Cell at column 3 must NOT have been written by BufferView
        // (the canvas had its initial '.empty' at construction).
        #expect(canvas[3, 0] == .empty)
    }

    @Test("clips cells below the rect's bottom edge")
    func clipsRectHeight() {
        // 1x5 source, rect height 3 — rows 3 and 4 must not appear.
        var src = CellBuffer(width: 1, height: 5)
        for y in 0..<5 {
            src[0, y] = Cell(character: Character(UnicodeScalar(65 + y)!), style: .plain)
        }
        let canvas = renderBufferView(BufferView(src), into: Rect(x: 0, y: 0, width: 1, height: 3))
        #expect(canvas[0, 0].character == "A")
        #expect(canvas[0, 1].character == "B")
        #expect(canvas[0, 2].character == "C")
        #expect(canvas[0, 3] == .empty)
    }

    @Test("paints source .empty cells too — does NOT skip them like ScrollView blit")
    func paintsEmptyCells() {
        // The user controls what's in their buffer. If they put .empty,
        // the framework MUST overwrite parent content with empty (this
        // is how a PTY emulator clears regions). ScrollView's local
        // buffer skips .empty for a different reason (it doesn't want
        // to paint over its parent's bg); that filter does NOT apply
        // here — BufferView is the user's authoritative content.
        var canvas = CellBuffer(width: 5, height: 1)
        // Pre-paint the canvas so we can detect overwrite vs. preserve.
        for x in 0..<5 {
            canvas[x, 0] = Cell(character: "X", style: .plain)
        }

        var src = CellBuffer(width: 3, height: 1)
        src[0, 0] = Cell(character: "A", style: .plain)
        // src[1, 0] is .empty by construction
        src[2, 0] = Cell(character: "C", style: .plain)

        // Render directly — bypass renderBufferView so we keep the
        // pre-painted canvas intact (renderBufferView allocates a
        // fresh canvas inside).
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: BufferView(src))
        let root = graph.root!
        let rect = Rect(x: 0, y: 0, width: 3, height: 1)
        root.rect = rect
        GraphRenderer.render(root, into: &canvas, context: RenderContext(style: .plain, rect: rect))

        #expect(canvas[0, 0].character == "A")
        #expect(canvas[1, 0] == .empty, "source .empty must overwrite parent's 'X'")
        #expect(canvas[2, 0].character == "C")
        #expect(canvas[3, 0].character == "X", "outside rect must be untouched")
    }

    @Test("zero-size source buffer renders nothing and does not crash")
    func zeroSizeBufferIsSafe() {
        let src = CellBuffer(width: 0, height: 0)
        let canvas = renderBufferView(BufferView(src), into: Rect(x: 0, y: 0, width: 5, height: 5))
        // Canvas should remain all-empty; no crash above.
        for y in 0..<5 {
            for x in 0..<5 {
                #expect(canvas[x, y] == .empty)
            }
        }
    }

    @Test("source larger than rect truncates to rect")
    func largerSourceTruncates() {
        var src = CellBuffer(width: 100, height: 100)
        // Fill only the corners we'll assert on.
        src[0, 0] = Cell(character: "A", style: .plain)
        src[4, 4] = Cell(character: "B", style: .plain)
        src[5, 5] = Cell(character: "C", style: .plain) // outside 5x5 rect
        let canvas = renderBufferView(BufferView(src), into: Rect(x: 0, y: 0, width: 5, height: 5))
        #expect(canvas[0, 0].character == "A")
        #expect(canvas[4, 4].character == "B")
        // Row/col 5 outside the rect must remain canvas-empty.
        #expect(canvas[5, 5] == .empty)
    }

    @Test("BufferView's natural size is the source buffer's dimensions")
    func measuredAtBufferDimensions() {
        let src = makeProbeBuffer(width: 7, height: 3)
        resetGraphContext()
        let graph = AttributeGraph()
        graph.update(from: BufferView(src))
        let root = graph.root!
        #expect(GraphMeasurer.measureWidth(root) == 7)
        #expect(GraphMeasurer.measureHeight(root, proposedWidth: 100) == 3)
    }
}
