import Foundation
import Observation
import TerminalUI

// MARK: - Test Data

struct Process: Identifiable {
    let id: Int
    let name: String
    let pid: Int
    let cpu: Double
    let mem: Double
    let status: String
}

func generateProcesses(count: Int) -> [Process] {
    let names = [
        "swift-frontend", "SourceKitService", "swift-build", "lldb",
        "Xcode", "clangd", "swift-package", "indexstore-db",
        "swift-symbolgraph", "docc", "dsymutil", "ld",
        "Terminal", "WindowServer", "loginwindow", "Finder",
        "Dock", "SystemUIServer", "kernel_task", "launchd",
        "mds_stores", "bluetoothd", "coreaudiod", "configd",
        "powerd", "diskarbitrationd", "fseventsd", "notifyd",
        "UserEventAgent", "syslogd", "corebrightnessd", "opendirectoryd",
    ]
    return (0..<count).map { i in
        Process(
            id: i,
            name: names[i % names.count],
            pid: 1000 + i * 7,
            cpu: Double.random(in: 0...95),
            mem: Double.random(in: 0.1...8.0),
            status: ["running", "sleeping", "idle"][i % 3]
        )
    }
}

func generateCPUHistory(count: Int) -> [Double] {
    var values: [Double] = []
    var v = 30.0
    for _ in 0..<count {
        v += Double.random(in: -5...5)
        v = max(0, min(100, v))
        values.append(v)
    }
    return values
}

func generateHeatmapData(weeks: Int, days: Int = 7) -> [[Double]] {
    (0..<days).map { _ in
        (0..<weeks).map { _ in
            let roll = Double.random(in: 0...1)
            if roll < 0.2 { return 0 }
            if roll < 0.5 { return Double.random(in: 1...3) }
            if roll < 0.8 { return Double.random(in: 3...7) }
            return Double.random(in: 7...15)
        }
    }
}

// MARK: - State

@Observable
final class ComponentsState {
    var selectedTab = 0
    var tick = 0

    // List state
    let processes: [Process]
    var selectedProcessID: Int? = 0
    var processListScroll: Int = 0

    // Chart data
    var cpuHistory: [Double]
    var memHistory: [Double]

    // Heatmap
    let heatmapData: [[Double]]

    init() {
        processes = generateProcesses(count: 500)
        cpuHistory = generateCPUHistory(count: 80)
        memHistory = generateCPUHistory(count: 80)
        heatmapData = generateHeatmapData(weeks: 52)
    }

    func advanceTick() {
        tick += 1
        // Add new data point to charts
        let lastCPU = cpuHistory.last ?? 50
        let newCPU = max(0, min(100, lastCPU + Double.random(in: -8...8)))
        cpuHistory.append(newCPU)
        if cpuHistory.count > 120 { cpuHistory.removeFirst() }

        let lastMem = memHistory.last ?? 40
        let newMem = max(0, min(100, lastMem + Double.random(in: -3...3)))
        memHistory.append(newMem)
        if memHistory.count > 120 { memHistory.removeFirst() }
    }
}

nonisolated(unsafe) let state = ComponentsState()

// MARK: - Tab Navigation

struct ClickableTab: TerminalView {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some TerminalView {
        Text(isSelected ? "▸ \(label)" : "  \(label)")
            .foreground(isSelected ? .white : .gray)
            .focusable()
            .onKeyPress { event in
                if event.key == .enter || event.key == .character(" ") {
                    action()
                    return .handled
                }
                return .ignored
            }
    }
}

// MARK: - Views

struct TabBar: TerminalView {
    let selected: Int
    let onSelect: (Int) -> Void
    let tabs = ["Process List", "Charts", "Heatmap", "Table"]

    var body: some TerminalView {
        HStack {
            Text("TerminalUI Components")
                .foreground(.cyan)
                .bold()
            Text(" │ ")
                .foreground(.gray)
            ForEach(Array(tabs.enumerated().map { TabEntry(index: $0.offset, name: $0.element) })) { entry in
                ClickableTab(
                    label: entry.name,
                    isSelected: selected == entry.index
                ) { onSelect(entry.index) }
                Text(" ")
            }
            Spacer()
        }
    }
}

struct TabEntry: Identifiable {
    let index: Int
    let name: String
    var id: Int { index }
}

// MARK: - Tab 1: Large Scrollable Process List

struct ProcessListTab: TerminalView {
    let state: ComponentsState

    var body: some TerminalView {
        VStack {
            HStack {
                Text("Process List")
                    .bold()
                Spacer()
                Text("\(state.processes.count) items — ↑↓ navigate, PgUp/PgDn scroll")
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
                 visibleCount: 25
            ) { proc in
                Text(formatProcess(proc))
                    .foreground(proc.cpu > 50 ? .yellow : proc.cpu > 80 ? .red : .default)
            }
        }
    }
}

func formatProcess(_ p: Process) -> String {
    let name = p.name.padding(toLength: 22, withPad: " ", startingAt: 0)
    let pid = String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)
    let cpu = String(format: "%5.1f%%", p.cpu)
    let mem = String(format: "%5.1fM", p.mem)
    let status = p.status.padding(toLength: 10, withPad: " ", startingAt: 0)
    return "\(name) \(pid) \(cpu) \(mem) \(status)"
}

// MARK: - Tab 2: Charts

struct ChartsTab: TerminalView {
    let state: ComponentsState

    var body: some TerminalView {
        VStack {
            Text("Live Charts")
                .bold()
            Divider()

            // CPU sparkline
            HStack {
                Text("CPU ")
                    .foreground(.cyan)
                    .bold()
                Sparkline(
                    data: state.cpuHistory,
                    width: 60, height: 5,
                    min: 0, max: 100
                )
                .foreground(.green)
            }

            Divider()

            // Memory sparkline
            HStack {
                Text("MEM ")
                    .foreground(.magenta)
                    .bold()
                Sparkline(
                    data: state.memHistory,
                    width: 60, height: 5,
                    min: 0, max: 100,
                    filled: true
                )
                .foreground(.blue)
            }

            Divider()

            // Bar chart
            Text("Language Popularity")
                .bold()
            BarChart(
                items: [
                    .init(label: "Python", value: 28.1, color: .yellow),
                    .init(label: "Java", value: 15.6, color: .red),
                    .init(label: "JavaScript", value: 12.4, color: .yellow),
                    .init(label: "C/C++", value: 11.2, color: .blue),
                    .init(label: "Go", value: 8.7, color: .cyan),
                    .init(label: "Rust", value: 5.3, color: .red),
                    .init(label: "Swift", value: 4.8, color: .brightRed),
                    .init(label: "TypeScript", value: 4.2, color: .blue),
                ],
                barWidth: 40
            )
            .foreground(.green)

            Spacer()
        }
    }
}

// MARK: - Tab 3: Heatmap

struct HeatmapTab: TerminalView {
    let state: ComponentsState

    var body: some TerminalView {
        VStack {
            Text("Contribution Heatmap (52 weeks)")
                .bold()
            Divider()
            Text("")
            HStack {
                VStack {
                    Text("Mon")
                        .foreground(.gray)
                    Text("   ")
                    Text("Wed")
                        .foreground(.gray)
                    Text("   ")
                    Text("Fri")
                        .foreground(.gray)
                    Text("   ")
                    Text("Sun")
                        .foreground(.gray)
                }
                HeatMap(
                    data: state.heatmapData,
                    palette: .green,
                    cellStyle: .shade
                )
                .foreground(.green)
            }
            Text("")
            HStack {
                Text("  Less ")
                    .foreground(.gray)
                Text("░▒▓█")
                    .foreground(.green)
                Text(" More")
                    .foreground(.gray)
                Spacer()
            }
            Spacer()
        }
    }
}

// MARK: - Tab 4: Table

struct TableTab: TerminalView {
    let state: ComponentsState

    var body: some TerminalView {
        VStack {
            Text("Process Table (top 20 by CPU)")
                .bold()
            Divider()
            Table(
                Array(state.processes.sorted { $0.cpu > $1.cpu }.prefix(20)),
                columns: [
                    TableColumn("Process", width: 22) { $0.name },
                    TableColumn("PID", width: 8, alignment: .right) { "\($0.pid)" },
                    TableColumn("CPU%", width: 8, alignment: .right) { String(format: "%.1f", $0.cpu) },
                    TableColumn("Mem MB", width: 8, alignment: .right) { String(format: "%.1f", $0.mem) },
                    TableColumn("Status", width: 12) { $0.status },
                ]
            )
            Spacer()
        }
    }
}

// MARK: - Root

struct ComponentsApp: TerminalView {
    let state: ComponentsState

    var body: some TerminalView {
        VStack {
            TabBar(selected: state.selectedTab, onSelect: { state.selectedTab = $0 })
            Divider()

            if state.selectedTab == 0 {
                ProcessListTab(state: state)
            } else if state.selectedTab == 1 {
                ChartsTab(state: state)
            } else if state.selectedTab == 2 {
                HeatmapTab(state: state)
            } else {
                TableTab(state: state)
            }
        }
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Entry Point

@main struct ComponentsDemo: TerminalAppProtocol {
    static var renderMode: RenderMode { .fps30 }

    static var timers: [TerminalTimer] {[
        TerminalTimer("tick", every: .milliseconds(200)),
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
            default: break
            }
        case .timer(let name):
            if name == "tick" { state.advanceTick() }
        default: break
        }
        return true
    }

    static func content() -> some TerminalView {
        ComponentsApp(state: state)
    }
}
