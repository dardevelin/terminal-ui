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

@Suite("TextInput validation — measurement must include the message row")
@MainActor
struct TextInputValidationMeasureTests {

    @Test("validator error produces measured height of 2")
    func errorHeightIsTwo() {
        resetGraphContext()
        var value = "hello"
        let binding = Binding(get: { value }, set: { value = $0 })
        let graph = AttributeGraph()
        graph.update(from: TextInput(
            text: binding,
            validate: { v in v.contains("@") ? .ok : TextInputValidation(.error, "missing @") }
        ))
        // Height should include the input row (1) + the error row (1).
        let h = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 40)
        #expect(h == 2, "expected 2 rows when validation is in .error state, got \(h)")
    }

    @Test("validator ok produces measured height of 1")
    func okHeightIsOne() {
        resetGraphContext()
        var value = "hi@example.com"
        let binding = Binding(get: { value }, set: { value = $0 })
        let graph = AttributeGraph()
        graph.update(from: TextInput(
            text: binding,
            validate: { v in v.contains("@") ? .ok : TextInputValidation(.error, "missing @") }
        ))
        let h = GraphMeasurer.measureHeight(graph.root!, proposedWidth: 40)
        #expect(h == 1, "expected 1 row when validation is .ok (no message), got \(h)")
    }
}
