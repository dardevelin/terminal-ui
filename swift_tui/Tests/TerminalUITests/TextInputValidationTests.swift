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

// HYP-82 #3 — validating TextInput surfaces severity + message to the user.
// These tests cover the value-level contract: running `validate` against the
// current text produces the expected outcome. Visual contract (error border
// colour) is an integration concern verified in the live Storybook.

@Suite("TextInputValidation — severity + message contract")
@MainActor
struct TextInputValidationTests {

    @Test("TextInputValidation.ok is convenience for .ok severity, no message")
    func okShorthand() {
        let v = TextInputValidation.ok
        #expect(v.severity == .ok)
        #expect(v.message == nil)
    }

    @Test("custom validator returns .error with message")
    func errorWithMessage() {
        let validator: (String) -> TextInputValidation = { value in
            value.contains("@")
                ? .ok
                : TextInputValidation(.error, "missing @")
        }
        #expect(validator("hello").severity == .error)
        #expect(validator("hello").message == "missing @")
        #expect(validator("hi@example.com").severity == .ok)
        #expect(validator("hi@example.com").message == nil)
    }

    @Test("TextInput with validator renders without crashing")
    func renderWithValidator() {
        resetGraphContext()
        var text = "bad"
        let binding = Binding(get: { text }, set: { text = $0 })
        let graph = AttributeGraph()
        graph.update(from: TextInput(
            text: binding,
            validate: { $0.contains("@") ? .ok : TextInputValidation(.error, "missing @") }
        ))
        var buffer = CellBuffer(width: 40, height: 4)
        let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 4))
        GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
        // Error message should appear somewhere after the input row.
        var found = false
        for y in 0..<4 {
            var line = ""
            for x in 0..<40 { line.append(buffer[x, y].character) }
            if line.contains("missing @") { found = true; break }
        }
        #expect(found, "validation message should render below the input")
    }
}
