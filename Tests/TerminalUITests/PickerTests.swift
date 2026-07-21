import Foundation
import Testing
@testable import TerminalUI

// Apple HIG, Pickers: a picker "presents a menu of mutually exclusive options."
// Two rules from that guidance drive the behaviour pinned here:
//
//   * The current selection is always visible, in every style. A collapsed
//     dropdown that does not show its own value forces the user to open it to
//     learn what it holds.
//   * Segmented controls commit on move — there is no separate confirm step —
//     while a menu-style picker commits only on an explicit choice. The two
//     idioms differ deliberately and users rely on the difference.
//
// Style is an environment value rather than an initialiser argument so a
// settings screen can state `.pickerStyle(.inline)` once for a whole Form,
// matching how the framework already scopes other design choices.

private enum Theme: String, Hashable, CaseIterable {
    case light, dark, auto
    var title: String { rawValue.capitalized }
}

/// A reference box so a `Binding` survives being captured by a key handler —
/// `@TerminalState` does not work inside handler closures.
@MainActor
private final class Selection {
    var value: Theme
    init(_ value: Theme) { self.value = value }
    var binding: Binding<Theme> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@discardableResult
@MainActor
private func render(_ graph: AttributeGraph, width: Int = 40, height: Int = 12) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    guard let root = graph.root else { return buffer }
    GraphRenderer.render(
        root,
        into: &buffer,
        context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    )
    return buffer
}

@MainActor
private func buildWithEngine(
    _ engine: FocusEngine,
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    width: Int = 40,
    height: Int = 12
) {
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        render(graph, width: width, height: height)
        engine.rebuildIndex(root: graph.root!)
    }
}

/// Re-evaluate, render, and re-index — the full frame the runtime performs.
///
/// Two steps are load-bearing and each caused a false failure here:
///
///   * `graph.update(from:)` — `@TerminalState` writes land in state storage,
///     but the *body* that reads them only re-runs on update. Rendering the
///     existing tree asserts against the previous frame.
///   * `engine.rebuildIndex` — a dropdown that opens *adds* nodes. Without a
///     rebuild the engine's handler index still describes the closed tree, so
///     the next keypress reaches a stale handler set.
@MainActor
private func reframe(
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    engine: FocusEngine? = nil,
    width: Int = 40,
    height: Int = 12
) -> String {
    guard let engine else {
        graph.update(from: view)
        return renderedText(render(graph, width: width, height: height))
    }
    return GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        let text = renderedText(render(graph, width: width, height: height))
        engine.rebuildIndex(root: graph.root!)
        return text
    }
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
private func themePicker(
    _ selection: Selection,
    style: PickerStyle,
    label: String = "Theme"
) -> some TerminalView {
    Picker(label, selection: selection.binding) {
        ForEach(Theme.allCases) { theme in
            Text(theme.title).tag(theme)
        }
    }
    .pickerStyle(style)
}

extension Theme: Identifiable { var id: String { rawValue } }

// MARK: - Inline

@Suite("Picker — inline style")
@MainActor
struct PickerInlineTests {

    @Test("inline renders every option")
    func inlineRendersAllOptions() {
        let selection = Selection(.light)
        let graph = AttributeGraph()
        graph.update(from: themePicker(selection, style: .inline))

        let text = renderedText(render(graph))
        for theme in Theme.allCases {
            #expect(text.contains(theme.title))
        }
    }

    @Test("inline marks the selected option")
    func inlineMarksSelection() {
        let selection = Selection(.dark)
        let graph = AttributeGraph()
        graph.update(from: themePicker(selection, style: .inline))

        let lines = renderedText(render(graph)).split(separator: "\n", omittingEmptySubsequences: false)
        let darkLine = lines.first { $0.contains("Dark") }
        #expect(darkLine?.contains(PickerGlyph.selected) == true)
    }

    // Movement and commit are separate steps here, unlike segmented.
    @Test("inline down arrow moves the highlight without committing")
    func inlineDownMovesHighlightOnly() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .inline))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .down), root: graph.root!)
        #expect(selection.value == .light)
    }

    @Test("inline Enter commits the highlighted option")
    func inlineEnterCommitsSelection() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .inline))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .down), root: graph.root!)
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(selection.value == .dark)
    }

    @Test("inline highlight starts on the selected option, not the first")
    func inlineHighlightStartsAtSelection() {
        let selection = Selection(.auto)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .inline))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(selection.value == .auto)
    }
}

// MARK: - Segmented

@Suite("Picker — segmented style")
@MainActor
struct PickerSegmentedTests {

    @Test("segmented renders all options on a single row")
    func segmentedRendersSingleRow() {
        let selection = Selection(.light)
        let graph = AttributeGraph()
        graph.update(from: themePicker(selection, style: .segmented))

        let lines = renderedText(render(graph)).split(separator: "\n", omittingEmptySubsequences: false)
        let row = lines.first { $0.contains("Light") }
        #expect(row?.contains("Dark") == true)
        #expect(row?.contains("Auto") == true)
    }

    // HIG: a segmented control has no separate confirm step.
    @Test("segmented right arrow commits immediately")
    func segmentedRightCommitsImmediately() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .segmented))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .right), root: graph.root!)
        #expect(selection.value == .dark)
    }

    @Test("segmented left arrow commits immediately")
    func segmentedLeftCommitsImmediately() {
        let selection = Selection(.dark)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .segmented))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .left), root: graph.root!)
        #expect(selection.value == .light)
    }

    @Test("segmented stops at the ends rather than wrapping")
    func segmentedClampsAtEnds() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, themePicker(selection, style: .segmented))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .left), root: graph.root!)
        #expect(selection.value == .light)
    }

    // Silent truncation would hide options the user can still select by
    // arrowing past the visible edge. Falling back to inline keeps every
    // option addressable and visible.
    @Test("segmented too narrow falls back to inline rendering")
    func segmentedFallsBackToInlineWhenTooNarrow() {
        let selection = Selection(.light)
        let graph = AttributeGraph()
        // `terminalSize` flows in from the runtime, which wraps the whole
        // frame in this binding — the fallback reads it at body-eval time.
        var env = EnvironmentValues()
        env.terminalSize = TerminalSize(cols: 12, rows: 12)
        let text = GraphContext.$currentEnvironment.withValue(env) {
            graph.update(from: themePicker(selection, style: .segmented))
            return renderedText(render(graph, width: 12, height: 12))
        }

        let optionLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in Theme.allCases.contains { line.contains($0.title) } }
        #expect(optionLines.count >= Theme.allCases.count)
    }

    @Test("segmented stays on one row when it fits")
    func segmentedStaysSingleRowWhenItFits() {
        let selection = Selection(.light)
        let graph = AttributeGraph()
        var env = EnvironmentValues()
        env.terminalSize = TerminalSize(cols: 80, rows: 24)
        let text = GraphContext.$currentEnvironment.withValue(env) {
            graph.update(from: themePicker(selection, style: .segmented))
            return renderedText(render(graph, width: 80, height: 24))
        }

        let optionLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in Theme.allCases.contains { line.contains($0.title) } }
        #expect(optionLines.count == 1)
    }
}

// MARK: - Dropdown

@Suite("Picker — dropdown style")
@MainActor
struct PickerDropdownTests {

    @Test("dropdown collapsed shows the current value and an affordance")
    func dropdownCollapsedShowsCurrentValue() {
        let selection = Selection(.dark)
        let graph = AttributeGraph()
        graph.update(from: themePicker(selection, style: .dropdown))

        let text = renderedText(render(graph))
        #expect(text.contains("Dark"))
        #expect(text.contains(PickerGlyph.collapsed))
        // Closed: the other options must not be on screen.
        #expect(!text.contains("Auto"))
    }

    @Test("dropdown Enter opens the option list")
    func dropdownEnterOpensOverlay() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = themePicker(selection, style: .dropdown)
        buildWithEngine(engine, graph, view)

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(reframe(graph, view, engine: engine).contains("Auto"))
    }

    @Test("dropdown Esc closes without committing")
    func dropdownEscClosesWithoutCommitting() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = themePicker(selection, style: .dropdown)
        buildWithEngine(engine, graph, view)

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        // Confirm it actually opened, so a no-op Esc cannot pass vacuously.
        #expect(reframe(graph, view, engine: engine).contains("Auto"))

        _ = engine.routeKeyEvent(KeyEvent(key: .down), root: graph.root!)
        _ = engine.routeKeyEvent(KeyEvent(key: .escape), root: graph.root!)

        #expect(selection.value == .light)
        #expect(!reframe(graph, view, engine: engine).contains("Auto"))
    }

    @Test("dropdown Enter commits the highlighted option and closes")
    func dropdownEnterCommitsAndCloses() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = themePicker(selection, style: .dropdown)
        buildWithEngine(engine, graph, view)

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        _ = reframe(graph, view, engine: engine)
        _ = engine.routeKeyEvent(KeyEvent(key: .down), root: graph.root!)
        _ = reframe(graph, view, engine: engine)
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)

        #expect(selection.value == .dark)
        #expect(!reframe(graph, view, engine: engine).contains("Auto"))
    }
}

// MARK: - Edge cases

@Suite("Picker — edge cases")
@MainActor
struct PickerEdgeCaseTests {

    @Test("a picker with no options renders a placeholder rather than crashing")
    func emptyPickerRendersPlaceholder() {
        let selection = Selection(.light)
        let graph = AttributeGraph()
        graph.update(from: Picker("Theme", selection: selection.binding) { EmptyView() }
            .pickerStyle(.inline))

        let text = renderedText(render(graph))
        #expect(text.contains("Theme"))
        #expect(text.contains(PickerGlyph.emptyPlaceholder))
    }

    // Coercing to the first option would hide the consumer's bug and silently
    // change their model value behind their back.
    @Test("a selection absent from the options is shown raw, not coerced")
    func selectionNotInOptionsRendersRaw() {
        let selection = Selection(.auto)
        let graph = AttributeGraph()
        graph.update(from: Picker("Theme", selection: selection.binding) {
            Text("Light").tag(Theme.light)
            Text("Dark").tag(Theme.dark)
        }.pickerStyle(.dropdown))

        #expect(renderedText(render(graph)).contains("auto"))
        #expect(selection.value == .auto)
    }

    @Test("an empty picker cannot be opened into an empty overlay")
    func emptyDropdownDoesNotOpen() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph,
                        Picker("Theme", selection: selection.binding) { EmptyView() }
                            .pickerStyle(.dropdown))

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(renderedText(render(graph)).contains(PickerGlyph.emptyPlaceholder))
    }

    @Test("a disabled picker is skipped in the tab order")
    func disabledPickerSkippedInTabOrder() {
        let selection = Selection(.light)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, VStack {
            themePicker(selection, style: .inline).disabled(true)
            Button("After") {}
        })

        engine.focusNext()
        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(selection.value == .light)
    }

    // Selection identity lives in the Binding, not in graph state, so an
    // unrelated update must not disturb it.
    @Test("selection survives graph reconciliation")
    func selectionSurvivesReconciliation() {
        let selection = Selection(.dark)
        let graph = AttributeGraph()
        graph.update(from: themePicker(selection, style: .inline, label: "Theme"))
        render(graph)
        graph.update(from: themePicker(selection, style: .inline, label: "Appearance"))

        let lines = renderedText(render(graph)).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first { $0.contains("Dark") }?.contains(PickerGlyph.selected) == true)
        #expect(selection.value == .dark)
    }
}
