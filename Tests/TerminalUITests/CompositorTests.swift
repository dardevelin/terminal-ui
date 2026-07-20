import Testing
@testable import TerminalUI

@Suite("Layer.computeDirtyRegion")
struct LayerDirtyRegionTests {

    @Test("first frame (nil previous) is full")
    func nilPreviousIsFull() {
        var layer = Layer(width: 10, height: 5)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .full)
    }

    @Test("identical buffers produce .clean")
    func identicalIsClean() {
        var layer = Layer(width: 10, height: 5)
        layer.buffer.write("hi", x: 0, y: 0, style: .plain)
        layer.snapshotBuffer()
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .clean)
    }

    @Test("single-cell change returns 1x1 rect")
    func singleCellChange() {
        var layer = Layer(width: 10, height: 5)
        layer.snapshotBuffer()
        layer.buffer[3, 2] = Cell(character: "x", style: .plain)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .rect(x: 3, y: 2, width: 1, height: 1))
    }

    @Test("horizontal run change")
    func horizontalRun() {
        var layer = Layer(width: 10, height: 5)
        layer.snapshotBuffer()
        layer.buffer.write("hello", x: 2, y: 1, style: .plain)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .rect(x: 2, y: 1, width: 5, height: 1))
    }

    @Test("vertical column change")
    func verticalColumn() {
        var layer = Layer(width: 10, height: 5)
        layer.snapshotBuffer()
        for y in 1...3 {
            layer.buffer[4, y] = Cell(character: "|", style: .plain)
        }
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .rect(x: 4, y: 1, width: 1, height: 3))
    }

    @Test("scattered changes produce bounding rect")
    func scatteredChangesBoundingRect() {
        var layer = Layer(width: 10, height: 10)
        layer.snapshotBuffer()
        layer.buffer[1, 1] = Cell(character: "a", style: .plain)
        layer.buffer[7, 8] = Cell(character: "b", style: .plain)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .rect(x: 1, y: 1, width: 7, height: 8))
    }

    @Test("size mismatch between current and previous returns .full")
    func sizeMismatchIsFull() {
        var layer = Layer(width: 10, height: 5)
        layer.previousBuffer = CellBuffer(width: 8, height: 5)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .full)
    }

    @Test("style-only change is dirty")
    func styleOnlyChange() {
        var layer = Layer(width: 5, height: 1)
        layer.buffer.write("a", x: 0, y: 0, style: .plain)
        layer.snapshotBuffer()
        let bold = Style(foreground: nil, background: nil, bold: true, italic: false, underline: false)
        layer.buffer.write("a", x: 0, y: 0, style: bold)
        layer.computeDirtyRegion()
        #expect(layer.dirtyRect == .rect(x: 0, y: 0, width: 1, height: 1))
    }
}

@Suite("Compositor.deltaComposite")
struct CompositorDeltaCompositeTests {

    @Test("no layers produces no dirty region")
    func noLayers() {
        var layers: [Layer] = []
        var output = CellBuffer(width: 10, height: 5)
        let dirty = Compositor.deltaComposite(layers: &layers, into: &output)
        #expect(dirty == nil)
    }

    @Test("first frame reports full-layer bounds as dirty")
    func firstFrameFull() {
        var layers = [Layer(width: 10, height: 5)]
        layers[0].buffer.write("hi", x: 0, y: 0, style: .plain)
        var output = CellBuffer(width: 10, height: 5)
        let dirty = Compositor.deltaComposite(layers: &layers, into: &output)
        #expect(dirty?.x == 0)
        #expect(dirty?.y == 0)
        #expect(dirty?.width == 10)
        #expect(dirty?.height == 5)
    }

    @Test("clean second frame produces nil dirty")
    func cleanSecondFrame() {
        var layers = [Layer(width: 10, height: 5)]
        layers[0].buffer.write("hi", x: 0, y: 0, style: .plain)
        var output = CellBuffer(width: 10, height: 5)
        _ = Compositor.deltaComposite(layers: &layers, into: &output)
        // Frame 2 — buffer unchanged
        let dirty = Compositor.deltaComposite(layers: &layers, into: &output)
        #expect(dirty == nil)
    }

    @Test("partial change only reports changed rect")
    func partialChangeReportsRect() {
        var layers = [Layer(width: 10, height: 5)]
        var output = CellBuffer(width: 10, height: 5)
        _ = Compositor.deltaComposite(layers: &layers, into: &output)
        layers[0].buffer[3, 2] = Cell(character: "x", style: .plain)
        let dirty = Compositor.deltaComposite(layers: &layers, into: &output)
        #expect(dirty?.x == 3)
        #expect(dirty?.y == 2)
        #expect(dirty?.width == 1)
        #expect(dirty?.height == 1)
    }

    @Test("offset layer translates dirty rect to output space")
    func offsetLayerTranslates() {
        var layers = [Layer(width: 5, height: 3, x: 4, y: 2)]
        var output = CellBuffer(width: 20, height: 10)
        _ = Compositor.deltaComposite(layers: &layers, into: &output)
        layers[0].buffer[1, 1] = Cell(character: "x", style: .plain)
        let dirty = Compositor.deltaComposite(layers: &layers, into: &output)
        // Layer-local (1, 1) with layer at (4, 2) → output (5, 3)
        #expect(dirty?.x == 5)
        #expect(dirty?.y == 3)
        #expect(dirty?.width == 1)
        #expect(dirty?.height == 1)
    }

    @Test("composited output contains layer contents")
    func compositedOutputWritten() {
        var layers = [Layer(width: 5, height: 1)]
        layers[0].buffer.write("hello", x: 0, y: 0, style: .plain)
        var output = CellBuffer(width: 10, height: 3)
        _ = Compositor.deltaComposite(layers: &layers, into: &output)
        #expect(output[0, 0].character == "h")
        #expect(output[4, 0].character == "o")
    }
}
