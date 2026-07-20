import Testing
@testable import TerminalUI

// / drop-in contract: each core component must render with
// the minimal required init args (data binding only, no sizing or layout
// config) and produce non-empty output into a reasonable buffer. Validates
// that the SwiftUI-style default principle holds: Component(x) works.

// Minimal Identifiable wrapper for List/TreeView tests.
private struct Row: Identifiable {
    let id: Int
    let label: String
}

private func renderToBuffer<V: TerminalView>(_ view: V, width: Int = 40, height: Int = 10) -> CellBuffer {
    let graph = AttributeGraph()
    graph.update(from: view)
    var buffer = CellBuffer(width: width, height: height)
    let ctx = RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    if let root = graph.root {
        GraphRenderer.render(root, into: &buffer, context: ctx)
    }
    return buffer
}

private func hasContent(_ buffer: CellBuffer) -> Bool {
    for cell in buffer.cells where cell.character != " " { return true }
    return false
}

@Suite("Drop-in contract — core components render with minimal args")
@MainActor
struct DropInContractTests {

    @Test("Text renders single string")
    func textMinimal() {
        let buffer = renderToBuffer(Text("hello"))
        #expect(buffer[0, 0].character == "h")
        #expect(buffer[4, 0].character == "o")
    }

    @Test("List renders non-empty data without visibleCount")
    func listMinimal() {
        let rows = [Row(id: 1, label: "alpha"), Row(id: 2, label: "beta")]
        let buffer = renderToBuffer(List(rows) { Text($0.label) })
        #expect(hasContent(buffer))
    }

    @Test("List with empty data renders empty placeholder")
    func listEmpty() {
        let buffer = renderToBuffer(List([Row]()) { Text($0.label) })
        // Placeholder contains em-dash + "empty"
        #expect(hasContent(buffer), "empty list should render the placeholder row")
    }

    @Test("PromptInput renders with only text and state bindings")
    func promptInputMinimal() {
        // Simulated bindings — real usage would be @TerminalState.
        var text = "type something"
        var promptState = PromptInputState()
        let textBinding = Binding(get: { text }, set: { text = $0 })
        let stateBinding = Binding(get: { promptState }, set: { promptState = $0 })
        let buffer = renderToBuffer(
            PromptInput(text: textBinding, state: stateBinding),
            width: 30, height: 3
        )
        #expect(hasContent(buffer))
    }

    @Test("Table renders with rows + columns, no custom width args")
    func tableMinimal() {
        let rows = [Row(id: 1, label: "alpha")]
        let buffer = renderToBuffer(
            Table(rows, columns: [
                TableColumn("id") { "\($0.id)" },
                TableColumn("label") { $0.label },
            ])
        )
        #expect(hasContent(buffer))
    }

    @Test("Table with empty rows renders empty placeholder")
    func tableEmpty() {
        let buffer = renderToBuffer(
            Table([Row](), columns: [TableColumn("id") { "\($0.id)" }])
        )
        #expect(hasContent(buffer))
    }

    @Test("BarChart fits container without barWidth arg")
    func barChartMinimal() {
        let items = [
            BarChart.Item(label: "go", value: 100),
            BarChart.Item(label: "rs", value: 50),
        ]
        let buffer = renderToBuffer(BarChart(items: items), width: 30, height: 3)
        #expect(hasContent(buffer))
    }

    @Test("Sparkline fits container without explicit size")
    func sparklineMinimal() {
        let buffer = renderToBuffer(Sparkline(data: [1, 5, 3, 8, 2, 6]), width: 20, height: 3)
        #expect(hasContent(buffer))
    }

    @Test("HeatMap renders with colored spans by default")
    func heatMapMinimal() {
        let data: [[Double]] = [[0.1, 0.5, 1.0], [0.0, 0.3, 0.7]]
        let buffer = renderToBuffer(HeatMap(data: data), width: 4, height: 3)
        #expect(hasContent(buffer))
    }
}
