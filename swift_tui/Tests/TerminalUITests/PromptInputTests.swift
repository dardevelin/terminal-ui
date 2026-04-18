import Testing
@testable import TerminalUI

@MainActor
private func resetGraphContext() {
    GraphContext.currentNode = nil
    GraphContext.currentGraph = nil
    GraphContext.currentEnvironment = nil
    GraphContext.currentFocusEngine = nil
    GraphContext.currentProposedSize = nil
}

// Harness reported a `Range requires lowerBound <= upperBound` crash when the
// Storybook walk landed on the PromptInput page with default state. These
// tests try to reproduce it in isolation so we can fix without the
// full-app spin-up.

@Suite("PromptInput — renders with default state without crashing")
@MainActor
struct PromptInputTests {

    @Test("default state + empty text renders into a standard preview rect")
    func defaultRenderDoesNotCrash() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // Prompt glyph is "❯" by default — confirming it at least landed in
        // the buffer proves we crossed the crash point.
        var seen = false
        for col in 0..<40 where buffer[col, 0].character == "\u{276F}" {
            seen = true
            break
        }
        #expect(seen, "expected the default prompt glyph to render")
    }

    @Test("default state inside a narrow rect with visibleLines > 1")
    func narrowRectDoesNotCrash() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        // This mirrors the Storybook preview pane geometry (~40 wide × 6 high
        // with no explicit maxVisibleLines).
        let view = PromptInput(text: textBinding, state: stateBinding)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 6)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 6))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("default state with explicit maxVisibleLines=3")
    func explicitMaxLines() {
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = PromptInput(text: textBinding, state: stateBinding, maxVisibleLines: 3)
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 8)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 8))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("renders inside PageDetail-style wrapping (VStack .padding .border)")
    func storybookStyleLayout() {
        // Matches Storybook's `PreviewPane ... .padding().border()` envelope.
        // Reproduces the nested GeometryReader + border-shrunk rect that
        // was hitting the Range crash on first render.
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })
        let view = VStack {
            PromptInput(text: textBinding, state: stateBinding,
                        onSubmit: { _ in })
            Text("last submitted: (nothing yet)").foreground(.gray)
        }
        .padding()
        .border()
        let graph = AttributeGraph()
        graph.update(from: view)
        var buffer = CellBuffer(width: 40, height: 10)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 10))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }

    @Test("graph reconciliation — switch TO PromptInput from another view")
    func reconciliationToPromptInput() {
        // Storybook's PreviewPane is a switch statement. Moving to the
        // PromptInput page triggers graph reconciliation where the old
        // subtree is replaced by PromptInput. Reproduce that here by
        // building a ConditionalView and flipping the branch.
        resetGraphContext()
        var value = ""
        var state = PromptInputState()
        let textBinding = Binding(get: { value }, set: { value = $0 })
        let stateBinding = Binding(get: { state }, set: { state = $0 })

        // A wrapper whose body flips between Text and PromptInput based on
        // a captured flag. First update renders Text, second renders
        // PromptInput — mirrors page navigation.
        final class Flipper { var onPrompt = false }
        let flip = Flipper()
        struct Container: TerminalView {
            let flip: Flipper
            let textBinding: Binding<String>
            let stateBinding: Binding<PromptInputState>
            var body: some TerminalView {
                if flip.onPrompt {
                    PromptInput(text: textBinding, state: stateBinding)
                } else {
                    Text("placeholder")
                }
            }
        }

        let graph = AttributeGraph()
        graph.update(from: Container(flip: flip, textBinding: textBinding, stateBinding: stateBinding))
        var buffer = CellBuffer(width: 40, height: 6)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 6))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)

        // Now flip and re-update — this is the transition that crashes live.
        flip.onPrompt = true
        graph.update(from: Container(flip: flip, textBinding: textBinding, stateBinding: stateBinding))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    }
}
