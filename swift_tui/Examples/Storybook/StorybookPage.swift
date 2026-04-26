import TerminalUI

// MARK: - Page metadata

/// Description of a single Storybook page. Pure data — the actual preview
/// is rendered by `PageDetail` via a switch on `id`. This keeps type erasure
/// out of the picture (TerminalView's `some TerminalView` constraint forbids
/// clean `any TerminalView` erasure anyway).
struct PageInfo: Identifiable, Sendable {
    let id: PageID
    let category: Category
    let name: String
    let summary: String
    let code: String

    enum Category: String, Sendable, CaseIterable, Hashable {
        case layout = "Layout"
        case primitives = "Primitives"
        case input = "Input"
        case display = "Display"
        case charts = "Charts"
        case modifiers = "Modifiers"
    }
}

/// Stable identifier for each page — used by `PageDetail` to pick the
/// concrete preview view. Adding a component = add a case here + a switch
/// arm in PageDetail + an entry in `allPages`.
enum PageID: String, Sendable, Hashable, CaseIterable {
    // Layout
    case vstack, hstack, zstack, spacer, divider, scrollview, geometryreader
    // Primitives
    case text, forEach
    // Input
    case button, textInput, textArea, toggle, promptInput
    // Display
    case list, table, tabView, treeView, diffView, hunkDiffView, progressBar, statusBar, bufferView
    // Charts
    case barChart, sparkline, heatMap, brailleCanvas, dotMatrixText, morseTicker
    // Modifiers
    case foreground, bold, border, padding, focusable, frame, onHover, mouseFocusPolicy

    // The `code` string must reproduce the exact `PreviewPane` output.
    // Paste-and-run contract: if it doesn't match the preview, it's a bug.
    var info: PageInfo {
        switch self {
        // ───── Layout ─────
        case .vstack: return PageInfo(id: self, category: .layout, name: "VStack",
            summary: "Stack children vertically.",
            code: """
                VStack {
                    Text("row 1").foreground(.red)
                    Text("row 2").foreground(.yellow)
                    Text("row 3").foreground(.green)
                }
                """)
        case .hstack: return PageInfo(id: self, category: .layout, name: "HStack",
            summary: "Stack children horizontally.",
            code: """
                HStack {
                    Text("A").foreground(.red)
                    Text("|").foreground(.gray)
                    Text("B").foreground(.green)
                    Text("|").foreground(.gray)
                    Text("C").foreground(.blue)
                }
                """)
        case .zstack: return PageInfo(id: self, category: .layout, name: "ZStack",
            summary: "Layer children on top of each other. Later children draw over earlier ones.",
            code: """
                ZStack {
                    Text("◼◼◼◼◼◼◼◼◼◼\\n◼◼◼◼◼◼◼◼◼◼\\n◼◼◼◼◼◼◼◼◼◼")
                        .foreground(.ansi256(238))
                    Text(" OVER ").foreground(.cyan).bold()
                }
                """)
        case .spacer: return PageInfo(id: self, category: .layout, name: "Spacer",
            summary: "Flexible empty space that consumes available axis room.",
            code: """
                HStack {
                    Text("[left]").foreground(.yellow)
                    Spacer()
                    Text("[right]").foreground(.yellow)
                }
                """)
        case .divider: return PageInfo(id: self, category: .layout, name: "Divider",
            summary: "Horizontal rule separator.",
            code: """
                VStack {
                    Text("above")
                    Divider()
                    Text("below")
                }
                """)
        case .scrollview: return PageInfo(id: self, category: .layout, name: "ScrollView",
            summary: "Scrollable viewport for content taller or wider than the container.",
            code: """
                ScrollView(.vertical) {
                    VStack {
                        ForEachWithID(Array(0..<20), id: \\.self) { i in
                            Text("row \\(i)")
                                .foreground(i % 2 == 0 ? .cyan : .default)
                        }
                    }
                }
                .frame(height: 6)
                """)
        case .geometryreader: return PageInfo(id: self, category: .layout, name: "GeometryReader",
            summary: "Reads its proposed size; lets children adapt to available space.",
            code: """
                GeometryReader { size in
                    Text("proposed: \\(size.width)×\\(size.height)")
                        .foreground(.magenta)
                }
                .frame(height: 2)
                """)

        // ───── Primitives ─────
        case .text: return PageInfo(id: self, category: .primitives, name: "Text",
            summary: "Styled text — bold, foreground, italic, per-character spans.",
            code: """
                VStack {
                    Text("plain")
                    Text("bold").bold()
                    Text("colored").foreground(.green)
                    Text("both").bold().foreground(.red)
                }
                """)
        case .forEach: return PageInfo(id: self, category: .primitives, name: "ForEach",
            summary: "Render a view per element of a collection. Identifiable data uses ForEach; use ForEachWithID for non-Identifiable.",
            code: """
                HStack {
                    ForEachWithID(
                        Array(["red","yellow","green","cyan","magenta"]),
                        id: \\.self
                    ) { name in
                        Text("[\\(name)]").foreground(.cyan)
                        Text(" ")
                    }
                }
                """)

        // ───── Input ─────
        case .button: return PageInfo(id: self, category: .input, name: "Button",
            summary: "Clickable action. Enter/Space activate when focused.",
            code: """
                @Observable final class S { var msg = "(nothing yet)" }
                let s = S()

                VStack {
                    Button("OK")     { s.msg = "OK clicked" }
                    Button("Cancel") { s.msg = "Cancel clicked" }
                    Text("→ \\(s.msg)").foreground(.gray)
                }
                """)
        case .textInput: return PageInfo(id: self, category: .input, name: "TextInput",
            summary: "Single-line text field. Add `validate:` to colour the box and surface a warning when the value fails validation.",
            code: """
                VStack {
                    TextInput(text: $value, placeholder: "type an email...",
                              validate: { v in
                                  v.isEmpty || v.contains("@")
                                      ? .ok
                                      : TextInputValidation(.error, "missing @")
                              })
                    Text("→ \\(value)").foreground(.gray)
                }
                """)
        case .textArea: return PageInfo(id: self, category: .input, name: "TextArea",
            summary: "Multi-line text editor with cursor and selection.",
            code: """
                TextArea(text: $content,
                         state: $editorState,
                         lineNumbers: true,
                         visibleHeight: 6)
                """)
        case .toggle: return PageInfo(id: self, category: .input, name: "Toggle",
            summary: "Boolean on/off switch. Space toggles when focused.",
            code: """
                VStack {
                    Toggle("enabled", isOn: $flag)
                    Text("→ \\(flag ? "on" : "off")").foreground(.gray)
                }
                """)
        case .promptInput: return PageInfo(id: self, category: .input, name: "PromptInput",
            summary: "Chat-style input. Enter submits; Option/Shift+Enter = newline.",
            code: """
                VStack {
                    PromptInput(
                        text: $value,
                        state: $promptState,
                        onSubmit: { submitted in
                            lastSubmitted = submitted
                            value = ""
                        })
                    Text("last submitted: \\(lastSubmitted)")
                        .foreground(.gray)
                }
                """)

        // ───── Display ─────
        case .list: return PageInfo(id: self, category: .display, name: "List",
            summary: "Scrollable, selectable list of items.",
            code: """
                List(Array(items),
                     selection: $selectedID,
                     scroll: $scrollOffset,
                     visibleCount: 5) { item in
                    Text(item.label).foreground(item.color)
                }
                """)
        case .table: return PageInfo(id: self, category: .display, name: "Table",
            summary: "Tabular data with columns.",
            code: """
                Table(Array(items), columns: [
                    TableColumn("Name")  { $0.label },
                    TableColumn("Color") { "\\($0.color)" },
                ])
                """)
        case .tabView: return PageInfo(id: self, category: .display, name: "TabView",
            summary: "Multiple pages selected via a tab bar.",
            code: """
                TabView(selection: $tab) {
                    Tab("First")  { Text("first page content") }
                    Tab("Second") { Text("second page content") }
                    Tab("Third")  { Text("third page content") }
                }
                .frame(height: 6)
                """)
        case .treeView: return PageInfo(id: self, category: .display, name: "TreeView",
            summary: "Collapsible hierarchical tree. Node type must be Identifiable, with a key path to an optional children collection.",
            code: """
                TreeView(
                    roots,
                    children: \\.children,
                    selection: $selection,
                    visibleCount: 8
                ) { node in
                    Text(node.label)
                }
                """)
        case .diffView: return PageInfo(id: self, category: .display, name: "DiffView",
            summary: "Line-level diff viewer (unified or side-by-side).",
            code: """
                DiffView(original: "hello\\nworld",
                         modified: "hello\\nswift world")
                    .frame(height: 6)
                """)
        case .hunkDiffView: return PageInfo(id: self, category: .display, name: "HunkDiffView",
            summary: "GitHub-style hunk review with selection + comments.",
            code: """
                HunkDiffView(
                    hunks: hunks,
                    fileName: "example.swift",
                    visibleCount: 8)
                """)
        case .progressBar: return PageInfo(id: self, category: .display, name: "ProgressBar",
            summary: "Determinate progress indicator.",
            code: """
                VStack {
                    ProgressBar(value: 0.25, label: "25%")
                    ProgressBar(value: 0.50, label: "50%")
                    ProgressBar(value: 0.75, label: "75%")
                    ProgressBar(value: 1.00, label: "done")
                }
                """)
        case .statusBar: return PageInfo(id: self, category: .display, name: "StatusBar",
            summary: "Fixed bottom bar with sections separated by dividers.",
            code: """
                VStack {
                    Text("(above-bar content)")
                    Spacer()
                    StatusBar {
                        StatusBar.Section(.left)   { TextSpan("READY", bold: true) }
                        StatusBar.Section(.center) { TextSpan("tab:1/3") }
                        StatusBar.Section(.right)  { TextSpan("0.2ms",
                                                               foreground: .green) }
                    }
                }
                .frame(height: 5)
                """)

        // ───── Charts ─────
        case .barChart: return PageInfo(id: self, category: .charts, name: "BarChart",
            summary: "Vertical bar chart for labeled scalar data.",
            code: """
                BarChart(items: [
                    BarChart.Item(label: "A", value: 3),
                    BarChart.Item(label: "B", value: 7),
                    BarChart.Item(label: "C", value: 4),
                    BarChart.Item(label: "D", value: 9),
                    BarChart.Item(label: "E", value: 2),
                ], barWidth: 20)
                """)
        case .sparkline: return PageInfo(id: self, category: .charts, name: "Sparkline",
            summary: "Inline mini line chart for trends.",
            code: "Sparkline(data: sineData, width: 40, height: 4, min: -1, max: 1)")
        case .heatMap: return PageInfo(id: self, category: .charts, name: "HeatMap",
            summary: "2D grid visualization with color scale.",
            code: "HeatMap(data: heatData)")
        case .brailleCanvas: return PageInfo(id: self, category: .charts, name: "BrailleCanvas",
            summary: "Sub-pixel pixel-art canvas via 2×4 braille dots. Not a view — it renders to a String you wrap in Text.",
            code: """
                var canvas = BrailleCanvas(width: 40, height: 6)
                for x in 0..<(40 * 2) {
                    let t = Double(x) / Double(40 * 2) * .pi * 4
                    let y = Int((sin(t) + 1) / 2 * Double(6 * 4 - 1))
                    canvas.set(x: x, y: y)
                }
                Text(canvas.render()).foreground(.cyan)
                """)
        case .dotMatrixText: return PageInfo(id: self, category: .charts, name: "DotMatrixText",
            summary: "Large text rendered as dot-matrix LED panels.",
            code: "DotMatrixText(\"HELLO\")")
        case .morseTicker: return PageInfo(id: self, category: .charts, name: "MorseTicker",
            summary: "Animated Morse code signal visualizer.",
            code: "MorseTicker(\"SOS\", scrollOffset: $offset, width: 40)")

        // ───── Modifiers ─────
        case .foreground: return PageInfo(id: self, category: .modifiers, name: ".foreground",
            summary: "Set the foreground color.",
            code: """
                HStack {
                    Text("red").foreground(.red)
                    Text(" ")
                    Text("green").foreground(.green)
                    Text(" ")
                    Text("blue").foreground(.blue)
                }
                """)
        case .bold: return PageInfo(id: self, category: .modifiers, name: ".bold",
            summary: "Render text in bold.",
            code: """
                VStack {
                    Text("not bold")
                    Text("is bold").bold()
                }
                """)
        case .border: return PageInfo(id: self, category: .modifiers, name: ".border",
            summary: "Draw a border around the view.",
            code: "Text(\" bordered \").border()")
        case .padding: return PageInfo(id: self, category: .modifiers, name: ".padding",
            summary: "Add empty space around the view.",
            code: "Text(\"padded\").padding()")
        case .focusable: return PageInfo(id: self, category: .modifiers, name: ".focusable",
            summary: "Participate in Tab-order focus navigation.",
            code: "Text(\"press Tab to focus me\").focusable()")
        case .frame: return PageInfo(id: self, category: .modifiers, name: ".frame",
            summary: "Constrain size via width/height/min/max.",
            code: "Text(\"x\").frame(width: 10, height: 3).border()")
        case .onHover: return PageInfo(id: self, category: .modifiers, name: ".onHover",
            summary: "SwiftUI-style hover callback. Fires true on rect enter, false on leave; intra-rect movement does NOT re-fire.",
            code: """
                Text("hover me")
                    .onHover { isHovering in
                        state.hoverIndicator = isHovering ? "yes" : "no"
                    }
                """)
        case .mouseFocusPolicy: return PageInfo(id: self, category: .modifiers, name: ".mouseFocusPolicy",
            summary: "Pick how mouse events steer keyboard focus per subtree. Four cases: .clickToLock (default), .hoverFollows, .clickOnly, .disabled.",
            code: """
                VStack {
                    Text("outer — default policy")
                    Text("inner — disabled")
                }
                .mouseFocusPolicy(.disabled)
                """)
        case .bufferView: return PageInfo(id: self, category: .display, name: "BufferView",
            summary: "Render a pre-populated CellBuffer into the view's rect. SwiftUI analog: Image(decorative:).",
            code: """
                var buffer = CellBuffer(width: 20, height: 4)
                buffer.write("Hello, world!", x: 0, y: 0, style: ...)
                BufferView(buffer)
                """)
        }
    }
}

/// Registry: every page in display order. Grouped by category.
/// Adding a component = add a case to `PageID` + a switch arm in `PageDetail`.
enum Storybook {
    static let allPages: [PageID] = PageID.allCases
}
