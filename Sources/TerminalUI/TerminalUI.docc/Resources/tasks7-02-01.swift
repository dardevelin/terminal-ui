import Observation
import TerminalUI

struct TaskItem: Identifiable {
    let id: Int
    var title: String
    var done = false
}

protocol TaskService: Sendable {
    func load() async -> [TaskItem]
    func save(_ tasks: [TaskItem])
}

struct InMemoryTaskService: TaskService {
    func load() async -> [TaskItem] {
        try? await Task.sleep(for: .seconds(4))
        return [
            TaskItem(id: 1, title: "Read the TerminalUI tutorial"),
            TaskItem(id: 2, title: "Build a task list"),
            TaskItem(id: 3, title: "Ship it"),
        ]
    }

    func save(_ tasks: [TaskItem]) { }
}

@Observable
final class TaskStore {
    // MARK: State
    // Stored properties are private territory: views read the queries below,
    // and change state through the commands. The one sanctioned exception is
    // a control's binding — the prompt's draft, the tab, the Settings toggle —
    // which writes the property it edits, as SwiftUI's controls do.
    var tasks: [TaskItem] = []
    var isLoading = true
    var spinnerFrame = 0
    var selectedID = 1
    var tab = 0
    var showCompleted = true {
        // Hiding the selected task would leave the selection — and the
        // detail pane — on a row the reader cannot see.
        didSet {
            if !visibleTasks.contains(where: { $0.id == selectedID }) {
                selectedID = visibleTasks.first?.id ?? selectedID
            }
        }
    }
    var draft = ""
    var promptState = PromptInputState()
    var confirmDelete = false
    private var nextID = 1
    private let service: any TaskService

    init(service: any TaskService) {
        self.service = service
    }

    let split = SplitState(root: .split(
        axis: .horizontal,
        children: [.leaf(TasksPane()), .leaf(DetailPane())],
        ratios: [0.6, 0.4]))

    // MARK: Queries — what views render
    // Reads only. Every derived fact the UI shows has a name here, computed
    // in exactly one place.

    var visibleTasks: [TaskItem] {
        showCompleted ? tasks : tasks.filter { !$0.done }
    }

    var remaining: Int { tasks.filter { !$0.done }.count }

    // An empty list is vacuously complete — the same answer the old
    // `remaining == 0` check gave, now with a name the header can read.
    var completion: Double {
        tasks.isEmpty ? 1 : Double(tasks.count - remaining) / Double(tasks.count)
    }

    var selectedTask: TaskItem? {
        tasks.first { $0.id == selectedID }
    }

    // MARK: Commands — the only writers
    // Every state mutation in the app goes through one of these, named for
    // the user's intent, not for the fields it touches.

    @MainActor
    func load() async {
        // `.task` runs each time its view appears, so this runs again when
        // the reader comes back from Settings; the tasks load once.
        guard isLoading else { return }
        let loaded = await service.load()
        // Left before the load landed: the next appearance loads again.
        guard !Task.isCancelled else { return }
        tasks = loaded
        nextID = (loaded.map(\.id).max() ?? 0) + 1
        selectedID = loaded.first?.id ?? selectedID
        isLoading = false
    }

    func addDraft() {
        let title = draft.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        tasks.append(TaskItem(id: nextID, title: title))
        nextID += 1
        draft = ""
        service.save(tasks)
    }

    func moveSelection(_ delta: Int) {
        // Over the rows on screen: with completed tasks hidden, a step
        // through `tasks` could land on one the reader cannot see.
        let rows = visibleTasks
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedID = rows[next].id
    }

    func toggleSelected() {
        toggle(id: selectedID)
    }

    func toggle(id: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].done.toggle()
        service.save(tasks)
    }

    func requestDelete() {
        guard selectedTask != nil else { return }
        confirmDelete = true
    }

    func deleteSelected() {
        guard let index = tasks.firstIndex(where: { $0.id == selectedID }) else { return }
        tasks.remove(at: index)
        service.save(tasks)
        guard !tasks.isEmpty else { return }
        selectedID = tasks[min(index, tasks.count - 1)].id
    }
}

nonisolated(unsafe) let store = TaskStore(service: InMemoryTaskService())

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

// Handlers call commands; bodies render queries. `onEvent` is the clearest
// example: every case is one command, and it reads no state beyond the two
// gates that decide routing.
@main
struct TasksApp: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let keyEvent) = event {
            guard !store.confirmDelete else { return true }
            switch keyEvent.key {
            case .escape: return false
            case .up: store.moveSelection(-1)
            case .down: store.moveSelection(1)
            case .enter where store.draft.isEmpty: store.toggleSelected()
            case .backspace where store.draft.isEmpty:
                store.requestDelete()
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        TabView(selection: Binding(get: { store.tab }, set: { store.tab = $0 })) {
            Tab("Tasks") { TasksSplit() }
            Tab("Settings") { SettingsPane() }
        }
        .confirmationDialog(
            "Delete task?",
            isPresented: Binding(get: { store.confirmDelete },
                                 set: { store.confirmDelete = $0 }),
            message: "This cannot be undone."
        ) {
            AlertAction("Delete", role: .destructive) { store.deleteSelected() }
            AlertAction("Cancel", role: .cancel) { }
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

struct DetailPane: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("Detail").bold().foreground(.cyan)
            Divider()
            if let task = store.selectedTask {
                Text(task.title)
                Text(task.done ? "done" : "open").foreground(task.done ? .green : .yellow)
                Text("id \(task.id)").foreground(.gray)
            } else {
                Text(store.isLoading ? "Loading…" : "Nothing selected.")
                    .foreground(.gray)
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
            // The arrows move the list's selection, so the prompt gives them
            // up; Ctrl+P and Ctrl+N still recall what was typed before.
            .textKeymap(.standard.merging([.keyboard(.up, []): [], .keyboard(.down, []): []]))
            Text("type + Enter add   Enter toggle   ↑↓ move   ⌫ delete   esc quit")
                .foreground(.gray)
        }
        .task {
            await store.load()
        }
    }
}

struct TasksPane: TerminalView {
    var body: some TerminalView {
        VStack {
            HStack {
                Text("Tasks").bold().foreground(.cyan)
                Spacer()
                if store.isLoading {
                    Text("loading").foreground(.gray)
                } else if store.completion == 1 {
                    Text("all done").foreground(.green)
                } else {
                    Text("\(store.remaining) open").foreground(.yellow)
                }
            }
            Divider()
            if store.isLoading {
                HStack(spacing: 1) {
                    Spinner(frame: store.spinnerFrame).foreground(.cyan)
                    Text("Loading tasks…").foreground(.gray)
                }
                .task {
                    while store.isLoading && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        store.spinnerFrame += 1
                    }
                }
            } else {
                ForEach(store.visibleTasks) { task in
                    TaskRow(task: task, isSelected: task.id == store.selectedID)
                        .onClick { _, _ in store.toggle(id: task.id) }
                }
            }
            Spacer()
        }
        .padding(1)
    }
}
