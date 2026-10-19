import Testing
@testable import TerminalUI

// An agent composer reads as a control only when it says where keys go: a
// cursor while focused and none otherwise, a placeholder while empty, and a
// prefix column that changes with focus (Crush's `>` / `:::`). PromptInput
// drew its cursor whether or not it held focus — nothing could tell it — and
// its colours were literals no theme reached.

@MainActor
private final class Harness {
    var text: String
    var state = PromptInputState()
    let graph = AttributeGraph()
    private(set) var focus: NodeID?

    init(text: String = "") { self.text = text }

    var textBinding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    var stateBinding: Binding<PromptInputState> { Binding(get: { self.state }, set: { self.state = $0 }) }

    func mount(_ view: some TerminalView) {
        GraphContext.$currentEnvironment.withValue(environment) { _ = graph.update(from: view) }
    }

    func setFocused(_ focused: Bool) {
        focus = focused ? focusableID(in: graph.root!) : nil
        graph.focusMoved(to: focus)
        GraphContext.$currentEnvironment.withValue(environment) { _ = graph.drain() }
    }

    func render(width: Int, height: Int) -> CellBuffer {
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        GraphContext.$currentEnvironment.withValue(environment) {
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        return buffer
    }

    func rows(width: Int, height: Int) -> [String] {
        let buffer = render(width: width, height: height)
        return (0..<height).map { y in
            var line = String((0..<width).map { buffer[$0, y].character })
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    private var environment: EnvironmentValues {
        var env = EnvironmentValues()
        env.focusedID = focus
        return env
    }

    private func focusableID(in node: AttributeNode) -> NodeID? {
        if node.isFocusable { return node.id }
        for child in node.children {
            if let id = focusableID(in: child) { return id }
        }
        return nil
    }
}

/// Crush's composer column: `  > ` on the first row while focused, `::: `
/// on every other row and on all of them when focus is elsewhere.
private let crushColumn = PromptPrefix(width: 4) { row in
    switch (row.index, row.isFocused) {
    case (0, true): [TextSpan("  > ", foreground: row.theme.success, bold: true)]
    case (_, true): [TextSpan("::: ", foreground: row.theme.successSubtle)]
    default: [TextSpan("::: ", foreground: row.theme.foregroundMuted)]
    }
}

private struct Marked: Theme {
    var accent: Color = .magenta
    var foregroundFaint: Color = .rgb(90, 90, 90)
}

@Suite("PromptInput draws for focus, placeholder and its prefix")
@MainActor
struct PromptInputFocusTests {

    @Test func theCursorIsDrawnOnlyWhileFocused() {
        let harness = Harness(text: "hi")
        harness.state.cursorCol = 2
        harness.mount(PromptInput(text: harness.textBinding, state: harness.stateBinding))
        harness.setFocused(false)
        #expect(harness.rows(width: 10, height: 1) == ["❯ hi"])
        harness.setFocused(true)
        #expect(harness.rows(width: 10, height: 1) == ["❯ hi█"])
    }

    @Test func anEmptyPromptShowsItsPlaceholder() {
        let harness = Harness()
        harness.mount(PromptInput(text: harness.textBinding, state: harness.stateBinding,
                                  placeholder: "Ask anything")
            .environment(\.theme, Marked()))
        harness.setFocused(false)
        let unfocused = harness.render(width: 20, height: 1)
        #expect(harness.rows(width: 20, height: 1) == ["❯ Ask anything"])
        #expect(unfocused[2, 0].style.foreground == .rgb(90, 90, 90), "the placeholder is faint")

        harness.setFocused(true)
        let focused = harness.render(width: 20, height: 1)
        #expect(harness.rows(width: 20, height: 1) == ["❯ Ask anything"],
                "the cursor sits on the first character instead of pushing the text right")
        #expect(focused[2, 0].style.background == .magenta, "the cursor is on the A")
    }

    @Test func aReservedPromptDrawsItsPrefixOnEveryRow() {
        let harness = Harness(text: "fix it")
        harness.mount(PromptInput(text: harness.textBinding, state: harness.stateBinding,
                                  minimumHeight: 3)
            .promptPrefix(crushColumn))
        harness.setFocused(true)
        #expect(harness.rows(width: 20, height: 3) == ["  > fix it", ":::", ":::"])
        harness.setFocused(false)
        #expect(harness.rows(width: 20, height: 3) == ["::: fix it", ":::", ":::"])
    }

    @Test func thePrefixWidthIsTakenFromTheWrapWidth() {
        let harness = Harness(text: "aaaa bbbb")
        harness.mount(PromptInput(text: harness.textBinding, state: harness.stateBinding)
            .promptPrefix(crushColumn))
        harness.setFocused(false)
        #expect(harness.rows(width: 9, height: 2) == ["::: aaaa", "::: bbbb"])
    }

    @Test func thePromptGlyphTakesTheThemeAccent() {
        let harness = Harness()
        harness.mount(PromptInput(text: harness.textBinding, state: harness.stateBinding)
            .environment(\.theme, Marked()))
        harness.setFocused(false)
        #expect(harness.render(width: 10, height: 1)[0, 0].style.foreground == .magenta)
    }
}
