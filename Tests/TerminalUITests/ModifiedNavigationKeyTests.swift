import Testing
@testable import TerminalUI

// Views that move by the arrows took every arrow, so Shift+↓ and Ctrl+↑ did
// what ↓ and ↑ do, and an app could never bind a modified arrow on a view
// that moves by them: views see a key before an app's bindings, and the
// key went no further. Crush, for one, steps a message at a time on
// Shift+↑/↓ in the transcript its plain arrows scroll. A view moves on the
// plain navigation keys; a modified one goes on to the app.

/// Single-valued, so every binding the cases hand out stays put between
/// presses of one case.
@MainActor
private final class Holder<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
    var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

private struct Row: Identifiable {
    let id: Int
    let children: [Row]?
}

/// A view that moves by `key`, and the key that moves it.
private struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    let key: Key
    let view: @MainActor @Sendable () -> any TerminalView
    var testDescription: String { name }
}

private let rows = (0..<20).map { Row(id: $0, children: nil) }

private let cases: [Case] = [
    Case(name: "a scrollable ScrollView", key: .down) {
        ScrollView(.vertical) {
            VStack { ForEachWithID(0..<20, id: \.self) { Text("row \($0)") } }
        }.scrollable()
    },
    Case(name: "a List", key: .down) {
        List(rows, selection: Holder<Int?>(0).binding) { Text("row \($0.id)") }
    },
    Case(name: "a TreeView", key: .down) {
        TreeView(rows, children: \.children) { Text("row \($0.id)") }
    },
    Case(name: "a DiffView", key: .down) {
        DiffView(original: (0..<30).map { "old \($0)" }.joined(separator: "\n"),
                 modified: (0..<30).map { "new \($0)" }.joined(separator: "\n"), visibleHeight: 4)
    },
    Case(name: "a HunkDiffView", key: .down) {
        HunkDiffView(hunks: [HunkDiff.Hunk(oldStart: 1, newStart: 1, lines: (1...5).map { (number: Int) in
            HunkDiff.Line(type: .context, content: "line \(number)", oldLineNo: number, newLineNo: number)
        })], fileName: "a.swift")
    },
    Case(name: "an inline Picker", key: .down) {
        Picker("Size", selection: Holder("s").binding) {
            Text("Small").tag("s")
            Text("Large").tag("l")
        }.pickerStyle(.inline)
    },
    Case(name: "a segmented Picker", key: .right) {
        Picker("Size", selection: Holder("s").binding) {
            Text("Small").tag("s")
            Text("Large").tag("l")
        }.pickerStyle(.segmented)
    },
    Case(name: "a TabView", key: .right) {
        TabView {
            Tab("One") { Text("first") }
            Tab("Two") { Text("second") }
        }
    },
    Case(name: "a Slider", key: .right) {
        Slider(value: Holder(0.5).binding)
    },
    Case(name: "a Stepper", key: .right) {
        Stepper("Count", value: Holder(5).binding, in: 0...10)
    },
]

@Suite("Views leave modified navigation keys to the app")
@MainActor
struct ModifiedNavigationKeyTests {

    /// Whether `view`, drawn and holding focus, takes `event`.
    private func takes(_ event: KeyEvent, _ view: any TerminalView) -> Bool {
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
            let rect = Rect(x: 0, y: 0, width: 40, height: 6)
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            var buffer = CellBuffer(width: 40, height: 6)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            engine.rebuildIndex(root: graph.root!)
        }
        engine.focusNext()
        return GraphContext.$currentFocusEngine.withValue(engine) {
            engine.routeKeyEvent(event, root: graph.root!)
        }
    }

    @Test(arguments: cases)
    fileprivate func thePlainKeyMovesTheView(_ testCase: Case) {
        #expect(takes(KeyEvent(key: testCase.key), testCase.view()))
    }

    @Test(arguments: cases)
    fileprivate func theKeyWithAModifierGoesOnToTheApp(_ testCase: Case) {
        for modifiers in [KeyModifiers.shift, .ctrl, .alt] {
            #expect(!takes(KeyEvent(key: testCase.key, modifiers: modifiers), testCase.view()),
                    "\(testCase.name) took the key with \(modifiers)")
        }
    }
}
