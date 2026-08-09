import Observation
import TerminalUI

struct TaskItem: Identifiable {
    let id: Int
    var title: String
    var done = false
}

@Observable
final class TaskStore {
    var tasks: [TaskItem] = [
        TaskItem(id: 1, title: "Read the TerminalUI tutorial"),
        TaskItem(id: 2, title: "Build a task list"),
        TaskItem(id: 3, title: "Ship it"),
    ]
    var selectedID = 1
    var tab = 0
    var showCompleted = true
    var draft = ""
    var promptState = PromptInputState()
    private var nextID = 4

    // Completions per day, oldest first. A real app would append a bucket
    // as tasks close; seeding it gives the sparkline a shape on day one.
    var history: [Int] = [0, 2, 1, 3, 2, 5, 3, 4, 2, 6, 4, 5, 3, 6]

    // The split's panes are view values; their bodies read the store, so
    // both sides follow selection changes like any other view. The state
    // lives here so pane ratios survive re-renders.
    let split = SplitState(root: .split(
        axis: .horizontal,
        children: [.leaf(TasksPane()), .leaf(DetailPane())],
        ratios: [0.6, 0.4]))

    var remaining: Int { tasks.filter { !$0.done }.count }
    var doneCount: Int { tasks.filter(\.done).count }

    var completion: Double {
        tasks.isEmpty ? 0 : Double(doneCount) / Double(tasks.count)
    }

    var visibleTasks: [TaskItem] {
        showCompleted ? tasks : tasks.filter { !$0.done }
    }

    func addDraft() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        tasks.append(TaskItem(id: nextID, title: title))
        nextID += 1
        draft = ""
    }

    func moveSelection(_ delta: Int) {
        guard !tasks.isEmpty else { return }
        let current = tasks.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), tasks.count - 1)
        selectedID = tasks[next].id
    }

    func toggleSelected() {
        toggle(id: selectedID)
    }

    func toggle(id: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].done.toggle()
    }
}

nonisolated(unsafe) let store = TaskStore()

struct TaskRow: TerminalView {
    let task: TaskItem
    let isSelected: Bool

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(isSelected ? "▸" : " ").foreground(.cyan)
            Text(task.done ? "☑" : "☐").foreground(task.done ? .green : .default)
            Text(task.title).foreground(task.done ? .gray : .default)
        }
    }
}

@main
struct TasksApp: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let keyEvent) = event {
            switch keyEvent.key {
            // Letters belong to the text field now — a global chord on a
            // typeable key would fire while the user is writing a task.
            // Quit stays on q, but only when the draft is empty.
            case .character("q") where store.draft.isEmpty: return false
            case .escape: return false
            case .up: store.moveSelection(-1)
            case .down: store.moveSelection(1)
            // Enter submits a non-empty draft; with nothing typed it is
            // free to mean "toggle" — the same state gate as q.
            case .enter where store.draft.isEmpty: store.toggleSelected()
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        TabView(selection: Binding(get: { store.tab }, set: { store.tab = $0 })) {
            Tab("Tasks") { TasksSplit() }
            Tab("Settings") { SettingsPane() }
            Tab("Stats") { StatsPane() }
        }
    }
}

struct StatsPane: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("Stats").bold().foreground(.cyan)
            Divider()
            // Table is display-only — no cursor, no focus — which is what a
            // stats screen wants. The list keeps the interaction; this tab
            // shows the same rows as exact, aligned values.
            Table(store.tasks, columns: [
                TableColumn("Task", width: 30) { $0.title },
                TableColumn("Status", width: 6) { $0.done ? "done" : "open" },
            ])
            Text("Completions, last 14 days").foreground(.gray)
            // Both charts are flexible by default; a fixed frame keeps the
            // stack from handing either one the leftover rows.
            Sparkline(data: store.history.map(Double.init),
                      width: 40, height: 3, min: 0)
                .frame(height: 3)
                .foreground(.green)
            Text("Open vs done").foreground(.gray)
            BarChart(items: [
                BarChart.Item(label: "open", value: Double(store.remaining)),
                BarChart.Item(label: "done", value: Double(store.doneCount)),
            ], barWidth: 20)
            .frame(height: 2)
            .foreground(.cyan)
            Divider()
            // Gauge, not ProgressBar: nothing here is "completing" — the
            // ratio moves both ways as tasks are added and closed.
            Gauge(value: store.completion, label: "Done")
            Spacer()
        }
        .padding(1)
    }
}

struct SettingsPane: TerminalView {
    var body: some TerminalView {
        Form {
            Section("Display") {
                Toggle("Show completed", isOn: Binding(
                    get: { store.showCompleted },
                    set: { store.showCompleted = $0 }
                ))
            }
        }
    }
}

struct DetailPane: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("Detail").bold().foreground(.cyan)
            Divider()
            if let task = store.tasks.first(where: { $0.id == store.selectedID }) {
                Text(task.title)
                Text(task.done ? "done" : "open").foreground(task.done ? .green : .yellow)
                Text("id \(task.id)").foreground(.gray)
            } else {
                Text("Nothing selected.").foreground(.gray)
            }
            Spacer()
        }
        .padding(1)
    }
}

struct TasksSplit: TerminalView {
    var body: some TerminalView {
        VStack {
            SplitView(state: store.split)
                .flexible()
            PromptInput(
                text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                state: Binding(get: { store.promptState }, set: { store.promptState = $0 }),
                prompt: "❯",
                badge: "new",
                heightPolicy: .fixed(3),
                onSubmit: { _ in store.addDraft() }
            )
            Text("type + Enter add   click or Enter toggle   ↑↓ move   q quit")
                .foreground(.gray)
        }
    }
}

struct TasksPane: TerminalView {
    var body: some TerminalView {
        VStack {
            HStack {
                Text("Tasks").bold().foreground(.cyan)
                Spacer()
                Text("\(store.remaining) open").foreground(.gray)
            }
            Divider()
            ForEach(store.visibleTasks) { task in
                TaskRow(task: task, isSelected: task.id == store.selectedID)
                    .onClick { _, _ in store.toggle(id: task.id) }
            }
            Spacer()
        }
        .padding(1)
    }
}
