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
    var tab = 0
    var showCompleted = true
    var draft = ""
    var promptState = PromptInputState()
    // The path is the model: a link pushes a task id onto it, Esc pops it,
    // and the stack shows whatever screen the top id resolves to.
    var path: [Int] = []
    private var nextID = 4

    var remaining: Int { tasks.filter { !$0.done }.count }

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
}

nonisolated(unsafe) let store = TaskStore()

struct TaskRow: TerminalView {
    let task: TaskItem

    var body: some TerminalView {
        HStack(spacing: 1) {
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
            // Letters belong to the text field now, so no letter quits: q would
            // end the app as the first letter of "quick fix". Ctrl+C always
            // quits, and Esc does too — but only at the root. While a screen is
            // pushed the runtime hands Esc to the stack instead, which pops.
            case .escape: return false
            // The arrow and Enter cases are gone: the rows are focusable
            // links now, so the focus engine moves between them and Enter
            // activates the focused one.
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        TabView(selection: Binding(get: { store.tab }, set: { store.tab = $0 })) {
            Tab("Tasks") { TasksTab() }
            Tab("Settings") { SettingsPane() }
        }
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

struct TaskDetail: TerminalView {
    let taskID: Int

    var body: some TerminalView {
        VStack {
            if let task = store.tasks.first(where: { $0.id == taskID }) {
                Text(task.title)
                Text(task.done ? "done" : "open").foreground(task.done ? .green : .yellow)
                Text("id \(task.id)").foreground(.gray)
            }
        }
        .padding(1)
        .navigationTitle("Detail")
    }
}

struct TasksTab: TerminalView {
    var body: some TerminalView {
        NavigationStack(path: Binding(
            get: { store.path }, set: { store.path = $0 }
        )) {
            VStack {
                TaskList()
                PromptInput(
                    text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                    state: Binding(get: { store.promptState }, set: { store.promptState = $0 }),
                    prompt: "❯",
                    badge: "new",
                    heightPolicy: .fixed(3),
                    onSubmit: { _ in store.addDraft() }
                )
                // The arrows move focus between the rows, so the prompt gives them
                // up; Ctrl+P and Ctrl+N still recall what was typed before.
                .textKeymap(.standard.merging([.keyboard(.up, []): [], .keyboard(.down, []): []]))
                Text("type + Enter add   ↑↓ move   Enter open   esc quit")
                    .foreground(.gray)
            }
        }
        .navigationDestination(for: Int.self) { taskID in
            TaskDetail(taskID: taskID)
        }
    }
}

struct TaskList: TerminalView {
    var body: some TerminalView {
        VStack {
            HStack {
                Text("Tasks").bold().foreground(.cyan)
                Spacer()
                Text("\(store.remaining) open").foreground(.gray)
            }
            Divider()
            ForEach(store.visibleTasks) { task in
                NavigationLink(value: task.id) {
                    TaskRow(task: task)
                }
            }
        }
        .padding(1)
    }
}
