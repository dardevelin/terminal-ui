import Foundation
import Testing
@testable import TerminalUI

// Behaviour of the three bounded-value controls. The shared model is pinned in
// BoundedValueTests; this file covers what each control does with input.
//
// Apple HIG, Sliders: "a slider lets people choose a value from a range" and
// the current value must be visible without interacting. Gauge is deliberately
// distinct from the shipped ProgressBar — ProgressBar means "task completing",
// Gauge means "value within a range" — so Gauge takes no binding and is not
// focusable.

@MainActor
private final class Value {
    var double: Double
    var int: Int
    init(_ double: Double = 0.5, int: Int = 5) {
        self.double = double
        self.int = int
    }
    var doubleBinding: Binding<Double> {
        Binding(get: { self.double }, set: { self.double = $0 })
    }
    var intBinding: Binding<Int> {
        Binding(get: { self.int }, set: { self.int = $0 })
    }
}

@discardableResult
@MainActor
private func render(_ graph: AttributeGraph, width: Int = 40, height: Int = 8) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    guard let root = graph.root else { return buffer }
    GraphRenderer.render(
        root,
        into: &buffer,
        context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    )
    return buffer
}

private func renderedText(_ buffer: CellBuffer) -> String {
    var out = ""
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            out.append(buffer[x, y].character)
        }
        out.append("\n")
    }
    return out
}

@MainActor
private func buildWithEngine(
    _ engine: FocusEngine,
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    width: Int = 40,
    height: Int = 8
) {
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        render(graph, width: width, height: height)
        engine.rebuildIndex(root: graph.root!)
    }
}

// MARK: - Slider

@Suite("Slider")
@MainActor
struct SliderTests {

    @Test("the current value is visible without interacting")
    func rendersValue() {
        let value = Value(0.25)
        let graph = AttributeGraph()
        graph.update(from: Slider(value: value.doubleBinding))
        #expect(renderedText(render(graph)).contains("0.25"))
    }

    @Test("the thumb sits proportionally along the track")
    func thumbIsProportional() {
        let low = Value(0.0)
        let high = Value(1.0)
        let lowGraph = AttributeGraph()
        let highGraph = AttributeGraph()
        lowGraph.update(from: Slider(value: low.doubleBinding))
        highGraph.update(from: Slider(value: high.doubleBinding))

        let lowRow = renderedText(render(lowGraph)).split(separator: "\n")[0]
        let highRow = renderedText(render(highGraph)).split(separator: "\n")[0]
        let lowThumb = lowRow.firstIndex(of: Character(SliderGlyph.thumb))
        let highThumb = highRow.firstIndex(of: Character(SliderGlyph.thumb))

        #expect(lowThumb != nil && highThumb != nil)
        if let lowThumb, let highThumb {
            #expect(lowRow.distance(from: lowRow.startIndex, to: lowThumb)
                    < highRow.distance(from: highRow.startIndex, to: highThumb))
        }
    }

    @Test("Left and Right adjust by the step")
    func arrowsAdjustByStep() {
        let value = Value(0.5)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Slider(value: value.doubleBinding, step: 0.1))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(abs(value.double - 0.6) < 0.0001)
        _ = engine.routeKeyEvent(KeyEvent(key: .left), root: graph.root!)
        #expect(abs(value.double - 0.5) < 0.0001)
    }

    @Test("a nil step moves one percent of the range")
    func nilStepMovesOnePercent() {
        let value = Value(50.0)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Slider(value: value.doubleBinding, in: 0.0...100.0))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(abs(value.double - 51.0) < 0.0001)
    }

    @Test("Home and End jump to the bounds")
    func homeEndJumpToBounds() {
        let value = Value(5.0)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Slider(value: value.doubleBinding, in: 0.0...10.0))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .end), root: graph.root!)
        #expect(value.double == 10.0)
        _ = engine.routeKeyEvent(KeyEvent(key: .home), root: graph.root!)
        #expect(value.double == 0.0)
    }

    @Test("adjustment stops at the bounds rather than running past them")
    func clampsAtBounds() {
        let value = Value(9.9)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Slider(value: value.doubleBinding, in: 0.0...10.0, step: 1.0))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.double == 10.0)
    }

    @Test("a value starting outside the bounds is corrected, not rejected")
    func correctsOutOfRangeStart() {
        let value = Value(99.0)
        let graph = AttributeGraph()
        graph.update(from: Slider(value: value.doubleBinding, in: 0.0...10.0))
        // Rendering must show the nearest legal value rather than blank or NaN.
        #expect(renderedText(render(graph)).contains("10"))
    }
}

// MARK: - Stepper

@Suite("Stepper")
@MainActor
struct StepperTests {

    @Test("renders its label and current value")
    func rendersLabelAndValue() {
        let value = Value(int: 12)
        let graph = AttributeGraph()
        graph.update(from: Stepper("Tab width", value: value.intBinding, in: 1...16))

        let text = renderedText(render(graph))
        #expect(text.contains("Tab width"))
        #expect(text.contains("12"))
    }

    @Test("Right increments and Left decrements")
    func incrementsAndDecrements() {
        let value = Value(int: 5)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Stepper("n", value: value.intBinding, in: 0...10))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.int == 6)
        _ = engine.routeKeyEvent(KeyEvent(key: .left), root: graph.root!)
        #expect(value.int == 5)
    }

    // `-`/`+` are the keys a user reaches for on a numeric control, and they
    // work without the arrow keys the terminal may be remapping.
    @Test("plus and minus adjust as well as the arrows")
    func plusMinusAdjust() {
        let value = Value(int: 5)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Stepper("n", value: value.intBinding, in: 0...10))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .character("+")), root: graph.root!)
        #expect(value.int == 6)
        _ = engine.routeKeyEvent(KeyEvent(key: .character("-")), root: graph.root!)
        #expect(value.int == 5)
    }

    @Test("stops at the bounds")
    func stopsAtBounds() {
        let value = Value(int: 10)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Stepper("n", value: value.intBinding, in: 0...10))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.int == 10)
    }

    @Test("a step larger than the range lands on the bound, not past it")
    func oversizedStepClampsToBound() {
        let value = Value(int: 2)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Stepper("n", value: value.intBinding, in: 0...10, step: 99))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.int == 10)
    }
}

// MARK: - Gauge

@Suite("Gauge")
@MainActor
struct GaugeTests {

    @Test("renders a proportional fill and its value")
    func rendersProportionalFill() {
        let graph = AttributeGraph()
        graph.update(from: Gauge(value: 0.5, label: "Disk"))
        let text = renderedText(render(graph))
        #expect(text.contains("Disk"))
        #expect(text.contains("0.5"))
    }

    // Gauge is read-only: it reports a value the app owns. Making it focusable
    // would put a stop in the Tab order that does nothing when reached.
    @Test("is not focusable")
    func isNotFocusable() {
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, VStack {
            Gauge(value: 0.5, label: "Disk")
            Button("After") {}
        })

        engine.focusNext()
        let focused = engine.keyboardFocusID
        engine.focusNext()
        // Only one focusable exists, so focus cannot move off the Button.
        #expect(engine.keyboardFocusID == focused)
    }
}

// MARK: - Degenerate ranges, shared across the trio

@Suite("Bounded value — degenerate ranges")
@MainActor
struct BoundedValueDegenerateTests {

    @Test("inverted bounds warn and disable rather than crashing")
    func invertedBoundsWarnAndDisable() {
        let value = Value(5.0)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        // Bounds are passed as separate values: a ClosedRange would trap on
        // construction, so the mistake could never reach the component.
        buildWithEngine(engine, graph,
                        Slider(value: value.doubleBinding, from: 10.0, through: 0.0))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.double == 5.0)  // inert
    }

    @Test("a zero-width range renders full and cannot be moved")
    func zeroWidthRangeIsFullAndInert() {
        let value = Value(5.0)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph,
                        Slider(value: value.doubleBinding, in: 5.0...5.0))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(value.double == 5.0)
    }

    @Test("all three format the same number identically")
    func sharedNumericFormatting() {
        let value = Value(0.5)
        let sliderGraph = AttributeGraph()
        let gaugeGraph = AttributeGraph()
        sliderGraph.update(from: Slider(value: value.doubleBinding))
        gaugeGraph.update(from: Gauge(value: 0.5))

        #expect(renderedText(render(sliderGraph)).contains("0.5"))
        #expect(renderedText(render(gaugeGraph)).contains("0.5"))
    }
}

// The ◂ and ▸ are drawn to be pressed. A `Slider` has taken clicks on its
// track since it shipped; a `Stepper` drew the same kind of affordance and
// ignored them, which reads as a broken control rather than as a keyboard-only
// one — there is nothing on screen that says "arrows only".

@Suite("Stepper — clicking the affordances")
@MainActor
struct StepperClickTests {

    @Test("clicking ▸ increments and ◂ decrements")
    func clickingAffordancesAdjustsValue() {
        let model = StepperClickModel()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = Stepper("Tab width", value: model.binding, in: 1...16)

        var buffer = CellBuffer(width: 40, height: 4)
        let rect = Rect(x: 0, y: 0, width: 40, height: 4)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)

        let row = (0..<buffer.width).map { String(buffer[$0, 0].character) }.joined()
        guard let decrement = row.firstIndex(of: Character(SliderGlyph.decrement)),
              let increment = row.firstIndex(of: Character(SliderGlyph.increment)) else {
            Issue.record("stepper did not render its affordances: \(row)")
            return
        }

        engine.handleMouseClick(x: row.distance(from: row.startIndex, to: increment), y: 0,
                                root: graph.root!)
        #expect(model.value == 5, "clicking ▸ steps up")

        engine.handleMouseClick(x: row.distance(from: row.startIndex, to: decrement), y: 0,
                                root: graph.root!)
        #expect(model.value == 4, "clicking ◂ steps back down")
    }

    // A click on the label is not a click on an affordance; treating the whole
    // row as "increment" would fire on every stray press.
    @Test("clicking the label leaves the value alone")
    func clickingLabelDoesNothing() {
        let model = StepperClickModel()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = Stepper("Tab width", value: model.binding, in: 1...16)

        var buffer = CellBuffer(width: 40, height: 4)
        let rect = Rect(x: 0, y: 0, width: 40, height: 4)
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        engine.rebuildIndex(root: graph.root!)

        engine.handleMouseClick(x: 2, y: 0, root: graph.root!)
        #expect(model.value == 4)
    }
}

@MainActor
private final class StepperClickModel {
    var value = 4
    var binding: Binding<Int> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

// A slider's click lands on its track; the label before it and the value
// after it are not part of it. A click on the label set the minimum and one
// on the value text the maximum, clamped from offsets that were never on the
// track.
@Suite("Slider clicks off the track")
@MainActor
struct SliderClickTests {

    private func clicked(_ label: String, atColumnOf needle: String) -> Double {
        let model = Value(50)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Slider(value: model.doubleBinding, in: 0...100, label: label))
        let buffer = render(graph)
        // The cell the needle starts in: a wide label takes two cells a
        // character, so its column in characters would be short.
        let cells = (0..<buffer.width).first { buffer[$0, 0].character == needle.first! }!
        engine.handleMouseClick(x: cells, y: 0, root: graph.root!)
        return model.double
    }

    @Test func aClickOnTheLabelLeavesTheValue() {
        #expect(clicked("Volume", atColumnOf: "Volume") == 50)
    }

    @Test func aClickOnTheValueTextLeavesTheValue() {
        #expect(clicked("Volume", atColumnOf: "50") == 50)
    }

    @Test func aWideLabelPutsTheTrackWhereItIsDrawn() {
        // The track's first cell, after a label of two-cell characters.
        #expect(clicked("音量", atColumnOf: "─") == 0)
    }
}
