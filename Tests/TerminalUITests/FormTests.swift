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

/// Column at which a row's control starts — the first character after the
/// label's padded column.
private func controlColumn(in line: String, marker: Character) -> Int? {
    line.firstIndex(of: marker).map { line.distance(from: line.startIndex, to: $0) }
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
