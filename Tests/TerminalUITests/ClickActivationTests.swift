import Testing
@testable import TerminalUI

// Click on a focused text-input component must NOT insert a newline.
// The pre-fix path synthesized `.enter` for any focusable without an
// `.onClick` — designed for Button (Enter activates) but catastrophic
// for TextArea/TextInput/PromptInput (Enter inserts a newline /
// submits / etc.).
//
// Fix: synthesize `.activate` (new Key case) instead of `.enter`.
// Button accepts both `.enter` and `.activate`; text-input components
// ignore `.activate` because it isn't a character event.

@Suite("Click activation does not insert text-input characters")
@MainActor
struct ClickActivationTests {

    @Test("click on focused TextArea does NOT insert a newline")
    func clickOnTextAreaPreservesContent() {
        var value = "hello"
        var st = TextAreaState()
        let textBinding = Binding<String>(get: { value }, set: { value = $0 })
        let stateBinding = Binding<TextAreaState>(get: { st }, set: { st = $0 })
        let view = TextArea(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()  // focus the TextArea

        // Render once so node rects are populated; then click.
        var buffer = CellBuffer(width: 30, height: 5)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 30, height: 5))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        let before = value
        // Drive the click path through the engine. handleMouseClick
        // resolves a focusable under (0, 0) — the TextArea's rect
        // covers it post-render.
        engine.handleMouseClick(x: 1, y: 0, root: graph.root!)
        #expect(value == before,
                "click on TextArea must not mutate text; before=\(before.debugDescription) after=\(value.debugDescription)")
    }

    @Test("click on focused Button still fires its action")
    func clickOnButtonStillFires() {
        // Box for @Sendable mutation under strict concurrency.
        final class Box: @unchecked Sendable { var fired = 0 }
        let box = Box()
        let view = Button("OK") { box.fired += 1 }
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()

        var buffer = CellBuffer(width: 30, height: 1)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 30, height: 1))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        engine.handleMouseClick(x: 2, y: 0, root: graph.root!)
        #expect(box.fired == 1,
                "click on Button must fire its action exactly once; got \(box.fired)")
    }
}
