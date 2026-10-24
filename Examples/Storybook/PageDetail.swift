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
            // within. Still wants a visible scrollbar affordance.
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
        WidthReader { width in
            // Reserve 4 cells for the PageDetail-applied border+padding.
            let maxWidth = max(20, width - 4)
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
        case .alignment:
            VStack(spacing: 1) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("one").foreground(.cyan)
                    Text("three").foreground(.cyan)
                }
                HStack(alignment: .bottom, spacing: 2) {
                    Text("tall\nrows\nhere").foreground(.gray)
                    Text("bottom").foreground(.yellow)
                }
                Text("centred").frame(width: 18, height: 3, alignment: .center).border()
                Text("....\n....").foreground(.gray)
                    .overlay(alignment: .topTrailing) { Text("*").foreground(.magenta).bold() }
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
            .scrollable()
            .frame(height: 6)
        case .geometryreader:
            GeometryReader { size in
                Text("proposed: \(size.width)×\(size.height)")
                    .foreground(.magenta)
            }
            .frame(height: 2)
        case .widthReader:
            VStack(spacing: 0) {
                WidthReader { width in
                    Text("width \(width): a sentence long enough to wrap onto more than one row, "
                         + "so the reader's height comes from its content at this width.")
                        .foreground(.magenta)
                }
                Text("— this line follows the wrapped text —").foreground(.gray)
            }
        case .splitView:
            SplitView(state: state.splitState)
                .frame(height: 6)

        // ───── Primitives ─────
        case .text:
            VStack {
                Text("plain")
                Text("bold").bold()
                Text("colored").foreground(.green)
                Text("both").bold().foreground(.red)
            }
        case .gradient:
            VStack {
                Text.gradient("TERMINAL UI", from: .rgb(124, 92, 255), to: .rgb(61, 219, 217)).bold()
                Text.gradient(String(repeating: "╱", count: 28),
                              from: .rgb(124, 92, 255), to: .rgb(36, 35, 48))
                Text.gradient("▶▶▶▶▶▶▶▶▶▶", through: [
                    .rgb(255, 122, 198), .rgb(124, 92, 255), .rgb(61, 219, 217),
                ])
            }
        case .forEach:
            HStack {
                ForEachWithID(Array(["red", "yellow", "green", "cyan", "magenta"]), id: \.self) { name in
                    Text("[\(name)]").foreground(.cyan)
                    Text(" ")
                }
            }
        case .subCell:
            // Show one glyph per major case so the visual atlas is
            // immediate. Cases left out (eighthVertical other levels,
            // braille, full quadrant set) are documented in the code
            // string for the user to copy-paste.
            VStack {
                Text("Full / halves / quadrants:")
                HStack {
                    Text(String(SubCellGlyph.full.character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.halfTop.character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.halfBottom.character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.halfLeft.character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.halfRight.character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.quadrant([.topLeft, .bottomRight]).character)).foreground(.cyan)
                    Text(" ")
                    Text(String(SubCellGlyph.quadrant([.topRight, .bottomLeft]).character)).foreground(.cyan)
                }
                Text(" ")
                Text("Eighths (vertical fill):")
                HStack {
                    Text(String(SubCellGlyph.eighthVertical(.oneEighth).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.twoEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.threeEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.fourEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.fiveEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.sixEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.sevenEighths).character)).foreground(.green)
                    Text(String(SubCellGlyph.eighthVertical(.eightEighths).character)).foreground(.green)
                }
                Text(" ")
                Text("Shades:")
                HStack {
                    Text(String(SubCellGlyph.shade(.light).character)).foreground(.yellow)
                    Text(" ")
                    Text(String(SubCellGlyph.shade(.medium).character)).foreground(.yellow)
                    Text(" ")
                    Text(String(SubCellGlyph.shade(.dark).character)).foreground(.yellow)
                }
            }
        case .timeline:
            // Timeline is observable; the running ticker reads
            // `state.timelineFrame` which the StorybookApp advances
            // via TerminalTimer. Without that wiring the page still
            // renders — just shows frame 0 statically.
            VStack {
                Text("FrameTimeline (frames=8, fps=10):").foreground(.gray)
                HStack {
                    let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"]
                    Text(frames[state.timelineFrame % frames.count]).foreground(.cyan)
                    Text(" frame=\(state.timelineFrame % 8)").foreground(.gray)
                }
                Text(" ")
                Text("CurveTimeline (.easeInOut, fixed sample at 0.5):").foreground(.gray)
                Text("progress=\(AnimationCurve.easeInOut.apply(0.5))").foreground(.green)
                Text("(linear=0.50, easeIn=0.25, easeOut=0.75, easeInOut=0.50)")
                    .foreground(.gray)
            }
        case .asyncTask:
            AsyncTaskDemo()
        case .capabilities:
            // Read the framework-level singleton.
            let caps = Runtime.capabilities
            VStack {
                Text("Detected graphics protocol:").foreground(.gray)
                Text(String(describing: caps.graphics)).foreground(.cyan).bold()
                Text(" ")
                Text("Detection log:").foreground(.gray)
                ForEachWithID(caps.detectionLog, id: \.probe) { step in
                    Text("• \(step.probe): \(step.result)")
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
        case .picker:
            Picker("Theme",
                   selection: Binding(get: { state.pickerTheme },
                                       set: { state.pickerTheme = $0 })) {
                ForEach(StorybookTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        case .slider:
            Slider(value: Binding(get: { state.sliderVolume },
                                   set: { state.sliderVolume = $0 }),
                   in: 0...100, step: 5, label: "Volume")
        case .stepper:
            Stepper("Tab width",
                    value: Binding(get: { state.stepperTabWidth },
                                    set: { state.stepperTabWidth = $0 }),
                    in: 1...16)
        case .gauge:
            Gauge(value: 0.62, label: "Disk")
        case .form:
            Form {
                Section("Appearance") {
                    Picker("Theme",
                           selection: Binding(get: { state.pickerTheme },
                                               set: { state.pickerTheme = $0 })) {
                        ForEach(StorybookTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Dark mode", isOn: Binding(get: { state.formDark },
                                                       set: { state.formDark = $0 }))
                }
                Section("Editor") {
                    Stepper("Tab width",
                            value: Binding(get: { state.stepperTabWidth },
                                            set: { state.stepperTabWidth = $0 }),
                            in: 1...16)
                    Slider(value: Binding(get: { state.formFontScale },
                                           set: { state.formFontScale = $0 }),
                           in: 0.5...2.0, step: 0.1, label: "Font scale")
                }
                Section("Privacy") {
                    Toggle("Telemetry", isOn: Binding(get: { state.formTelemetry },
                                                        set: { state.formTelemetry = $0 }))
                    Toggle("Crash reports", isOn: Binding(get: { state.formCrashReports },
                                                            set: { state.formCrashReports = $0 }))
                }
                Section("Advanced") {
                    Toggle("Autosave", isOn: Binding(get: { state.formAutosave },
                                                       set: { state.formAutosave = $0 }))
                    Stepper("History depth",
                            value: Binding(get: { state.formHistoryDepth },
                                            set: { state.formHistoryDepth = $0 }),
                            in: 5...100, step: 5)
                }
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    Gauge(value: 0.62, label: "Disk")
                }
            }
            // A settings screen is taller than its window — that is this
            // page's subject. Left to itself the form would split the detail
            // column's leftover rows with the trailing spacer and land on a
            // window too short to read; a fixed one keeps the demo legible.
            // An app gives its Form the screen instead.
            .frame(height: 10)
        case .navigationStack:
            NavigationStack(path: Binding(get: { state.navPath },
                                           set: { state.navPath = $0 })) {
                VStack {
                    Text("Pick a section").foreground(.gray)
                    NavigationLink(value: NavItem(id: 1, name: "Fruits", kind: .section)) {
                        Text("Fruits")
                    }
                    NavigationLink(value: NavItem(id: 2, name: "Veg", kind: .section)) {
                        Text("Vegetables")
                    }
                }
                .navigationTitle("Sections")
            }
            .navigationDestination(for: NavItem.self) { item in
                switch item.kind {
                case .section:
                    VStack {
                        Text("Items in \(item.name)").foreground(.gray)
                        NavigationLink(value: NavItem(id: item.id * 10, name: "\(item.name) A", kind: .item)) {
                            Text("\(item.name) A")
                        }
                        NavigationLink(value: NavItem(id: item.id * 10 + 1, name: "\(item.name) B", kind: .item)) {
                            Text("\(item.name) B")
                        }
                    }
                    .navigationTitle(item.name)
                case .item:
                    VStack {
                        Text("Detail of \(item.name)").bold()
                        NavigationLink(value: NavItem(id: item.id * 10, name: "\(item.name) note", kind: .detail)) {
                            Text("More")
                        }
                    }
                    .navigationTitle(item.name)
                case .detail:
                    Text("\(item.name) — Esc to go back")
                        .navigationTitle(item.name)
                }
            }
        case .promptInput:
            VStack {
                PromptInput(
                    text: Binding(get: { state.promptValue },
                                   set: { state.promptValue = $0 }),
                    state: Binding(get: { state.promptState },
                                    set: { state.promptState = $0 }),
                    placeholder: "Ask anything",
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
            VStack(spacing: 1) {
                DotMatrixText("HELLO")
                DotMatrixText("HELLO", mode: .halfBlock)
                    .gradient(from: .rgb(124, 92, 255), to: .rgb(61, 219, 217))
            }
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
        case .theme:
            VStack {
                Toggle("loud",
                       isOn: Binding(get: { state.loudTheme },
                                      set: { state.loudTheme = $0 }))
                Button("Save") { state.buttonMessage = "themed" }
                Button("Disabled") {}.disabled()
                StorybookSwatch()
            }
            .environment(\.theme, state.loudTheme ? StorybookLoudTheme() as any Theme : DefaultTheme())
        case .border:
            Text(" bordered ").border()
        case .borderEdges:
            VStack(spacing: 1) {
                Text("tinted frame, plain text").border(.rounded, color: .cyan)
                Text("leading rail").border(.heavy, color: .magenta, edges: .leading)
                Text("rule above").border(.rounded, color: .green, edges: .top)
                Text("both rails").border(.rounded, color: .yellow, edges: .horizontal)
                Text("half blocks").border(.halfBlock, color: .cyan)
                Text("thick rail").border(.halfBlock, color: .magenta, edges: .leading)
            }
        case .padding:
            VStack(spacing: 0) {
                Text("all sides").padding().border()
                Text("leading only").padding(.leading, 2).border()
                Text("rail, then room")
                    .padding(.leading, 1)
                    .border(.heavy, color: .magenta, edges: .leading)
                Text("insets").padding(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 1)).border()
            }
        case .truncate:
            VStack {
                Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.tail))
                Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.head))
                Text("Sources/Rendering/Compositor.swift").wrap(.truncate(.middle))
            }
            .frame(width: 24)
        case .focusable:
            VStack {
                StorybookChoice(title: "press Tab to focus me").focusable()
                StorybookChoice(title: "then me").focusable()
            }
        case .frame:
            Text("x").frame(width: 10, height: 3).border()
        case .flexible:
            VStack {
                Text("HStack: fixed | flex 1 | flex 2").foreground(.cyan)
                HStack {
                    Text("fixed").border()
                    Text("flex 1").flexible(.horizontal).border()
                    Text("flex 2").flexible(grow: 2).border()
                }
                Text("Sidebar (28) + content fills remainder").foreground(.cyan)
                HStack {
                    Text("sidebar").frame(width: 14).border()
                    Text("content fills remainder")
                        .frame(maxWidth: .infinity)
                        .border()
                }
            }
        case .onHover:
            VStack {
                Text("hover this row").foreground(.cyan)
                    .onHover { [state] isHovering in
                        state.hoverIndicator = isHovering ? "hovering" : "left"
                    }
                Text("hover indicator: \(state.hoverIndicator)").foreground(.gray)
            }
        case .mouseFocusPolicy:
            VStack {
                Text("Outer subtree — default .clickToLock").foreground(.green)
                    .focusable()
                VStack {
                    Text("Inner subtree — .disabled").foreground(.yellow)
                        .focusable()
                }.mouseFocusPolicy(.disabled)
                Text("(hover both — only the outer reports hover state)").foreground(.gray)
            }
        case .markdown:
            MarkdownView("""
                ## What changed

                1. Give the skip its **own flag**
                2. Leave `previousBuffer` meaning one thing

                > The buffer carried two meanings.

                ```swift
                if skippedFrame { return .unchanged }
                ```
                """)
        case .codeView:
            CodeView("""
                    /// Present the frame, or nothing when the loop skipped it.
                    func flush(_ buffer: CellBuffer) -> FrameResult {
                        if skippedFrame { return .unchanged }
                        guard let previous = previousBuffer else {
                            return .fullRepaint(buffer, reason: "first frame, so there is nothing to diff against")
                        }
                        return diff(previous, buffer)
                    }
                    """, language: "swift", lineNumbers: true, firstLineNumber: 305)
                .wrap(.truncate(.tail))
        case .bufferView:
            BufferView(buildBufferDemo())
                .frame(width: 24, height: 4)
                .border()
        case .actions:
            VStack {
                Text("Tab here, then press Ctrl+P to fire the action").foreground(.cyan)
                Text("counter: \(state.actionFired)").foreground(.gray)
            }
            .focusable()
            .actions {
                Action(
                    id: "storybook.demo.fire",
                    title: .literal("Fire Demo Action"),
                    perform: { fireStorybookAction() }
                )
                .bound(to: .keyboard(.character("p"), [.ctrl]))
            }
        case .keyChord:
            VStack {
                Text("Same chord, four styles:").foreground(.gray)
                Text(" automatic (this OS): \(KeyChord(.character("r"), [.alt]).formatted())")
                Text(" symbolic (Mac):      \(KeyChord(.character("r"), [.alt]).formatted(.symbolic))")
                Text(" named (Linux):       \(KeyChord(.character("r"), [.alt]).formatted(.named))")
                Text(" multiple modifiers:")
                Text("    symbolic: \(KeyChord(.tab, [.ctrl, .shift]).formatted(.symbolic))")
                Text("    named:    \(KeyChord(.tab, [.ctrl, .shift]).formatted(.named))")
                Text(" special keys:")
                Text("    \(KeyChord(.escape, []).formatted(.symbolic)) / \(KeyChord(.escape, []).formatted(.named))")
                Text("    \(KeyChord(.enter, []).formatted(.symbolic)) / \(KeyChord(.enter, []).formatted(.named))")
            }
        case .actionContext:
            // Two-pane resize demo: a real container whose shared
            // boundary moves when L / H fire in resize mode. Widths
            // are computed from the rect GeometryReader hands us, so
            // the children always fit inside the available preview
            // pane (no overflow, no escape leak — the previous attempt
            // overflowed because it used fixed widths that didn't
            // account for the parent's actual size).
            VStack {
                Text("Tab here.").foreground(.cyan)
                Text("\(KeyChord(.character("r"), [.ctrl]).formatted()) → enter resize mode  ·  L grows left  ·  H grows right  ·  Esc exits")
                    .foreground(.gray)
                Text("mode: \(state.currentMode.current ?? "default")")
                    .foreground(.yellow).bold()
                // SplitView is purpose-built for this — it honors
                // explicit per-child ratios in its layout phase, so
                // the visible boundary tracks `actionContextLeftFraction`
                // exactly. (HStack with `.frame(width:)` doesn't honor
                // proposed widths inside flex distribution.)
                // Each leaf is bordered so the boundary slide moves
                // visible rectangle edges, not just text.
                SplitView(state: state.actionContextSplit)
                    .frame(height: 5)
                // Discoverability banner. Apple Terminal.app and iTerm2
                // default to using Option as a compose key, so demos
                // built around Option-modified bindings silently break
                // out of the box. We chose Ctrl above to sidestep that;
                // this row teaches users how to enable Option-as-Meta
                // if they want their own apps to use ⌥-chords.
                Text("Note: ⌥ chords need Option-as-Meta — Terminal.app: Settings → Profiles → Keyboard → Use Option as Meta key. iTerm2: Settings → Profiles → Keys → Left/Right Option = Esc+. Kitty: on by default.")
                    .foreground(.gray)
            }
            .focusable()
            .environment(\.actionContext, state.currentMode)
            .actions {
                Action(
                    id: "storybook.context.enter",
                    title: .literal("Enter / Exit Resize Mode"),
                    perform: { enterResizeMode() }
                )
                .bound(to: .keyboard(.character("r"), [.ctrl]))
                Action(
                    id: "storybook.context.grow",
                    title: .literal("Grow Left Pane"),
                    perform: { growLeftPane() }
                )
                .bound(to: .keyboard(.character("l"), []), whenContext: "resize")
                Action(
                    id: "storybook.context.shrink",
                    title: .literal("Shrink Left Pane"),
                    perform: { shrinkLeftPane() }
                )
                .bound(to: .keyboard(.character("h"), []), whenContext: "resize")
                Action(
                    id: "storybook.context.exit",
                    title: .literal("Exit Resize Mode"),
                    perform: { exitResizeMode() }
                )
                .bound(to: .keyboard(.escape, []), whenContext: "resize")
            }
        case .disabled:
            VStack {
                Text("Tab cycles only Live; Dead is skipped").foreground(.gray)
                Button("Live") { state.actionFired += 1 }
                Button("Dead") { state.actionFired += 1 }
                    .disabled()
                Text("counter: \(state.actionFired)").foreground(.gray)
            }
        case .scrollbarStyle:
            HStack(spacing: 2) {
                ScrollbarSample(title: ".thin", style: .thin)
                ScrollbarSample(title: ".block", style: .block)
                ScrollbarSample(title: ".hairline", style: .hairline)
            }
        case .defaultScrollAnchor:
            VStack {
                Button("Append a line") { state.anchoredLines += 1 }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEachWithID(Array(1...state.anchoredLines), id: \.self) { line in
                            Text("line \(line)")
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
                .frame(width: 24, height: 5)
                Text("wheel up to stay put, back down to follow").foreground(.gray)
            }
        case .scrollPosition:
            VStack {
                HStack(spacing: 2) {
                    Button("Jump to row 25") { state.positionedRow = 25 }
                    Button("Back to the top") { state.positionedRow = 0 }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEachWithID(Array(0..<30), id: \.self) { row in
                            Text("row \(row)").id(row)
                        }
                    }
                }
                .scrollPosition(id: Binding(get: { state.positionedRow },
                                            set: { state.positionedRow = $0 }),
                                anchor: .top)
                .frame(width: 24, height: 5)
                Text("position: \(state.positionedRow.map(String.init) ?? "none")").foreground(.gray)
            }
        case .scrollTargetVisibility:
            VStack {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEachWithID(Array(0..<30), id: \.self) { row in
                            Text("row \(row)").id(row)
                        }
                    }
                }
                .scrollable()
                .onScrollTargetVisibilityChange(idType: Int.self) { state.visibleRows = $0 }
                .frame(width: 24, height: 5)
                Text("seen: \(state.visibleRows.map(String.init).joined(separator: ", "))").foreground(.gray)
            }
        case .syntaxHighlighter:
            MarkdownView("""
                ```ini
                ; written by the installer
                [server]
                port = 8080
                ```

                ```swift
                let port = 8080
                ```
                """)
                .syntaxHighlighter(IniHighlighter(), for: "ini")
        case .markdownStyle:
            VStack(spacing: 1) {
                MarkdownView("## Kept marker\nRun `swift test` before you push.")
                    .markdownStyle(StorybookMarkdown.marked)
                MarkdownView("Considering the **cache** first — it is the likely cause.")
                    .markdownStyle(StorybookMarkdown.quiet)
            }
        case .promptPrefix:
            PromptInput(
                text: Binding(get: { state.prefixDraft }, set: { state.prefixDraft = $0 }),
                state: Binding(get: { state.prefixPromptState }, set: { state.prefixPromptState = $0 }),
                placeholder: "Ask anything, or / for commands",
                minimumHeight: 3)
                .promptPrefix(PromptPrefix(width: 4) { row in
                    switch (row.index, row.isFocused) {
                    case (0, true):
                        [TextSpan("  > ", foreground: row.theme.success, bold: true)]
                    case (_, true):
                        [TextSpan("::: ", foreground: row.theme.successSubtle)]
                    default:
                        [TextSpan("::: ", foreground: row.theme.foregroundMuted)]
                    }
                })
        case .boundaryFeedback:
            VStack {
                Text("Type, then Left/Right past the edges").foreground(.gray)
                TextInput(text: Binding(get: { state.boundaryHitValue },
                                         set: { state.boundaryHitValue = $0 }),
                          placeholder: "type then arrow...")
                    .boundaryFeedback(.modal)
                    .onBoundaryHit { reason in
                        recordBoundaryHit(reason)
                    }
                Text("→ \(state.boundaryHitMessage)").foreground(.gray)
                Text("Same walls under .bell — the terminal beeps or flashes").foreground(.gray)
                TextInput(text: Binding(get: { state.boundaryBellValue },
                                         set: { state.boundaryBellValue = $0 }),
                          placeholder: "arrow past an edge...")
                    .boundaryFeedback(.bell)
            }
        case .textKeymap:
            VStack {
                Text("Standard: Ctrl+K kills to the end, Ctrl+A then Ctrl+Y yanks it back").foreground(.gray)
                TextInput(text: Binding(get: { state.keymapLineValue },
                                         set: { state.keymapLineValue = $0 }))
                Text("Rebound: Ctrl+Y redoes here, as it did before yank took it").foreground(.gray)
                TextArea(text: Binding(get: { state.keymapNotesContent },
                                         set: { state.keymapNotesContent = $0 }),
                         state: Binding(get: { state.keymapNotesState },
                                          set: { state.keymapNotesState = $0 }),
                         visibleHeight: 3)
                    .textKeymap(.standard.merging([.keyboard(.character("y"), .ctrl): [.redo]]))
            }
        case .modal:
            VStack {
                Text("Enter on the trigger presents; Tab stays inside").foreground(.gray)
                Text(state.modalPresented ? "  [ reopen ]  " : "  [ open dialog ]  ")
                    .focusable()
                    .onKeyPress { key in
                        switch key.key {
                        case .enter, .activate:
                            state.modalPresented = true
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                Text("background — unreachable while presented").foreground(.gray)
            }
            .modal(isPresented: state.modalPresented) {
                VStack {
                    Text(" Delete this file? ")
                    Text("  [ Cancel ]  ")
                        .focusable()
                        .onKeyPress { key in
                            switch key.key {
                            case .enter, .activate, .escape:
                                state.modalPresented = false
                                return .handled
                            default:
                                return .ignored
                            }
                        }
                    Text("  [ Delete ]  ")
                        .focusable()
                        .onKeyPress { key in
                            switch key.key {
                            case .enter, .activate:
                                state.modalPresented = false
                                return .handled
                            default:
                                return .ignored
                            }
                        }
                }
                .border(.rounded)
            }
        case .alert:
            VStack {
                Text("Enter presents; Esc cancels, Return confirms").foreground(.gray)
                Text("  [ delete file ]  ")
                    .focusable()
                    .onKeyPress { key in
                        switch key.key {
                        case .enter, .activate:
                            state.alertPresented = true
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                Text("chose: \(state.alertResult)").foreground(.gray)
            }
            .alert(
                "Delete file?",
                isPresented: Binding(get: { state.alertPresented },
                                     set: { state.alertPresented = $0 }),
                message: "This cannot be undone."
            ) {
                AlertAction("Delete", role: .destructive) { recordAlertChoice("Delete") }
                AlertAction("Cancel", role: .cancel) { recordAlertChoice("Cancel") }
            }
        case .confirmationDialog:
            VStack {
                Text("Actions stack vertically — the action-sheet shape").foreground(.gray)
                Text("  [ close editor ]  ")
                    .focusable()
                    .onKeyPress { key in
                        switch key.key {
                        case .enter, .activate:
                            state.confirmPresented = true
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                Text("chose: \(state.confirmResult)").foreground(.gray)
            }
            .confirmationDialog(
                "Discard changes?",
                isPresented: Binding(get: { state.confirmPresented },
                                     set: { state.confirmPresented = $0 })
            ) {
                AlertAction("Discard", role: .destructive) { recordConfirmChoice("Discard") }
                AlertAction("Save draft") { recordConfirmChoice("Save draft") }
                AlertAction("Cancel", role: .cancel) { recordConfirmChoice("Cancel") }
            }
        }
    }
}

/// Trampoline so the @Sendable action closure can mutate the
/// nonisolated(unsafe) global StorybookState without capturing the
/// non-Sendable instance directly. ActionDispatch fires under
/// @MainActor (the runtime contract), so direct mutation is safe;
/// the @Sendable label is a Swift-6 constraint on the closure type
/// rather than a real concurrency concern at the call site.
@Sendable
private func fireStorybookAction() {
    MainActor.assumeIsolated {
        state.actionFired += 1
    }
}

/// Trampoline for the boundary-feedback page's `.onBoundaryHit`
/// callback. Same pattern as `fireStorybookAction` — the @Sendable
/// closure can't capture the non-Sendable StorybookState directly,
/// so it hops onto MainActor and mutates the global.
@Sendable
private func recordBoundaryHit(_ reason: BoundaryHitReason) {
    MainActor.assumeIsolated {
        state.boundaryHitMessage = "boundary: \(reason)"
    }
}

/// Record which alert action the user chose. The dialog is already gone by
/// the time this is read, so the page reports the choice inline — same
/// trampoline pattern as the callbacks above.
@Sendable
private func recordAlertChoice(_ choice: String) {
    MainActor.assumeIsolated {
        state.alertResult = choice
    }
}

@Sendable
private func recordConfirmChoice(_ choice: String) {
    MainActor.assumeIsolated {
        state.confirmResult = choice
    }
}

/// Toggle "resize" mode on the actionContext stack — invoked by
/// Ctrl+R on the .actionContext page. If "resize" is currently the
/// top of the stack, pop it (exit). Otherwise push (enter). Toggling
/// avoids the "press it twice and now you need 2 pops" bug — Ctrl+R
/// is a single key the user expects to be self-inverse.
@Sendable
private func enterResizeMode() {
    MainActor.assumeIsolated {
        if state.currentMode.current == "resize" {
            state.currentMode.pop()
        } else {
            state.currentMode.push("resize")
        }
    }
}

@Sendable
private func exitResizeMode() {
    MainActor.assumeIsolated {
        // Pop while still in resize mode — guards against accidental
        // multi-pop if some path push'd more than once.
        while state.currentMode.current == "resize" {
            state.currentMode.pop()
        }
    }
}

/// Push the current fraction into the SplitState so SplitView re-
/// renders with new ratios. SplitView's update path replaces the
/// subtree on root reassignment, so we build a fresh root each time.
/// Each leaf is bordered so the visible boundary move is unambiguous
/// (border edges shift, not just text reflow).
@MainActor
private func syncActionContextSplit() {
    let f = state.actionContextLeftFraction
    state.actionContextSplit.root = .split(
        axis: .horizontal,
        children: [
            .leaf(Text("left").foreground(.green).border()),
            .leaf(Text("right").foreground(.cyan).border()),
        ],
        ratios: [f, 1.0 - f])
}

/// L bound when in resize mode — grow the left pane by ~5% of
/// the available width. The fraction is bounded [0.1, 0.9] so
/// neither pane collapses to zero.
@Sendable
private func growLeftPane() {
    MainActor.assumeIsolated {
        state.actionContextLeftFraction = min(0.9, state.actionContextLeftFraction + 0.05)
        syncActionContextSplit()
    }
}

@Sendable
private func shrinkLeftPane() {
    MainActor.assumeIsolated {
        state.actionContextLeftFraction = max(0.1, state.actionContextLeftFraction - 0.05)
        syncActionContextSplit()
    }
}

/// Build a 24x4 CellBuffer for the BufferView preview. Distinct cells
/// at known positions so a smoke walkthrough can spot-check by reading
/// the rendered preview pane back through the harness. Uses .plain
/// style: Style's custom initializer is internal, so a demo cannot
/// colour individual cells.
func buildBufferDemo() -> CellBuffer {
    var buffer = CellBuffer(width: 24, height: 4)
    buffer.write("BufferView demo", x: 0, y: 0, style: .plain)
    buffer.write("CellBuffer -> blit", x: 0, y: 1, style: .plain)
    buffer.write("\u{2592}\u{2592}\u{2592}\u{2592}\u{2592}", x: 0, y: 2, style: .plain)
    buffer.write("12345 67890", x: 0, y: 3, style: .plain)
    return buffer
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


/// The `.task` page's preview: work the view owns, ticking state that nothing
/// else drives. No timer is declared for it and no key is pressed — if the
/// screen advances, the run loop noticed an `@Observable` mutation by itself.
struct AsyncTaskDemo: TerminalView {
    // Reads the app-wide singleton rather than holding a reference: the work
    // outlives a single body evaluation, and `state` is the shape this example
    // already uses for exactly that reason.
    var body: some TerminalView {
        VStack {
            Text("ticks: \(state.asyncTicks)").foreground(.cyan).bold()
            Text("started when the page appeared, cancelled when you leave")
                .foreground(.gray)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                state.asyncTicks += 1
            }
        }
    }
}


/// One overflowing pane drawn with a given scrollbar style, for the
/// `.scrollbarStyle` page's side-by-side comparison.
struct ScrollbarSample: TerminalView {
    let title: String
    let style: ScrollbarStyle

    var body: some TerminalView {
        VStack {
            Text(title).foreground(.gray)
            ScrollView(.vertical) {
                VStack {
                    ForEachWithID(Array(0..<20), id: \.self) { row in
                        Text("row \(row)")
                    }
                }
            }
            .scrollbarStyle(style)
            .frame(width: 12, height: 6)
        }
    }
}

/// The two looks the `.markdownStyle` page shows side by side: a reply that
/// keeps its heading markers and chips its code, and a muted thinking block.
enum StorybookMarkdown {
    static let marked: MarkdownStyle = {
        var style = MarkdownStyle()
        style.h2.prefix = "## "
        style.inlineCode = .init(foreground: .red, background: .ansi256(236), prefix: " ", suffix: " ")
        return style
    }()

    static let quiet: MarkdownStyle = {
        var style = MarkdownStyle()
        style.text = .init(foreground: .gray, background: .ansi256(235))
        return style
    }()
}

/// A lexer for INI files — the `.syntaxHighlighter` page's example of an
/// app teaching the framework a language. Comments, `[section]` headers and
/// `key = value` pairs are the whole grammar.
struct IniHighlighter: SyntaxHighlighter {
    func tokenize(line: String) -> [SyntaxSpan] {
        let trimmed = line.drop { $0 == " " }
        if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") {
            return [SyntaxSpan(range: trimmed.startIndex..<line.endIndex, token: .comment)]
        }
        if trimmed.hasPrefix("[") {
            return [SyntaxSpan(range: trimmed.startIndex..<line.endIndex, token: .type)]
        }
        guard let equals = line.firstIndex(of: "=") else { return [] }
        let valueStart = line.index(after: equals)
        return [
            SyntaxSpan(range: line.startIndex..<equals, token: .keyword),
            SyntaxSpan(range: equals..<valueStart, token: .operatorToken),
            SyntaxSpan(range: valueStart..<line.endIndex, token: .string),
        ]
    }
}

/// A deliberately loud theme for the `.environment(\.theme)` page — the point
/// is that nothing on the page names a color, yet everything changes.
struct StorybookLoudTheme: Theme {
    var accent: Color = .magenta
    var foregroundMuted: Color = .rgb(120, 90, 140)
}

/// Draws with the theme and takes nothing else, so nothing but the theme can
/// make it draw differently — the `.environment(\.theme)` page's proof that a
/// switch reaches a view whose inputs never change.
struct StorybookSwatch: TerminalView {
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        Text("■ accent is \(theme.accent)").foreground(theme.accent)
    }
}

/// A row that knows when it holds focus — the `.focusable` page's example of
/// reading `isFocused`.
struct StorybookChoice: TerminalView {
    let title: String
    @TerminalEnvironment(\.isFocused) var isFocused

    var body: some TerminalView {
        Text((isFocused ? "▸ " : "  ") + title)
            .foreground(isFocused ? .cyan : .gray)
    }
}
