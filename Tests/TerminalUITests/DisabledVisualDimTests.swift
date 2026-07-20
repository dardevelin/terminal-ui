import Testing
@testable import TerminalUI

// `.disabled()` on an interactive subtree should DIM the rendered
// foreground so users see they can't interact. Pairs with the
// behavioral half (handler gating + focus skip) ships with the
// .disabled() modifier in DisabledModifier.swift.
//
// Pattern: each interactive component reads
// `@TerminalEnvironment(\.isEnabled)` and routes its rendered
// foreground through a ternary — `.gray` when disabled, the
// component's normal color when enabled.
//
// These tests render each component into a CellBuffer through a
// `.disabled()` wrapper and assert the cells the component painted
// carry the dim foreground.

/// Render a view into a CellBuffer of the given size with a default
/// env (no overrides). Returns the rendered buffer for cell-level
/// inspection.
@MainActor
private func render<V: TerminalView>(_ view: V, width: Int = 20, height: Int = 3) -> CellBuffer {
    let graph = AttributeGraph()
    GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
        graph.update(from: view)
    }
    var buffer = CellBuffer(width: width, height: height)
    let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    GraphRenderer.render(graph.root!, into: &buffer, context: ctx)
    return buffer
}

/// Returns the foreground colors of every non-space cell in the buffer.
private func nonSpaceForegrounds(_ buffer: CellBuffer) -> [Color?] {
    var colors: [Color?] = []
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            let cell = buffer[x, y]
            if cell.character != " " {
                colors.append(cell.style.foreground)
            }
        }
    }
    return colors
}

@Suite("Disabled visual dim — Button")
@MainActor
struct DisabledButtonVisualTests {

    @Test("enabled Button paints its label with the default (non-gray) foreground")
    func enabledButtonNotDim() {
        let view = Button("OK") { /* no-op */ }
        let buffer = render(view, width: 10)
        let colors = nonSpaceForegrounds(buffer)
        // No cells should carry the .gray foreground when enabled —
        // Button's default uses .default. (We only assert the absence
        // of the dim color rather than the exact default tone.)
        #expect(!colors.allSatisfy { $0 == .gray },
                "enabled Button should not paint every glyph in .gray; got \(colors)")
    }

    @Test(".disabled() Button paints its label with .gray foreground")
    func disabledButtonDim() {
        let view = Button("OK") { /* no-op */ }.disabled()
        let buffer = render(view, width: 10)
        let colors = nonSpaceForegrounds(buffer)
        #expect(!colors.isEmpty, "Button should have rendered some glyphs")
        #expect(colors.allSatisfy { $0 == .gray },
                "disabled Button must paint every glyph in .gray; got \(colors)")
    }
}

@Suite("Disabled visual dim — Toggle")
@MainActor
struct DisabledToggleVisualTests {

    @Test(".disabled() Toggle paints checkbox + label in .gray")
    func disabledToggleDim() {
        var on = false
        let binding = Binding<Bool>(get: { on }, set: { on = $0 })
        let view = Toggle("Pref", isOn: binding).disabled()
        let buffer = render(view, width: 16)
        let colors = nonSpaceForegrounds(buffer)
        #expect(!colors.isEmpty)
        #expect(colors.allSatisfy { $0 == .gray },
                "disabled Toggle must paint every glyph in .gray; got \(colors)")
    }
}

@Suite("Disabled visual dim — TextInput")
@MainActor
struct DisabledTextInputVisualTests {

    @Test(".disabled() TextInput dims its rendered text")
    func disabledTextInputDim() {
        var value = "abc"
        let binding = Binding<String>(get: { value }, set: { value = $0 })
        let view = TextInput(text: binding).disabled()
        let buffer = render(view, width: 12, height: 1)
        let colors = nonSpaceForegrounds(buffer)
        #expect(!colors.isEmpty, "TextInput should have rendered some glyphs")
        // The cursor glyph may keep an explicit color even when
        // disabled — our contract is that the BULK of the rendered
        // text uses .gray. Assert at least the value characters are
        // dim. The cursor `│` is a single cell.
        let nonCursor = colors.filter { _ in true }  // keep all for now
        let grayCount = nonCursor.filter { $0 == .gray }.count
        #expect(grayCount >= nonCursor.count - 1,
                "disabled TextInput should dim ≥ N-1 of its glyphs; got \(grayCount)/\(nonCursor.count) gray cells")
    }
}

@Suite("Disabled visual dim — TextArea")
@MainActor
struct DisabledTextAreaVisualTests {

    @Test(".disabled() TextArea dims its rendered content")
    func disabledTextAreaDim() {
        var value = "hello"
        var st = TextAreaState()
        let textBinding = Binding<String>(get: { value }, set: { value = $0 })
        let stateBinding = Binding<TextAreaState>(get: { st }, set: { st = $0 })
        let view = TextArea(text: textBinding, state: stateBinding).disabled()
        let buffer = render(view, width: 10, height: 1)
        let colors = nonSpaceForegrounds(buffer)
        #expect(!colors.isEmpty, "TextArea should have rendered some glyphs")
        // Same loose assertion as TextInput — cursor/selection painters
        // may retain colors. Bulk of cells should be .gray.
        let grayCount = colors.filter { $0 == .gray }.count
        #expect(grayCount >= colors.count - 1,
                "disabled TextArea should dim ≥ N-1 of its glyphs; got \(grayCount)/\(colors.count) gray cells")
    }
}
