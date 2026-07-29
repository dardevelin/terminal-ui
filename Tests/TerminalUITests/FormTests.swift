import Foundation
import Testing
@testable import TerminalUI

// Apple HIG, Settings: a settings screen is "a list of controls, grouped into
// sections, with labels aligned so the eye can scan the column." That
// alignment *is* the feature — a Form that does not align its labels is a
// VStack with extra ceremony.
//
// The mechanism: a row states its label width through `_FormRowLabel`, `Form`
// takes the widest, and publishes it as an environment value. Every control
// reads that value and pads its own label to match. No control is forked into
// a form-aware variant, and a control used outside a Form sees no value and
// renders exactly as before.

@MainActor
private final class Model {
    var toggle = false
    var theme = "dark"
    var count = 5
    var volume: Double = 50
    var toggleBinding: Binding<Bool> { Binding(get: { self.toggle }, set: { self.toggle = $0 }) }
    var themeBinding: Binding<String> { Binding(get: { self.theme }, set: { self.theme = $0 }) }
    var countBinding: Binding<Int> { Binding(get: { self.count }, set: { self.count = $0 }) }
    var volumeBinding: Binding<Double> { Binding(get: { self.volume }, set: { self.volume = $0 }) }
}

@discardableResult
@MainActor
private func render(_ graph: AttributeGraph, width: Int = 60, height: Int = 20) -> CellBuffer {
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

private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

@MainActor
private func buildWithEngine(
    _ engine: FocusEngine,
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    width: Int = 60,
    height: Int = 20
) {
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        render(graph, width: width, height: height)
        engine.rebuildIndex(root: graph.root!)
    }
}

/// One frame of the real run loop: update, adjust scroll for focus, lay out,
/// render, reindex — in that order. A form that scrolls cannot be verified by
/// `render` alone, because the offset that keeps the focused row visible is
/// computed between update and render.
@MainActor
private func frame(
    _ engine: FocusEngine,
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    width: Int = 40,
    height: Int = 10
) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    var env = EnvironmentValues()
    env.terminalSize = TerminalSize(cols: width, rows: height)
    GraphContext.$currentFocusEngine.withValue(engine) {
        GraphContext.$currentEnvironment.withValue(env) {
            GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
                graph.update(from: view)
                GraphRenderer.adjustScrollForFocus(
                    root: graph.root, focusedID: engine.keyboardFocusID,
                    viewportWidth: width, viewportHeight: height
                )
                guard let root = graph.root else { return }
                let rect = Rect(x: 0, y: 0, width: width, height: height)
                Layout.measureAndPlace(graph: root, in: rect)
                GraphRenderer.render(root, into: &buffer, context: RenderContext(rect: rect))
                engine.rebuildIndex(root: root)
            }
        }
    }
    return buffer
}

/// Column at which a row's control starts — the first character after the
/// label's padded column.
private func controlColumn(in line: String, marker: Character) -> Int? {
    line.firstIndex(of: marker).map { line.distance(from: line.startIndex, to: $0) }
}

/// A settings screen with more rows than any terminal this test runs at.
private struct TallForm: TerminalView {
    let isOn: Binding<Bool>
    let rows: Int

    var body: some TerminalView {
        Form {
            ForEachWithID(Array(0..<rows), id: \.self) { index in
                Toggle("Row \(index)", isOn: isOn)
            }
        }
    }
}

// MARK: - Label column

@Suite("Form — shared label column")
@MainActor
struct FormLabelColumnTests {

    @Test("controls align to the widest label in the form")
    func alignsToWidestLabel() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Toggle("Wi-Fi", isOn: model.toggleBinding)
            Toggle("Bluetooth connectivity", isOn: model.toggleBinding)
        })

        let rendered = lines(renderedText(render(graph)))
        let shortRow = rendered.first { $0.contains("Wi-Fi") }
        let longRow = rendered.first { $0.contains("Bluetooth") }
        #expect(shortRow != nil && longRow != nil)

        // Both checkboxes must begin at the same column.
        let shortCol = shortRow.flatMap { controlColumn(in: $0, marker: "[") }
        let longCol = longRow.flatMap { controlColumn(in: $0, marker: "[") }
        #expect(shortCol != nil)
        #expect(shortCol == longCol)
    }

    // The alignment must not depend on which control type a row holds, or a
    // form mixing toggles and steppers would step-ladder down the screen.
    @Test("different control types share one column")
    func mixedControlsShareColumn() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Toggle("Telemetry", isOn: model.toggleBinding)
            Stepper("Tab width", value: model.countBinding, in: 1...16)
        })

        let rendered = lines(renderedText(render(graph)))
        let toggleRow = rendered.first { $0.contains("Telemetry") }
        let stepperRow = rendered.first { $0.contains("Tab width") }
        let toggleCol = toggleRow.flatMap { controlColumn(in: $0, marker: "[") }
        let stepperCol = stepperRow.flatMap { controlColumn(in: $0, marker: Character(SliderGlyph.decrement)) }
        #expect(toggleCol != nil && stepperCol != nil)
        #expect(toggleCol == stepperCol)
    }

    // Picker draws its own label in three style bodies, so it is the control
    // most likely to miss the column — and it did, by two cells, until it
    // routed through the shared row like every other control.
    @Test("a picker joins the shared column")
    func pickerJoinsSharedColumn() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Picker("Theme", selection: model.themeBinding) {
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Bluetooth connectivity", isOn: model.toggleBinding)
        })

        let rendered = lines(renderedText(render(graph)))
        let pickerRow = rendered.first { $0.contains("Dark") }
        let toggleRow = rendered.first { $0.contains("Bluetooth") }
        let pickerCol = pickerRow.flatMap { controlColumn(in: $0, marker: "D") }
        let toggleCol = toggleRow.flatMap { controlColumn(in: $0, marker: "[") }
        #expect(pickerCol != nil)
        #expect(pickerCol == toggleCol)
    }

    // The slider re-derived its track offset from `label.count`, but inside a
    // Form the label is padded to the shared column — so a click near the left
    // end of the track resolved to a position far to its right and saturated
    // the value.
    @Test("clicking a slider's track inside a Form lands where the user clicked")
    func sliderClickInsideFormIsAccurate() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Form {
            Toggle("Bluetooth connectivity", isOn: model.toggleBinding)
            Slider(value: model.volumeBinding, in: 0...100, label: "Vol")
        })

        let rendered = lines(renderedText(render(graph)))
        let sliderRow = rendered.firstIndex { $0.contains("●") }
        let trackStart = rendered.first { $0.contains("●") }
            .flatMap { line in line.firstIndex(of: "─").map { line.distance(from: line.startIndex, to: $0) } }
        #expect(sliderRow != nil && trackStart != nil)

        guard let sliderRow, let trackStart else { return }
        // Click the first cell of the track: that is the lower bound.
        engine.handleMouseClick(x: trackStart, y: sliderRow, root: graph.root!)
        #expect(model.volume == 0.0)
    }

    // A control used outside a Form must render exactly as it always has.
    @Test("a control outside a Form is not padded")
    func outsideFormIsUnpadded() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Toggle("Wi-Fi", isOn: model.toggleBinding))

        let row = lines(renderedText(render(graph))).first { $0.contains("Wi-Fi") }
        #expect(row?.hasPrefix("[") == true)
    }

    @Test("a narrow terminal stacks the label above its control")
    func stacksWhenTooNarrow() {
        let model = Model()
        let graph = AttributeGraph()
        var env = EnvironmentValues()
        env.terminalSize = TerminalSize(cols: 16, rows: 20)
        let text = GraphContext.$currentEnvironment.withValue(env) {
            graph.update(from: Form {
                Toggle("Bluetooth connectivity", isOn: model.toggleBinding)
            })
            return renderedText(render(graph, width: 16, height: 20))
        }

        let rendered = lines(text)
        let labelRow = rendered.firstIndex { $0.contains("Bluetooth") }
        let controlRow = rendered.firstIndex { $0.contains("[") }
        #expect(labelRow != nil && controlRow != nil)
        if let labelRow, let controlRow { #expect(controlRow > labelRow) }
    }
}

// MARK: - Section

@Suite("Form — sections")
@MainActor
struct FormSectionTests {

    @Test("a section renders its header and footer")
    func rendersHeaderAndFooter() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section {
                Toggle("Wi-Fi", isOn: model.toggleBinding)
            } header: {
                Text("Network")
            } footer: {
                Text("Applies immediately")
            }
        })

        let text = renderedText(render(graph))
        #expect(text.contains("NETWORK"))          // headers render uppercase
        #expect(text.contains("Applies immediately"))
    }

    @Test("the title convenience initialiser renders a header")
    func titleConvenienceRendersHeader() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("Appearance") {
                Toggle("Dark mode", isOn: model.toggleBinding)
            }
        })
        #expect(renderedText(render(graph)).contains("APPEARANCE"))
    }

    // An orphan header over nothing, or a divider with no section after it,
    // both read as a rendering fault rather than an empty state.
    @Test("an empty section renders nothing at all")
    func emptySectionRendersNothing() {
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("Ghost") { EmptyView() }
        })
        #expect(!renderedText(render(graph)).contains("GHOST"))
    }

    // `isSection` is a direct type test, so a section produced by a `ForEach`
    // or guarded by an `if` was never stamped with an ordinal — every one kept
    // index 0 and suppressed its own divider.
    @Test("sections inside a ForEach still get their dividers")
    func sectionsInsideForEachGetDividers() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("First") { Toggle("A", isOn: model.toggleBinding) }
            ForEachWithID(["Second", "Third"], id: \.self) { title in
                Section(title) { Toggle(title, isOn: model.toggleBinding) }
            }
        })

        let rendered = lines(renderedText(render(graph)))
        #expect(rendered.filter { $0.contains("──") }.count == 2)
    }

    @Test("a section behind a condition still gets its divider")
    func sectionBehindConditionGetsDivider() {
        let model = Model()
        let show = true
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("First") { Toggle("A", isOn: model.toggleBinding) }
            if show {
                Section("Second") { Toggle("B", isOn: model.toggleBinding) }
            }
        })

        let rendered = lines(renderedText(render(graph)))
        #expect(rendered.filter { $0.contains("──") }.count == 1)
    }

    // An empty section renders nothing, so it must not consume an ordinal
    // either — otherwise the next section believes something precedes it and
    // opens the form with a rule that has nothing above it.
    @Test("an empty leading section does not leave a rule at the top")
    func emptyLeadingSectionLeavesNoRule() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("Ghost") { EmptyView() }
            Section("Real") { Toggle("A", isOn: model.toggleBinding) }
        })

        let rendered = lines(renderedText(render(graph)))
        #expect(rendered.filter { $0.contains("──") }.isEmpty)
    }

    @Test("dividers separate sections but never trail the last one")
    func dividersBetweenSectionsOnly() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            Section("One") { Toggle("A", isOn: model.toggleBinding) }
            Section("Two") { Toggle("B", isOn: model.toggleBinding) }
        })

        let rendered = lines(renderedText(render(graph)))
        let dividerRows = rendered.indices.filter { rendered[$0].contains("──") }
        let lastContentRow = rendered.lastIndex { $0.contains("B") } ?? 0
        #expect(dividerRows.count == 1)
        if let divider = dividerRows.first { #expect(divider < lastContentRow) }
    }
}

// MARK: - LabeledContent

@Suite("Form — LabeledContent")
@MainActor
struct LabeledContentTests {

    @Test("the value initialiser renders both sides")
    func valueInitRendersBothSides() {
        let graph = AttributeGraph()
        graph.update(from: LabeledContent("Version", value: "1.0.0"))
        let text = renderedText(render(graph))
        #expect(text.contains("Version"))
        #expect(text.contains("1.0.0"))
    }

    @Test("labeled content participates in the shared column")
    func participatesInSharedColumn() {
        let model = Model()
        let graph = AttributeGraph()
        graph.update(from: Form {
            LabeledContent("ID", value: "42")
            Toggle("Bluetooth connectivity", isOn: model.toggleBinding)
        })

        let rendered = lines(renderedText(render(graph)))
        let idRow = rendered.first { $0.contains("42") }
        let toggleRow = rendered.first { $0.contains("Bluetooth") }
        let idCol = idRow.flatMap { controlColumn(in: $0, marker: "4") }
        let toggleCol = toggleRow.flatMap { controlColumn(in: $0, marker: "[") }
        #expect(idCol != nil)
        #expect(idCol == toggleCol)
    }
}

// MARK: - Scrolling

// Apple HIG, Settings: a settings screen is a scrolling list. A form taller
// than the terminal that merely clips is worse than one that scrolls — the
// rows below the fold stay focusable, so Tab lands on controls the user cannot
// see and cannot tell have changed.
//
// `Form` composes the shipped `ScrollView`. Always, not on overflow: the
// scrollbar and the ▲/▼ glyphs already suppress themselves when content fits,
// so "only when it overflows" would be a second overflow test answering a
// question the renderer already answers.

@Suite("Form — scrolling")
@MainActor
struct FormScrollingTests {

    // One Tab past the fold, two facts: the row arrives, and the one it
    // replaced leaves. A form that grew instead of scrolling would satisfy the
    // first and fail the second.
    @Test("Tab to a row below the fold scrolls it into view")
    func tabBelowFoldScrollsIntoView() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = TallForm(isOn: model.toggleBinding, rows: 20)

        let top = renderedText(frame(engine, graph, view))
        #expect(top.contains("Row 0"))

        for _ in 0..<20 { engine.focusNext() }
        let bottom = renderedText(frame(engine, graph, view))

        #expect(bottom.contains("Row 19"),
                "the focused row must be on screen, not below the fold")
        #expect(!bottom.contains("Row 0"),
                "the viewport moved, so the first row is no longer drawn")
    }

    // The column is measured from every row, including the ones off screen —
    // scrolling must not re-measure it against whatever happens to be visible,
    // or the controls would shift sideways as the user scrolls.
    @Test("the label column stays aligned after scrolling")
    func labelColumnSurvivesScrolling() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        // "Row 10" is a cell wider than "Row 0": the column is only stable if
        // it was measured across the whole form.
        let view = TallForm(isOn: model.toggleBinding, rows: 20)

        _ = frame(engine, graph, view)
        for _ in 0..<20 { engine.focusNext() }

        let rendered = lines(renderedText(frame(engine, graph, view)))
        let columns = Set(rendered.filter { $0.contains("Row ") }
            .compactMap { controlColumn(in: $0, marker: "[") })
        #expect(columns.count == 1, "every visible control shares one column")
    }

    // A short form is the common case; an affordance that draws when there is
    // nothing to scroll to is noise.
    @Test("a form that fits draws no scrollbar")
    func shortFormDrawsNoScrollbar() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = TallForm(isOn: model.toggleBinding, rows: 3)

        let text = renderedText(frame(engine, graph, view))
        #expect(!text.contains("█"))
        #expect(!text.contains("▼"))
    }

    @Test("a form taller than the viewport shows the overflow affordance")
    func tallFormShowsScrollbar() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = TallForm(isOn: model.toggleBinding, rows: 20)

        let text = renderedText(frame(engine, graph, view))
        #expect(text.contains("▼"), "there is more content below the fold")
    }
}

// MARK: - Focus

@Suite("Form — focus")
@MainActor
struct FormFocusTests {

    // Labels, headers and footers are text. Landing on them would be a stop in
    // the Tab order that does nothing.
    @Test("Tab visits only the controls, skipping headers and labels")
    func tabSkipsNonControls() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Form {
            Section("Appearance") {
                Toggle("Dark mode", isOn: model.toggleBinding)
                Stepper("Tab width", value: model.countBinding, in: 1...16)
            }
        })

        var visited: [NodeID] = []
        for _ in 0..<4 {
            engine.focusNext()
            if let id = engine.keyboardFocusID { visited.append(id) }
        }
        // Two controls, so cycling four times must revisit exactly two nodes.
        #expect(Set(visited).count == 2)
    }
}

// MARK: - Arrow navigation

// Apple HIG, Settings: a settings screen is a list, and Down walks it. Two
// separate things stopped that walk short.
//
// A result builder groups the rows a `Section` was written with into one
// structural stack. Structural stacks stay out of the focus walk, which is
// right — but their children were dropped along with them rather than spliced
// into the parent, so a section holding two rows presented one child and
// arrows stepped over the second.
//
// And a stack refuses to let arrows past its last child, which is right for a
// stack sitting next to unrelated content and wrong inside a form: the rows
// of the next section are the continuation of this list, not somewhere else.

@Suite("Form — arrow navigation")
@MainActor
struct FormArrowNavigationTests {

    private func sectionedForm(_ model: Model) -> some TerminalView {
        Form {
            Section("Appearance") {
                Toggle("Dark mode", isOn: model.toggleBinding)
                Stepper("Tab width", value: model.countBinding, in: 1...16)
            }
            Section("Editor") {
                Toggle("Autosave", isOn: model.toggleBinding)
                Stepper("History depth", value: model.countBinding, in: 1...16)
            }
        }
    }

    /// Every row the form draws, in the order Down should visit them.
    private func walkDown(_ engine: FocusEngine, _ graph: AttributeGraph, steps: Int) -> [NodeID] {
        var visited: [NodeID] = []
        for _ in 0..<steps {
            engine.move(.down, root: graph.root!)
            if let id = engine.keyboardFocusID { visited.append(id) }
        }
        return visited
    }

    @Test("Down visits both rows of a section, not just the first")
    func downVisitsEveryRowInASection() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, sectionedForm(model), width: 40, height: 20)

        engine.focusNext()
        let first = engine.keyboardFocusID
        // Tab order is the reference: the row after the first is the second
        // row of the same section.
        engine.focusNext()
        let second = engine.keyboardFocusID
        engine.keyboardFocusID = first

        engine.move(.down, root: graph.root!)
        #expect(engine.keyboardFocusID == second,
                "Down goes to the very next row, not past it to the next section")
    }

    @Test("Down reaches every control in the form")
    func downReachesEveryControl() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        _ = frame(engine, graph, sectionedForm(model), width: 40, height: 20)

        engine.focusNext()
        var visited: Set<NodeID> = [engine.keyboardFocusID].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        for id in walkDown(engine, graph, steps: 6) { visited.insert(id) }

        #expect(visited.count == 4,
                "four controls across two sections, all reachable by Down alone")
    }
}

// MARK: - Focus indicator

// The bar that marks the focused row draws one cell to the left of it, in the
// padding a form usually sits in. That is the `.overlay` style, whose own
// documentation calls it the best visual for forms — and it was skipped for
// any node inside a scroll container, on the grounds that scroll clipping
// fights with cells drawn outside the content area. Once a `Form` composed a
// `ScrollView`, that condition became true for every control in every form and
// the focused row became the only thing on screen with nothing to say so.
//
// The clipping concern is real but narrower than the rule: it only matters
// when the focused row has scrolled out of its own viewport, which is a
// question about the row's position, not about whether a scroll container
// exists somewhere above it.

@Suite("Form — focus indicator")
@MainActor
struct FormFocusIndicatorTests {

    private func markedRows(_ buffer: CellBuffer) -> [Int] {
        (0..<buffer.height).filter { y in
            (0..<buffer.width).contains { x in buffer[x, y].character == "▎" }
        }
    }

    @Test("the focused row is marked")
    func focusedRowIsMarked() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = TallForm(isOn: model.toggleBinding, rows: 4).padding().border()

        var buffer = frame(engine, graph, view, width: 40, height: 12)
        engine.focusNext()
        buffer = frame(engine, graph, view, width: 40, height: 12)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root)
        }

        let rows = markedRows(buffer)
        #expect(rows.count == 1, "exactly one row carries the focus bar")

        let text = (0..<buffer.width).map { String(buffer[$0, rows.first ?? 0].character) }.joined()
        #expect(text.contains("Row 0"), "and it is the row that has focus")
    }

    // The narrower rule the blanket skip was standing in for: a row that has
    // scrolled out of its viewport must not leave a bar behind on whatever is
    // drawn where it used to be.
    @Test("a row scrolled out of the viewport leaves no bar behind")
    func scrolledAwayRowLeavesNoBar() {
        let model = Model()
        let engine = FocusEngine()
        let graph = AttributeGraph()
        let view = TallForm(isOn: model.toggleBinding, rows: 30).padding().border()

        var buffer = frame(engine, graph, view, width: 40, height: 10)
        for _ in 0..<30 { engine.focusNext() }
        buffer = frame(engine, graph, view, width: 40, height: 10)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root)
        }

        let rows = markedRows(buffer)
        #expect(rows.count <= 1)
        for y in rows {
            let text = (0..<buffer.width).map { String(buffer[$0, y].character) }.joined()
            #expect(text.contains("Row "), "a bar only ever sits beside a row")
        }
    }
}
