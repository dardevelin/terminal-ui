import Foundation
import Observation
import TerminalUI

// MARK: - Data Models

struct Task: Identifiable {
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

// MARK: - App State

@Observable
final class AppState {
    let startTime = Date()
    var tick: Int = 0
    var spinnerFrame: Int = 0
    var selectedTab: Int = 0
    var showHelp: Bool = false

    var tasks: [Task] = [
        Task(id: 0, name: "Compile swift_tui",     status: .pending, progress: 0),
        Task(id: 1, name: "Link TerminalUI",       status: .pending, progress: 0),
        Task(id: 2, name: "Run test suite",         status: .pending, progress: 0),
        Task(id: 3, name: "Generate documentation", status: .pending, progress: 0),
        Task(id: 4, name: "Package binary",         status: .pending, progress: 0),
    ]

    var logs: [LogEntry] = []
    private var logCounter = 0

    var overallProgress: Double {
        tasks.map(\.progress).reduce(0, +) / Double(tasks.count)
    }

    var activeTaskIndex: Int? {
        tasks.firstIndex { $0.status == .running }
    }

    func advanceBuild() {
        tick += 1

        // Find the current running task, or start the next pending one
        if let idx = activeTaskIndex {
            tasks[idx].progress = min(1.0, tasks[idx].progress + 0.02)
            if tasks[idx].progress >= 1.0 {
                tasks[idx].status = .done
                addLog(.info, "Completed: \(tasks[idx].name)")

                // Randomly fail a task
                if idx == 2 && tick > 60 {
                    tasks[idx].status = .failed
                    addLog(.error, "FAILED: \(tasks[idx].name)")
                }
            }
        } else if let nextIdx = tasks.firstIndex(where: { $0.status == .pending }) {
            tasks[nextIdx].status = .running
            addLog(.info, "Starting: \(tasks[nextIdx].name)")
        }
    }

    func addLog(_ level: LogEntry.LogLevel, _ message: String) {
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
        logCounter += 1
        logs.append(LogEntry(id: logCounter, timestamp: elapsed, message: message, level: level))
        if logs.count > 50 { logs.removeFirst() }
    }

    var elapsed: String {
        String(format: "%.1fs", Date().timeIntervalSince(startTime))
    }
}

nonisolated(unsafe) let state = AppState()

// MARK: - Views

struct TitleBar: TerminalView {
    let selectedTab: Int

    var body: some TerminalView {
        HStack {
            Text("swift_tui")
                .foreground(.cyan)
                .bold()
            Text(" │ ")
                .foreground(.gray)
            Text(selectedTab == 0 ? "▸ Build" : "  Build")
                .foreground(selectedTab == 0 ? .white : .gray)
            Text("  ")
            Text(selectedTab == 1 ? "▸ Logs" : "  Logs")
                .foreground(selectedTab == 1 ? .white : .gray)
            Text("  ")
            Text(selectedTab == 2 ? "▸ Info" : "  Info")
                .foreground(selectedTab == 2 ? .white : .gray)
            Spacer()
            Text("v0.2")
                .foreground(.gray)
        }
    }
}

struct TaskRow: TerminalView {
    let task: Task
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
            if task.status == .running || task.status == .done {
                ProgressBar(value: task.progress, filled: "█", empty: "░")
                    .foreground(task.status == .done ? .green : .yellow)
                    .frame(width: 20)
            }
            Text(" \(task.status.rawValue)")
                .foreground(task.status.color)
        }
    }
}

struct BuildTab: TerminalView {
    let tasks: [Task]
    let spinnerFrame: Int
    let overallProgress: Double

    var body: some TerminalView {
        VStack {
            Text("Build Pipeline")
                .bold()
            Divider()
            ForEach(tasks) { task in
                TaskRow(task: task, spinnerFrame: spinnerFrame)
            }
            Divider()
            HStack {
                Text("Overall:")
                ProgressBar(value: overallProgress, label: nil, filled: "█", empty: "░")
                    .foreground(overallProgress >= 1.0 ? .green : .cyan)
            }
        }
    }
}

struct LogRow: TerminalView {
    let entry: LogEntry

    var body: some TerminalView {
        HStack {
            Text("[\(entry.timestamp)]")
                .foreground(.gray)
            Text(" \(entry.level.prefix)")
                .foreground(entry.level.color)
                .bold()
            Text(" \(entry.message)")
        }
    }
}

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
                ForEach(Array(logs.suffix(15).enumerated().map {
                    IndexedLog(index: $0.offset, entry: $0.element)
                })) { item in
                    LogRow(entry: item.entry)
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

struct InfoTab: TerminalView {
    let elapsed: String
    let taskCount: Int
    let logCount: Int

    var body: some TerminalView {
        VStack {
            Text("System Information")
                .bold()
            Divider()
            Text("")
            HStack {
                Text("  Framework:")
                    .foreground(.gray)
                Spacer()
                Text("TerminalUI v0.2")
                    .foreground(.cyan)
            }
            HStack {
                Text("  Runtime:")
                    .foreground(.gray)
                Spacer()
                Text("@MainActor + Observation")
                    .foreground(.cyan)
            }
            HStack {
                Text("  Renderer:")
                    .foreground(.gray)
                Spacer()
                Text("Attribute Graph + Enum Dispatch")
                    .foreground(.cyan)
            }
            HStack {
                Text("  Uptime:")
                    .foreground(.gray)
                Spacer()
                Text(elapsed)
                    .foreground(.white)
            }
            HStack {
                Text("  Tasks:")
                    .foreground(.gray)
                Spacer()
                Text("\(taskCount)")
                    .foreground(.white)
            }
            HStack {
                Text("  Log entries:")
                    .foreground(.gray)
                Spacer()
                Text("\(logCount)")
                    .foreground(.white)
            }
            Text("")
            Divider()
            Text("")
            Text("  Architecture")
                .bold()
            Text("  SwiftUI paradigm → terminal")
                .foreground(.gray)
            Text("  Result builders + Observation")
                .foreground(.gray)
            Text("  82,000fps idle / 700fps active")
                .foreground(.gray)
            Spacer()
        }
    }
}

struct HelpOverlay: TerminalView {
    var body: some TerminalView {
        VStack {
            Spacer()
            Text("  ╔══════════════════════════╗")
                .foreground(.cyan)
            Text("  ║   Keyboard Shortcuts     ║")
                .foreground(.cyan)
                .bold()
            Text("  ╠══════════════════════════╣")
                .foreground(.cyan)
            Text("  ║  1/2/3   Switch tabs     ║")
                .foreground(.white)
            Text("  ║  h/?     Toggle help      ║")
                .foreground(.white)
            Text("  ║  ctrl+d  Debug overlay   ║")
                .foreground(.white)
            Text("  ║  ctrl+f  Debug panel     ║")
                .foreground(.white)
            Text("  ║  q/esc   Quit            ║")
                .foreground(.white)
            Text("  ╚══════════════════════════╝")
                .foreground(.cyan)
            Spacer()
        }
    }
}

struct StatusLine: TerminalView {
    let elapsed: String
    let tab: Int

    var body: some TerminalView {
        HStack {
            Text(elapsed)
                .foreground(.gray)
            Text(" │ ")
                .foreground(.gray)
            Text("tab:\(tab + 1)")
                .foreground(.gray)
            Spacer()
            Text("h: help  q: quit")
                .foreground(.gray)
        }
    }
}

struct App: TerminalView {
    let state: AppState

    var body: some TerminalView {
        VStack {
            TitleBar(selectedTab: state.selectedTab)
            Divider()

            if state.selectedTab == 0 {
                BuildTab(
                    tasks: state.tasks,
                    spinnerFrame: state.spinnerFrame,
                    overallProgress: state.overallProgress
                )
            } else if state.selectedTab == 1 {
                LogsTab(logs: state.logs)
            } else {
                InfoTab(
                    elapsed: state.elapsed,
                    taskCount: state.tasks.count,
                    logCount: state.logs.count
                )
            }

            Spacer()
            Divider()
            StatusLine(elapsed: state.elapsed, tab: state.selectedTab)
        }
        .padding(1)
        .border(.rounded)
    }
}

// MARK: - Entry Point

@main struct Demo: TerminalAppProtocol {
    static var renderMode: RenderMode { .uncapped }

    static var timers: [TerminalTimer] {[
        TerminalTimer("spinner", every: .milliseconds(80)),
        TerminalTimer("build",   every: .milliseconds(150)),
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event {
            switch k.key {
            case .character("q"), .escape: return false
            case .character("1"): state.selectedTab = 0
            case .character("2"): state.selectedTab = 1
            case .character("3"): state.selectedTab = 2
            case .character("?"), .character("h"):
                state.showHelp.toggle()
                state.addLog(.info, "Help toggled: \(state.showHelp)")
            default: break
            }
        }

        if case .timer(let name) = event {
            switch name {
            case "spinner": state.spinnerFrame += 1
            case "build":   state.advanceBuild()
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        ZStack {
            App(state: state)
            if state.showHelp {
                HelpOverlay()
            }
        }
    }
}
