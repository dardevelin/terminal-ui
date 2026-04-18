import Foundation
import Observation
import TerminalUI

// MARK: - Detail pane

/// Renders the currently selected page as:
///   [NAME] bold
///   [SUMMARY] gray
///   ────────────
///   Code:
///     [CODE] boxed
///   Preview:
///     [LIVE VIEW]
///
/// The `@ViewBuilder` switch on `PageID` is the canonical registration point —
/// each component gets one arm returning its concrete preview view.
struct PageDetail: TerminalView {
    let pageID: PageID
    let state: StorybookState

    var body: some TerminalView {
        let info = pageID.info
        return VStack {
            Text(info.name).bold().foreground(.cyan)
            Text(info.summary).foreground(.gray)
            Divider()
            // Code pane: border is the outer frame, ScrollView lives INSIDE
            // the border so the closing ╰─╯ is always visible even for long
            // snippets. frame(height:) gives a fixed window; content scrolls
            // within. Still wants HYP-76 (visible scrollbar affordance).
            Text("Code").foreground(.gray).bold()
            ScrollView(.vertical) {
                CodeBlock(code: info.code)
            }
            .frame(height: 12)
            .padding()
            .border()
            Text("").foreground(.default)
            Text("Preview").foreground(.gray).bold()
            PreviewPane(pageID: pageID, state: state)
                .padding()
                .border()
            Spacer()
        }
    }
}

// MARK: - Code block
//
// Pre-wraps long lines at `maxWidth` so content stays inside its container.
// The outer frame (border + padding) is now applied by PageDetail around
// the enclosing ScrollView — so CodeBlock itself is plain text rows.

struct CodeBlock: TerminalView {
    let code: String

    var body: some TerminalView {
        GeometryReader { size in
            // Reserve 4 cells for the PageDetail-applied border+padding.
            let maxWidth = max(20, size.width - 4)
            let wrapped = wrap(code: code, maxWidth: maxWidth)
            VStack {
                ForEachWithID(Array(wrapped.enumerated()), id: \.offset) { pair in
                    Text(pair.element).foreground(.brightBlue)
                }
            }
        }
    }

    /// Word-aware line wrap preserving original indentation on continuation.
    private func wrap(code: String, maxWidth: Int) -> [String] {
        var out: [String] = []
        for raw in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.count <= maxWidth {
                out.append(line)
                continue
            }
            // Split long line. Continuation lines carry the original indent
            // plus two extra spaces so they read as "wrapped continuation."
            let indent = line.prefix(while: { $0 == " " })
            let continuation = String(indent) + "  "
            var remaining = line
            var first = true
            while remaining.count > maxWidth {
                let cutWidth = first ? maxWidth : (maxWidth - continuation.count)
                let idx = remaining.index(remaining.startIndex, offsetBy: max(1, cutWidth))
                let chunk = String(remaining[..<idx])
                out.append(first ? chunk : (continuation + chunk))
                remaining = String(remaining[idx...])
                first = false
            }
            if !remaining.isEmpty {
                out.append(first ? remaining : (continuation + remaining))
            }
        }
        return out
    }
}

// MARK: - Preview switch

/// The single switch that maps each `PageID` to its concrete preview view.
/// Intentionally monolithic so the canonical list of components is one
/// readable file. When adding a page, add a case here + a case to `PageID`.
struct PreviewPane: TerminalView {
    let pageID: PageID
    let state: StorybookState

    var body: some TerminalView {
        switch pageID {
        // ───── Layout ─────
        case .vstack:
            VStack {
                Text("row 1").foreground(.red)
                Text("row 2").foreground(.yellow)
                Text("row 3").foreground(.green)
            }
        case .hstack:
            HStack {
                Text("A").foreground(.red)
                Text("|").foreground(.gray)
                Text("B").foreground(.green)
                Text("|").foreground(.gray)
                Text("C").foreground(.blue)
            }
        case .zstack:
            // Layered: a multi-line background box with a label painted on top.
            ZStack {
                Text("◼◼◼◼◼◼◼◼◼◼\n◼◼◼◼◼◼◼◼◼◼\n◼◼◼◼◼◼◼◼◼◼")
                    .foreground(.ansi256(238))
                Text(" OVER ").foreground(.cyan).bold()
            }
        case .spacer:
            HStack {
                Text("[left]").foreground(.yellow)
                Spacer()
                Text("[right]").foreground(.yellow)
            }
        case .divider:
            VStack {
                Text("above")
                Divider()
                Text("below")
            }
        case .scrollview:
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(Array(0..<20), id: \.self) { i in
                        Text("row \(i)").foreground(i % 2 == 0 ? .cyan : .default)
                    }
                }
            }
            .frame(height: 6)
        case .geometryreader:
            GeometryReader { size in
                Text("proposed: \(size.width)×\(size.height)")
                    .foreground(.magenta)
            }
            .frame(height: 2)

        // ───── Primitives ─────
        case .text:
            VStack {
                Text("plain")
                Text("bold").bold()
                Text("colored").foreground(.green)
                Text("both").bold().foreground(.red)
            }
        case .forEach:
            HStack {
                ForEachWithID(Array(["red", "yellow", "green", "cyan", "magenta"]), id: \.self) { name in
                    Text("[\(name)]").foreground(.cyan)
                    Text(" ")
                }
            }

        // ───── Input ─────
        case .button:
            VStack {
                Button("OK") { state.buttonMessage = "OK clicked" }
                Button("Cancel") { state.buttonMessage = "Cancel clicked" }
                Text("→ \(state.buttonMessage)").foreground(.gray)
            }
        case .textInput:
            VStack {
                TextInput(text: Binding(get: { state.textInputValue },
                                         set: { state.textInputValue = $0 }),
                          placeholder: "type an email...",
                          validate: { value in
                              if value.isEmpty { return .ok }
                              return value.contains("@")
                                  ? .ok
                                  : TextInputValidation(.error, "missing @")
                          })
                Text("→ \(state.textInputValue)").foreground(.gray)
            }
        case .textArea:
            TextArea(text: Binding(get: { state.textAreaContent },
                                     set: { state.textAreaContent = $0 }),
                     state: Binding(get: { state.textAreaState },
                                      set: { state.textAreaState = $0 }),
                     lineNumbers: true,
                     visibleHeight: 6)
        case .toggle:
            VStack {
                Toggle("enabled",
                       isOn: Binding(get: { state.toggleValue },
                                      set: { state.toggleValue = $0 }))
                Text("→ \(state.toggleValue ? "on" : "off")").foreground(.gray)
            }
        case .promptInput:
            VStack {
                PromptInput(
                    text: Binding(get: { state.promptValue },
                                   set: { state.promptValue = $0 }),
                    state: Binding(get: { state.promptState },
                                    set: { state.promptState = $0 }),
                    onSubmit: { submitted in
                        state.promptSubmitted = submitted
                        state.promptValue = ""
                    })
                Text("last submitted: \(state.promptSubmitted)").foreground(.gray)
            }

        // ───── Display ─────
        case .list:
            List(Array(demoItems),
                 selection: Binding(get: { state.listSelection },
                                    set: { state.listSelection = $0 }),
                 scroll: Binding(get: { state.listScroll },
                                 set: { state.listScroll = $0 }),
                 visibleCount: 5) { item in
                Text(item.label).foreground(item.color)
            }
        case .table:
            Table(Array(demoItems), columns: [
                TableColumn("Name") { $0.label },
                TableColumn("Color") { "\($0.color)" },
            ])
        case .tabView:
            TabView(selection: Binding(get: { state.tabSelection },
                                        set: { state.tabSelection = $0 })) {
                Tab("First") { Text("first page content") }
                Tab("Second") { Text("second page content") }
                Tab("Third") { Text("third page content") }
            }
            .frame(height: 6)
        case .treeView:
            TreeView(
                demoTreeRoots,
                children: \.children,
                selection: Binding(get: { state.treeSelection },
                                    set: { state.treeSelection = $0 }),
                visibleCount: 8) { node in
                Text(node.label)
            }
        case .diffView:
            DiffView(original: "hello\nworld",
                     modified: "hello\nswift world")
                .frame(height: 6)
        case .hunkDiffView:
            HunkDiffView(
                hunks: demoHunks,
                fileName: state.hunkFileName,
                visibleCount: 8)
        case .progressBar:
            VStack {
                ProgressBar(value: 0.25, label: "25%")
                ProgressBar(value: 0.50, label: "50%")
                ProgressBar(value: 0.75, label: "75%")
                ProgressBar(value: 1.00, label: "done")
            }
        case .statusBar:
            VStack {
                Text("(above-bar content)")
                Spacer()
                StatusBar {
                    StatusBar.Section(.left) {
                        TextSpan("READY", bold: true)
                    }
                    StatusBar.Section(.center) {
                        TextSpan("tab:1/3")
                    }
                    StatusBar.Section(.right) {
                        TextSpan("0.2ms", foreground: .green)
                    }
                }
            }
            .frame(height: 5)

        // ───── Charts ─────
        case .barChart:
            BarChart(items: [
                BarChart.Item(label: "A", value: 3),
                BarChart.Item(label: "B", value: 7),
                BarChart.Item(label: "C", value: 4),
                BarChart.Item(label: "D", value: 9),
                BarChart.Item(label: "E", value: 2),
            ], barWidth: 20)
        case .sparkline:
            Sparkline(data: sineData, width: 40, height: 4, min: -1, max: 1)
        case .heatMap:
            HeatMap(data: heatData)
        case .brailleCanvas:
            // BrailleCanvas is a helper — build it, render to a String,
            // then wrap in Text. This keeps the preview declarative.
            Text(buildBrailleDemo()).foreground(.cyan)
        case .dotMatrixText:
            DotMatrixText("HELLO")
        case .morseTicker:
            MorseTicker("SOS",
                        scrollOffset: Binding(get: { state.morseScroll },
                                               set: { state.morseScroll = $0 }),
                        width: 40)

        // ───── Modifiers ─────
        case .foreground:
            HStack {
                Text("red").foreground(.red)
                Text(" ")
                Text("green").foreground(.green)
                Text(" ")
                Text("blue").foreground(.blue)
            }
        case .bold:
            VStack {
                Text("not bold")
                Text("is bold").bold()
            }
        case .border:
            Text(" bordered ").border()
        case .padding:
            Text("padded").padding()
        case .focusable:
            Text("press Tab to focus me").focusable()
        case .frame:
            Text("x").frame(width: 10, height: 3).border()
        }
    }
}

// MARK: - Demo data shared across pages

struct DemoItem: Identifiable {
    let id: Int
    let label: String
    let color: Color
}

let demoItems: [DemoItem] = [
    .init(id: 0, label: "alpha",   color: .red),
    .init(id: 1, label: "beta",    color: .yellow),
    .init(id: 2, label: "gamma",   color: .green),
    .init(id: 3, label: "delta",   color: .cyan),
    .init(id: 4, label: "epsilon", color: .magenta),
    .init(id: 5, label: "zeta",    color: .blue),
    .init(id: 6, label: "eta",     color: .white),
    .init(id: 7, label: "theta",   color: .gray),
]

let sineData: [Double] = (0..<40).map { i in
    sin(Double(i) * 0.4)
}

let heatData: [[Double]] = (0..<5).map { r in
    (0..<20).map { c in
        sin(Double(r) * 0.5) * cos(Double(c) * 0.3) * 0.5 + 0.5
    }
}

// TreeView demo data
struct TreeNode: Identifiable {
    let id: Int
    let label: String
    let children: [TreeNode]?
}

let demoTreeRoots: [TreeNode] = [
    TreeNode(id: 1, label: "Sources", children: [
        TreeNode(id: 2, label: "TerminalUI", children: [
            TreeNode(id: 3, label: "Views", children: [
                TreeNode(id: 4, label: "Text.swift", children: nil),
                TreeNode(id: 5, label: "VStack.swift", children: nil),
            ]),
            TreeNode(id: 6, label: "Core", children: nil),
        ]),
    ]),
    TreeNode(id: 7, label: "Tests", children: [
        TreeNode(id: 8, label: "TerminalUITests", children: nil),
    ]),
]

// HunkDiffView demo data
let demoHunks: [HunkDiff.Hunk] = [
    HunkDiff.Hunk(oldStart: 1, newStart: 1, lines: [
        HunkDiff.Line(type: .context, content: "import Foundation", oldLineNo: 1, newLineNo: 1),
        HunkDiff.Line(type: .remove, content: "let x = 1", oldLineNo: 2, newLineNo: nil),
        HunkDiff.Line(type: .add, content: "let x = 42", oldLineNo: nil, newLineNo: 2),
        HunkDiff.Line(type: .context, content: "print(x)", oldLineNo: 3, newLineNo: 3),
    ]),
]

// BrailleCanvas demo — a sine wave plotted at sub-pixel density.
func buildBrailleDemo() -> String {
    var canvas = BrailleCanvas(width: 40, height: 6)
    let w = 40 * 2          // canvas dot width
    let h = 6 * 4           // canvas dot height
    for x in 0..<w {
        let t = Double(x) / Double(w) * Double.pi * 4
        let y = Int((sin(t) + 1) / 2 * Double(h - 1))
        canvas.set(x: x, y: y)
    }
    return canvas.render()
}
