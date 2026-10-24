import Observation
import TerminalUI

struct TaskItem: Identifiable {
    let id: Int
    var title: String
    var done = false
}

// A service is the app's only door to the outside world: everything that
// reads or writes beyond the process lives behind this protocol, and the
// store never learns which implementation it got. `Sendable` because a
// service is called from async work — every implementation has to be safe
// to carry across that boundary, so the protocol makes it a requirement.
protocol TaskService: Sendable {
    func load() async -> [TaskItem]
    func save(_ tasks: [TaskItem])
}

// The seed data and the simulated latency both moved here — the sleep
// stands in for the file read or network call a real implementation would
// make. Save has nowhere to write; an in-memory service's data already
// lives in the store. A file-backed service would write here, and nothing
// else in the app would change.
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

    // Injection is the whole point: the store works against the protocol,
    // so a test can hand it a canned service and exercise every mutation
    // below without a terminal, a delay, or a file in sight.
    private let service: any TaskService

    init(service: any TaskService) {
        self.service = service
    }

    let split = SplitState(root: .split(
        axis: .horizontal,
        children: [.leaf(TasksPane()), .leaf(DetailPane())],
        ratios: [0.6, 0.4]))

    var remaining: Int { tasks.filter { !$0.done }.count }

    var visibleTasks: [TaskItem] {
        showCompleted ? tasks : tasks.filter { !$0.done }
    }

    // The one async entry point. `@MainActor` so it can touch the store's
    // properties directly — the same isolation every other entry point
    // already runs on, stated because this one is async.
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
        guard tasks.contains(where: { $0.id == selectedID }) else { return }
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

// The concrete service appears exactly once, at the construction site.
// Swapping in a file-backed or networked service is a one-line change.
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
            if let task = store.tasks.first(where: { $0.id == store.selectedID }) {
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
        // The view no longer knows where tasks come from, how long a load
        // takes, or what the seed data is — it asks the store, and the
        // store asks whatever service it was built with.
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
                } else if store.remaining == 0 {
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
                // The animation stayed behind when the load moved out: it
                // is pure presentation, so it belongs to the view. The
                // ticker lives on the loading row itself and stops when
                // the load lands.
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
