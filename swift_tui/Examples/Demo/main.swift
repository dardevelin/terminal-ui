import Foundation
import TerminalUI

// State
nonisolated(unsafe) var spinnerFrame: Int = 0
nonisolated(unsafe) var progress: Double = 0.0
let startTime = Date()
nonisolated(unsafe) var logMessages: [(String, Color)] = []
nonisolated(unsafe) var lastTaskLogged = ""

let taskList: [(String, Double)] = [
    ("compiling sources", 0.3),
    ("linking modules",   0.5),
    ("running tests",     0.7),
    ("generating docs",   0.85),
    ("packaging binary",  1.0),
]

func currentTask() -> String {
    for (name, threshold) in taskList {
        if progress < threshold { return name }
    }
    return "done"
}

func advanceBuild() {
    if progress < 1.0 {
        progress = min(1.0, progress + 0.005)
    }

    let task = currentTask()
    if task != lastTaskLogged {
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
        logMessages.append(("[\(elapsed)] \(task)...", .gray))
        lastTaskLogged = task
    }

    if progress >= 1.0 && !logMessages.contains(where: { $0.0.contains("complete") }) {
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
        logMessages.append(("[\(elapsed)] build complete", .green))
    }
}

// Views

struct Header: TerminalView {
    var body: some TerminalView {
        HStack {
            Text("swift_tui")
                .foreground(.cyan)
                .bold()
            Spacer()
            Text("prototype v0.1")
                .foreground(.gray)
        }
    }
}

struct BuildStatus: TerminalView {
    let spinnerFrame: Int
    let progress: Double
    let task: String

    var body: some TerminalView {
        VStack {
            HStack {
                Spinner(frame: spinnerFrame, style: .dots)
                    .foreground(.cyan)
                Text(" \(task)")
            }
            ProgressBar(value: progress, label: "build")
                .foreground(progress < 1.0 ? .yellow : .green)
        }
    }
}

struct LogView: TerminalView {
    let messages: [(String, Color)]

    var body: some TerminalView {
        Text(messages.suffix(10).map(\.0).joined(separator: "\n"))
            .foreground(.gray)
    }
}

struct StatusBar: TerminalView {
    let elapsed: String

    var body: some TerminalView {
        HStack {
            Text(elapsed)
                .foreground(.gray)
            Spacer()
            Text("q: quit")
                .foreground(.gray)
        }
    }
}

// App — each timer runs at its own rate

@main struct Demo: TerminalAppProtocol {
    // Render at 30fps — the framework checks for dirty state this often
    static var renderMode: RenderMode { .uncapped }

    // Independent animation clocks
    static var timers: [TerminalTimer] {[
        TerminalTimer("spinner", every: .milliseconds(80)),   // spinner cycles fast
        TerminalTimer("build",   every: .milliseconds(100)),  // build advances steadily
    ]}

    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event, k.key == .character("q") { return false }
        if case .key(let k) = event, k.key == .escape { return false }

        // Each timer updates only its own state
        if case .timer(let name) = event {
            switch name {
            case "spinner": spinnerFrame += 1
            case "build":   advanceBuild()
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))

        VStack {
            Header()
            Text("")
            BuildStatus(spinnerFrame: spinnerFrame, progress: progress, task: currentTask())
            Text("")
            LogView(messages: logMessages)
            Spacer()
            StatusBar(elapsed: elapsed)
        }
        .padding(1)
        .border(.rounded)
    }
}
