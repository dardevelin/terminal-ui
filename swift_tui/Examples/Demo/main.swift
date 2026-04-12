import Foundation
import Observation
import TerminalUI

// MARK: - Data Models

struct BuildTask: Identifiable {
    let id: Int
    var name: String
    var status: TaskStatus
    var progress: Double

    enum TaskStatus: String {
        case pending = "pending"
        case running = "running"
        case done = "done"
        case failed = "failed"

        var color: Color {
            switch self {
            case .pending: .gray
            case .running: .yellow
            case .done: .green
            case .failed: .red
            }
        }

        var icon: String {
            switch self {
            case .pending: "○"
            case .running: "●"
            case .done: "✓"
            case .failed: "✗"
            }
        }
    }
}

struct LogEntry: Identifiable {
    let id: Int
    let timestamp: String
    let message: String
    let level: LogLevel

    enum LogLevel {
        case info, warn, error

        var color: Color {
            switch self {
            case .info: .gray
            case .warn: .yellow
            case .error: .red
            }
        }

        var prefix: String {
            switch self {
            case .info: "INF"
            case .warn: "WRN"
            case .error: "ERR"
            }
        }
    }
}

struct ProcessItem: Identifiable {
    let id: Int
    let name: String
    let pid: Int
    let cpu: Double
    let mem: Double
    let status: String
}

// MARK: - App State

@Observable
final class AppState {
    let startTime = Date()
    var tick: Int = 0
    var spinnerFrame: Int = 0
    var selectedTab: Int = 0
    var showHelp: Bool = false

    // TextArea state
    var editorText: String = "// Welcome to TerminalUI\n// Try editing this text!\n\nfunc hello() {\n    print(\"Hello, world!\")\n}\n"
    var editorState: TextAreaState = TextAreaState()

    // Interactive controls state
    var searchText: String = ""
    var projectName: String = "swift_tui"
    var autoRebuild: Bool = true
    var verboseOutput: Bool = false
    var optimizeRelease: Bool = false
    var actionLog: [String] = []

    // Build tasks
    var tasks: [BuildTask] = [
        BuildTask(id: 0, name: "Compile swift_tui",     status: .pending, progress: 0),
        BuildTask(id: 1, name: "Link TerminalUI",       status: .pending, progress: 0),
        BuildTask(id: 2, name: "Run test suite",         status: .pending, progress: 0),
        BuildTask(id: 3, name: "Generate documentation", status: .pending, progress: 0),
        BuildTask(id: 4, name: "Package binary",         status: .pending, progress: 0),
    ]

    var logs: [LogEntry] = []
    private var logCounter = 0

    // Chart data — live updating
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []

    // Process list (large dataset)
    let processes: [ProcessItem]
    var selectedProcessID: Int? = 0
    var processListScroll: Int = 0

    // Heatmap (static)
    let heatmapData: [[Double]]

    init() {
        // Generate 500 processes
        let names = [
            "swift-frontend", "SourceKitService", "swift-build", "lldb",
            "Xcode", "clangd", "swift-package", "indexstore-db",
            "Terminal", "WindowServer", "loginwindow", "Finder",
            "Dock", "SystemUIServer", "kernel_task", "launchd",
            "mds_stores", "bluetoothd", "coreaudiod", "configd",
        ]
        processes = (0..<500).map { i in
            ProcessItem(
                id: i,
                name: names[i % names.count],
                pid: 1000 + i * 7,
                cpu: Double.random(in: 0...95),
                mem: Double.random(in: 0.1...8.0),
                status: ["running", "sleeping", "idle"][i % 3]
            )
        }

        // GitHub-style heatmap (7 rows x 52 cols)
        heatmapData = (0..<7).map { _ in
            (0..<52).map { _ in
                let roll = Double.random(in: 0...1)
                if roll < 0.2 { return 0 }
                if roll < 0.5 { return Double.random(in: 1...3) }
                if roll < 0.8 { return Double.random(in: 3...7) }
                return Double.random(in: 7...15)
            }
        }

        // Seed chart history
        var cpu = 30.0, mem = 45.0
        for _ in 0..<80 {
            cpu += Double.random(in: -5...5); cpu = max(0, min(100, cpu))
            mem += Double.random(in: -3...3); mem = max(0, min(100, mem))
            cpuHistory.append(cpu)
            memHistory.append(mem)
        }
    }

    var overallProgress: Double {
        tasks.map(\.progress).reduce(0, +) / Double(tasks.count)
    }

    var activeTaskIndex: Int? {
        tasks.firstIndex { $0.status == .running }
    }

    func advanceBuild() {
        tick += 1
        if let idx = activeTaskIndex {
            tasks[idx].progress = min(1.0, tasks[idx].progress + 0.02)
            if tasks[idx].progress >= 1.0 {
                tasks[idx].status = .done
                addLog(.info, "Completed: \(tasks[idx].name)")
            }
        } else if let nextIdx = tasks.firstIndex(where: { $0.status == .pending }) {
            tasks[nextIdx].status = .running
            addLog(.info, "Starting: \(tasks[nextIdx].name)")
        }
    }

    func advanceCharts() {
        let lastCPU = cpuHistory.last ?? 50
        let newCPU = max(0, min(100, lastCPU + Double.random(in: -8...8)))
        cpuHistory.append(newCPU)
        if cpuHistory.count > 120 { cpuHistory.removeFirst() }

        let lastMem = memHistory.last ?? 40
        let newMem = max(0, min(100, lastMem + Double.random(in: -3...3)))
        memHistory.append(newMem)
        if memHistory.count > 120 { memHistory.removeFirst() }
    }

    func addLog(_ level: LogEntry.LogLevel, _ message: String) {
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
        logCounter += 1
        logs.append(LogEntry(id: logCounter, timestamp: elapsed, message: message, level: level))
        if logs.count > 50 { logs.removeFirst() }
    }

    func logAction(_ action: String) {
        actionLog.append(action)
        if actionLog.count > 10 { actionLog.removeFirst() }
        addLog(.info, action)
    }

    var elapsed: String {
        String(format: "%.1fs", Date().timeIntervalSince(startTime))
    }
}

nonisolated(unsafe) let state = AppState()

// MARK: - Reusable Tab Item

struct TabItem: TerminalView {
    let label: String
    let isSelected: Bool
    let index: Int
    let tabCount: Int
    let onSelectTab: (Int) -> Void

    var body: some TerminalView {
        Text(isSelected ? "▸ \(label)" : "  \(label)")
            .foreground(isSelected ? .white : .gray)
            .focusable()
            .onKeyPress { event in
                switch event.key {
                case .enter, .character(" "):
                    onSelectTab(index)
                    return .handled
                case .right:
                    if index + 1 < tabCount { onSelectTab(index + 1) }
                    return .ignored
                case .left:
                    if index > 0 { onSelectTab(index - 1) }
                    return .ignored
                default:
                    return .ignored
                }
            }
    }
}

// MARK: - Title Bar

struct TitleBar: TerminalView {
    let selectedTab: Int
    let tabNames: [String]
    let onSelectTab: (Int) -> Void

    var body: some TerminalView {
        HStack {
            Text("TerminalUI")
                .foreground(.cyan)
                .bold()
            Text(" │ ")
                .foreground(.gray)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(tabNames.enumerated().map {
                        TabEntry(index: $0.offset, name: $0.element)
                    })) { entry in
                        TabItem(
                            label: entry.name,
                            isSelected: selectedTab == entry.index,
                            index: entry.index,
                            tabCount: tabNames.count,
                            onSelectTab: onSelectTab
                        )
                        Text(" ")
                    }
                }
            }
            Text(" │ ")
                .foreground(.gray)
            Text("v0.6")
                .foreground(.gray)
        }
    }
}

struct TabEntry: Identifiable {
    let index: Int
    let name: String
    var id: Int { index }
}

// MARK: - Tab 1: Build Pipeline

struct TaskRow: TerminalView {
    let task: BuildTask
    let spinnerFrame: Int

    var body: some TerminalView {
        HStack {
            if task.status == .running {
                Spinner(frame: spinnerFrame, style: .dots)
                    .foreground(.cyan)
            } else {
                Text(task.status.icon)
                    .foreground(task.status.color)
            }
            Text(" \(task.name)")
            Spacer()
            Text(rightColumns)
                .foreground(task.status.color)
        }
    }

    var rightColumns: String {
        let bar: String
        let pct: String
        switch task.status {
        case .running, .done, .failed:
            let barW = 20
            let filled = Int(Double(barW) * task.progress)
            let empty = barW - filled
            bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
            let p = "\(Int(task.progress * 100))%"
            pct = String(repeating: " ", count: max(0, 5 - p.count)) + p
        case .pending:
            bar = String(repeating: " ", count: 20)
            pct = String(repeating: " ", count: 5)
        }
        let status = task.status.rawValue
        let statusPad = String(repeating: " ", count: max(0, 8 - status.count))
        return bar + pct + " " + status + statusPad
    }
}

struct BuildTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("Build Pipeline")
                .bold()
            Divider()
            ForEach(state.tasks) { task in
                TaskRow(task: task, spinnerFrame: state.spinnerFrame)
            }
            Divider()
            HStack {
                Text("Overall:")
                ProgressBar(value: state.overallProgress, label: nil, filled: "█", empty: "░")
                    .foreground(state.overallProgress >= 1.0 ? .green : .cyan)
            }
            Spacer()
        }
    }
}

// MARK: - Tab 2: Logs

struct LogsTab: TerminalView {
    let logs: [LogEntry]

    var body: some TerminalView {
        VStack {
            Text("Event Log")
                .bold()
            Divider()
            if logs.isEmpty {
                Text("No events yet...")
                    .foreground(.gray)
            } else {
                ForEach(Array(logs.suffix(20).enumerated().map {
                    IndexedLog(index: $0.offset, entry: $0.element)
                })) { item in
                    HStack {
                        Text("[\(item.entry.timestamp)]")
                            .foreground(.gray)
                        Text(" \(item.entry.level.prefix)")
                            .foreground(item.entry.level.color)
                            .bold()
                        Text(" \(item.entry.message)")
                    }
                }
            }
            Spacer()
        }
    }
}

struct IndexedLog: Identifiable {
    let index: Int
    let entry: LogEntry
    var id: Int { entry.id }
}

// MARK: - Tab 3: Controls

struct ControlsTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("Interactive Controls")
                .bold()
            Divider()
            Text("  Tab/S-Tab: navigate   Enter/Space: activate   Mouse: click")
                .foreground(.gray)
            Divider()

            Text("  Text Inputs")
                .bold()
            HStack {
                Text("  ")
                TextInput("  Project: ", text: Binding(
                    get: { state.projectName }, set: { state.projectName = $0 }
                ))
            }
            HStack {
                Text("  ")
                TextInput("  Search:  ", text: Binding(
                    get: { state.searchText }, set: { state.searchText = $0 }
                ))
            }
            Divider()

            Text("  Options")
                .bold()
            HStack {
                Text("  ")
                Toggle("Auto-rebuild", isOn: Binding(
                    get: { state.autoRebuild },
                    set: { state.autoRebuild = $0; state.logAction("Auto-rebuild: \($0)") }
                ))
                Text("    ")
                Toggle("Verbose", isOn: Binding(
                    get: { state.verboseOutput },
                    set: { state.verboseOutput = $0; state.logAction("Verbose: \($0)") }
                ))
                Text("    ")
                Toggle("Release", isOn: Binding(
                    get: { state.optimizeRelease },
                    set: { state.optimizeRelease = $0; state.logAction("Optimize: \($0)") }
                ))
            }
            Divider()

            Text("  Actions")
                .bold()
            HStack {
                Text("  ")
                Button("Clean Build") {
                    state.logAction("Clean build triggered")
                    for i in state.tasks.indices {
                        state.tasks[i].status = .pending
                        state.tasks[i].progress = 0
                    }
                }
                Text("  ")
                Button("Run Tests") { state.logAction("Test run triggered") }
                Text("  ")
                Button("Deploy") { state.logAction("Deploy triggered") }
            }

            if !state.actionLog.isEmpty {
                Text("")
                ForEach(Array(state.actionLog.suffix(5).enumerated().map {
                    ActionItem(index: $0.offset, text: $0.element)
                })) { item in
                    Text("  → \(item.text)")
                        .foreground(.cyan)
                }
            }
            Spacer()
        }
    }
}

struct ActionItem: Identifiable {
    let index: Int
    let text: String
    var id: Int { index }
}

// MARK: - Tab 4: Charts

struct ChartsTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("Live Charts")
                .bold()
            Divider()

            HStack {
                Text("CPU ")
                    .foreground(.cyan)
                    .bold()
                Sparkline(data: state.cpuHistory, width: 60, height: 4, min: 0, max: 100)
                    .foreground(.green)
            }
            Divider()
            HStack {
                Text("MEM ")
                    .foreground(.magenta)
                    .bold()
                Sparkline(data: state.memHistory, width: 60, height: 4, min: 0, max: 100, filled: true)
                    .foreground(.blue)
            }
            Divider()

            Text("Language Popularity")
                .bold()
            BarChart(
                items: [
                    .init(label: "Python    ", value: 28.1),
                    .init(label: "Java      ", value: 15.6),
                    .init(label: "JavaScript", value: 12.4),
                    .init(label: "C/C++     ", value: 11.2),
                    .init(label: "Go        ", value: 8.7),
                    .init(label: "Rust      ", value: 5.3),
                    .init(label: "Swift     ", value: 4.8),
                ],
                barWidth: 35
            )
            .foreground(.green)
            Spacer()
        }
    }
}

// MARK: - Tab 5: Heatmap

struct HeatmapTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("Contribution Heatmap (52 weeks)")
                .bold()
            Divider()
            Text("")
            HStack {
                VStack {
                    Text("Mon").foreground(.gray)
                    Text("   ")
                    Text("Wed").foreground(.gray)
                    Text("   ")
                    Text("Fri").foreground(.gray)
                    Text("   ")
                    Text("Sun").foreground(.gray)
                }
                HeatMap(data: state.heatmapData, palette: .green, cellStyle: .shade)
                    .foreground(.green)
            }
            Text("")
            HStack {
                Text("  Less ").foreground(.gray)
                Text("░▒▓█").foreground(.green)
                Text(" More").foreground(.gray)
                Spacer()
            }
            Spacer()
        }
    }
}

// MARK: - Tab 6: Process List (500 items)

struct ProcessListTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            HStack {
                Text("Process List")
                    .bold()
                Spacer()
                Text("\(state.processes.count) items — ↑↓ PgUp/PgDn Home/End")
                    .foreground(.gray)
            }
            Divider()
            List(state.processes,
                 selection: Binding(
                    get: { state.selectedProcessID },
                    set: { state.selectedProcessID = $0 }
                 ),
                 scroll: Binding(
                    get: { state.processListScroll },
                    set: { state.processListScroll = $0 }
                 ),
                 visibleCount: 20
            ) { proc in
                Text(formatProcess(proc))
                    .foreground(proc.cpu > 80 ? .red : proc.cpu > 50 ? .yellow : .default)
            }
        }
    }
}

private func formatProcess(_ p: ProcessItem) -> String {
    let name = p.name.count > 20 ? String(p.name.prefix(20)) : p.name + String(repeating: " ", count: 20 - p.name.count)
    let pid = String(p.pid)
    let pidPad = String(repeating: " ", count: max(0, 7 - pid.count))
    let cpu = String(format: "%5.1f%%", p.cpu)
    let mem = String(format: "%5.1fM", p.mem)
    let status = p.status.count > 8 ? String(p.status.prefix(8)) : p.status + String(repeating: " ", count: 8 - p.status.count)
    return "\(name) \(pidPad)\(pid) \(cpu) \(mem) \(status)"
}

// MARK: - Tab 7: Table

struct TableTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("Process Table (top 20 by CPU)")
                .bold()
            Divider()
            Table(
                Array(state.processes.sorted { $0.cpu > $1.cpu }.prefix(20)),
                columns: [
                    TableColumn("Process", width: 20) { $0.name },
                    TableColumn("PID", width: 8, alignment: .right) { "\($0.pid)" },
                    TableColumn("CPU%", width: 8, alignment: .right) { String(format: "%.1f", $0.cpu) },
                    TableColumn("Mem MB", width: 8, alignment: .right) { String(format: "%.1f", $0.mem) },
                    TableColumn("Status", width: 10) { $0.status },
                ]
            )
            Spacer()
        }
    }
}

// MARK: - Tab 8: Diff View

struct DiffTab: TerminalView {
    static let diffLines: [DiffLine] = {
        let oldCode = """
        func greet(_ name: String) {
            print("Hello, \\(name)!")
        }

        func farewell(_ name: String) {
            print("Goodbye!")
        }
        """

        let newCode = """
        func greet(_ name: String, formal: Bool = false) {
            if formal {
                print("Good day, \\(name).")
            } else {
                print("Hello, \\(name)!")
            }
        }

        func farewell(_ name: String) {
            print("Goodbye, \\(name)! See you soon.")
        }

        func wave() {
            print("👋")
        }
        """
        return DiffEngine.diff(original: oldCode, modified: newCode)
    }()

    var body: some TerminalView {
        VStack {
            Text("Diff View — Unified Mode")
                .bold()
            Divider()
            DiffView(lines: Self.diffLines)
            Spacer()
        }
    }
}

// MARK: - Tab 9: Hunk Diff View

struct HunkDiffTab: TerminalView {
    static let hunks: [HunkDiff.Hunk] = [
        HunkDiff.Hunk(oldStart: 1, newStart: 1, lines: [
            HunkDiff.Line(type: .context, content: "import Foundation", oldLineNo: 1, newLineNo: 1),
            HunkDiff.Line(type: .context, content: "", oldLineNo: 2, newLineNo: 2),
            HunkDiff.Line(type: .remove, content: "func process(_ input: String) -> String {", oldLineNo: 3, newLineNo: nil),
            HunkDiff.Line(type: .add, content: "func process(_ input: String, validate: Bool = true) -> Result<String, Error> {", oldLineNo: nil, newLineNo: 3),
            HunkDiff.Line(type: .add, content: "    guard validate else { return .success(input) }", oldLineNo: nil, newLineNo: 4),
            HunkDiff.Line(type: .context, content: "    let trimmed = input.trimmingCharacters(in: .whitespaces)", oldLineNo: 4, newLineNo: 5),
            HunkDiff.Line(type: .remove, content: "    return trimmed.uppercased()", oldLineNo: 5, newLineNo: nil),
            HunkDiff.Line(type: .add, content: "    return .success(trimmed.uppercased())", oldLineNo: nil, newLineNo: 6),
            HunkDiff.Line(type: .context, content: "}", oldLineNo: 6, newLineNo: 7),
        ]),
        HunkDiff.Hunk(oldStart: 10, newStart: 11, lines: [
            HunkDiff.Line(type: .context, content: "// MARK: - Tests", oldLineNo: 10, newLineNo: 11),
            HunkDiff.Line(type: .context, content: "", oldLineNo: 11, newLineNo: 12),
            HunkDiff.Line(type: .add, content: "func testValidation() {", oldLineNo: nil, newLineNo: 13),
            HunkDiff.Line(type: .add, content: "    let result = process(\"hello\", validate: true)", oldLineNo: nil, newLineNo: 14),
            HunkDiff.Line(type: .add, content: "    assert(result == .success(\"HELLO\"))", oldLineNo: nil, newLineNo: 15),
            HunkDiff.Line(type: .add, content: "}", oldLineNo: nil, newLineNo: 16),
        ]),
    ]

    var body: some TerminalView {
        VStack {
            Text("Hunk Diff — GitHub PR Review Style")
                .bold()
            Text("  j/k: navigate  v: visual select  Esc: cancel")
                .foreground(.gray)
            Divider()
            HunkDiffView(
                hunks: Self.hunks,
                fileName: "Sources/Core/Processor.swift",
                visibleCount: 18
            )
            Spacer()
        }
    }
}

// MARK: - Tab 10: Tree View

struct FileItem: Identifiable {
    let id: String
    let name: String
    let children: [FileItem]?

    static let sampleTree: [FileItem] = [
        FileItem(id: "src", name: "Sources/", children: [
            FileItem(id: "core", name: "Core/", children: [
                FileItem(id: "app", name: "TerminalApp.swift", children: nil),
                FileItem(id: "frame", name: "FrameStats.swift", children: nil),
                FileItem(id: "input", name: "InputParser.swift", children: nil),
                FileItem(id: "key", name: "KeyEvent.swift", children: nil),
            ]),
            FileItem(id: "views", name: "Views/", children: [
                FileItem(id: "text", name: "Text.swift", children: nil),
                FileItem(id: "btn", name: "Button.swift", children: nil),
                FileItem(id: "list", name: "List.swift", children: nil),
                FileItem(id: "tree", name: "TreeView.swift", children: nil),
                FileItem(id: "diff", name: "DiffView.swift", children: nil),
            ]),
            FileItem(id: "graph", name: "Graph/", children: [
                FileItem(id: "ag", name: "AttributeGraph.swift", children: nil),
                FileItem(id: "an", name: "AttributeNode.swift", children: nil),
                FileItem(id: "gr", name: "GraphRenderer.swift", children: nil),
            ]),
        ]),
        FileItem(id: "ex", name: "Examples/", children: [
            FileItem(id: "demo", name: "Demo/", children: [
                FileItem(id: "main", name: "main.swift", children: nil),
            ]),
        ]),
        FileItem(id: "pkg", name: "Package.swift", children: nil),
    ]
}

struct TreeTab: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("Tree View — File Browser")
                .bold()
            Text("  ↑↓/mouse: navigate  →/Enter: expand  ←: collapse  Ctrl+G: inspector")
                .foreground(.gray)
            Divider()
            TreeView(FileItem.sampleTree, children: \.children, visibleCount: 20) { item in
                Text(item.name)
                    .foreground(item.children != nil ? .cyan : .default)
            }
            Spacer()
        }
    }
}

// MARK: - Tab 11: TextArea

struct TextAreaTab: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            Text("TextArea — Multi-line Editor")
                .bold()
            Text("  Arrow keys: move  Shift+arrows: select  Type to insert")
                .foreground(.gray)
            Divider()
            TextArea(
                text: Binding(get: { state.editorText }, set: { state.editorText = $0 }),
                state: Binding(get: { state.editorState }, set: { state.editorState = $0 }),
                lineNumbers: true,
                visibleHeight: 16
            )
            Spacer()
        }
    }
}

// MARK: - Tab 12: StatusBar Demo

struct StatusBarTab: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("StatusBar Component")
                .bold()
            Divider()
            Text("  Key hints style:")
            StatusBar.keyHints([
                ("^C", "Quit"),
                ("^S", "Save"),
                ("Tab", "Focus"),
                ("^D", "Debug"),
                ("^F", "Panel"),
            ])
            Text("")
            Text("  Custom sections style:")
            StatusBar {
                StatusBar.Section(.left) {
                    " NORMAL ".fg(.white).bg(.blue).bolded()
                }
                StatusBar.Section(.center) {
                    "main.swift".fg(.white)
                }
                StatusBar.Section(.right) {
                    "Ln 42, Col 8".fg(.gray)
                }
            }
            Text("")
            Text("  These bars pin to a single row and fill the available width.")
                .foreground(.gray)
            Spacer()
        }
    }
}

// MARK: - Active Tab Router
// Renders the selected tab without using if/else chains or switch in a result builder.
// Deep ConditionalView nesting causes index-out-of-range during graph reconciliation.

struct ActiveTab: TerminalView {
    let index: Int
    let state: AppState

    var body: some TerminalView {
        // Each case is a full VStack — the graph sees a single composite child
        // that changes type when tabs switch, triggering a clean rebuild.
        if index == 0 { BuildTab(state: state) }
        else if index == 1 { LogsTab(logs: state.logs) }
        else if index == 2 { ControlsTab(state: state) }
        else if index == 3 { ChartsTab(state: state) }
        else if index == 4 { HeatmapTab(state: state) }
        else if index == 5 { ProcessListTab(state: state) }
        else if index == 6 { TableTab(state: state) }
        else if index == 7 { DiffTab() }
        else if index == 8 { HunkDiffTab() }
        else if index == 9 { TreeTab() }
        else if index == 10 { TextAreaTab(state: state) }
        else { StatusBarTab() }
    }
}

// MARK: - Help Overlay

struct HelpOverlay: TerminalView {
    static let content = [
        "  Keyboard Shortcuts     ",
        "─────────────────────────",
        "  1-9,0   Switch tabs    ",
        "  Tab     Next control   ",
        "  S-Tab   Prev control   ",
        "  Enter   Activate       ",
        "  h/?     Toggle help    ",
        "  ctrl+d  Debug overlay  ",
        "  ctrl+f  Debug panel    ",
        "  q/esc   Quit           ",
    ].joined(separator: "\n")

    var body: some TerminalView {
        Text(Self.content)
            .padding(1)
            .border(.double)
            .foreground(.cyan)
    }
}

// MARK: - Status Line

struct StatusLine: TerminalView {
    let elapsed: String
    let tab: Int
    let tabCount: Int

    var body: some TerminalView {
        HStack {
            Text(elapsed)
                .foreground(.gray)
            Text(" │ ")
                .foreground(.gray)
            Text("tab:\(tab + 1)/\(tabCount)")
                .foreground(.gray)
            Spacer()
            Text("1-0/-/=: tabs  []: prev/next  h: help  q: quit")
                .foreground(.gray)
        }
    }
}

// MARK: - Root App

struct App: TerminalView {
    let state: AppState

    static let tabNames = [
        "Build", "Logs", "Controls", "Charts", "Heatmap",
        "Processes", "Table", "Diff", "HunkDiff", "Tree", "Editor", "StatusBar",
    ]

    var body: some TerminalView {
        VStack {
            TitleBar(
                selectedTab: state.selectedTab,
                tabNames: Self.tabNames,
                onSelectTab: { state.selectedTab = $0 }
            )
            Divider()

            ActiveTab(index: state.selectedTab, state: state)

            Spacer()
            Divider()
            StatusLine(elapsed: state.elapsed, tab: state.selectedTab, tabCount: Self.tabNames.count)
        }
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Entry Point

@main struct Demo: TerminalAppProtocol {
    static var renderMode: RenderMode { .onDemand }

    static var timers: [TerminalTimer] {[
        TerminalTimer("spinner", every: .milliseconds(80)),
        TerminalTimer("build",   every: .milliseconds(150)),
        TerminalTimer("charts",  every: .milliseconds(200)),
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        switch event {
        case .key(let k):
            switch k.key {
            case .character("q"), .escape: return false
            case .character("1"): state.selectedTab = 0
            case .character("2"): state.selectedTab = 1
            case .character("3"): state.selectedTab = 2
            case .character("4"): state.selectedTab = 3
            case .character("5"): state.selectedTab = 4
            case .character("6"): state.selectedTab = 5
            case .character("7"): state.selectedTab = 6
            case .character("8"): state.selectedTab = 7
            case .character("9"): state.selectedTab = 8
            case .character("0"): state.selectedTab = 9
            case .character("-"): state.selectedTab = 10
            case .character("="): state.selectedTab = 11
            case .character("["): state.selectedTab = max(0, state.selectedTab - 1)
            case .character("]"): state.selectedTab = min(App.tabNames.count - 1, state.selectedTab + 1)
            case .character("?"), .character("h"):
                state.showHelp.toggle()
            default: break
            }
        case .timer(let name):
            switch name {
            case "spinner": state.spinnerFrame += 1
            case "build":   state.advanceBuild()
            case "charts":  state.advanceCharts()
            default: break
            }
        default: break
        }
        return true
    }

    static func content() -> some TerminalView {
        App(state: state)
            .modal(isPresented: state.showHelp) {
                HelpOverlay()
            }
    }
}
