import Foundation
import Observation
import TerminalUI

// MARK: Model

struct TaskItem: Identifiable, Codable {
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

/// The same contract, backed by a JSON file — the reason the service is a
/// protocol. Swapping this in changes one line at the composition root;
/// the store, the commands, and every view stay untouched, and the app's
/// tasks now survive a relaunch.
struct FileTaskService: TaskService {
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tasks-tutorial.json")
    }

    func load() async -> [TaskItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let tasks = try? JSONDecoder().decode([TaskItem].self, from: data),
              !tasks.isEmpty else {
            return await InMemoryTaskService().load()
        }
        return tasks
    }

    func save(_ tasks: [TaskItem]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}

// MARK: Presentation

// Everything a row shows, decided once. The view that renders one of these
// makes no decisions — it places what it is handed.
struct TaskRowPresentation {
    let cursor: String
    let checkbox: String
    let checkboxColor: Color
    let title: String
    let titleColor: Color
}

// A label whose color carries its meaning. The header's status light and
// the detail pane's state line are both one of these.
struct StatusLight {
    let label: String
    let color: Color
}

// MARK: View-model

@Observable
final class TaskStore {
    // MARK: State
    var tasks: [TaskItem] = []
    var isLoading = true
    var spinnerFrame = 0
    var selectedID = 1
    var tab = 0
    var showCompleted = true
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

    var visibleTasks: [TaskItem] {
        showCompleted ? tasks : tasks.filter { !$0.done }
    }

    var remaining: Int { tasks.filter { !$0.done }.count }

    var completion: Double {
        tasks.isEmpty ? 1 : Double(tasks.count - remaining) / Double(tasks.count)
    }

    var selectedTask: TaskItem? {
        tasks.first { $0.id == selectedID }
    }

    // The glyph and color choices that used to live in `TaskRow`'s body.
    // Here they are named, run once per row per frame, and are testable
    // with `#expect` instead of a screenshot.
    func row(for task: TaskItem) -> TaskRowPresentation {
        TaskRowPresentation(
            cursor: task.id == selectedID ? "▸" : " ",
            checkbox: task.done ? "☑" : "☐",
            checkboxColor: task.done ? .green : .default,
            title: task.title,
            titleColor: task.done ? .gray : .default)
    }

    var statusLight: StatusLight {
        if isLoading { return StatusLight(label: "loading", color: .gray) }
        if completion == 1 { return StatusLight(label: "all done", color: .green) }
        return StatusLight(label: "\(remaining) open", color: .yellow)
    }

    func stateLight(for task: TaskItem) -> StatusLight {
        task.done
            ? StatusLight(label: "done", color: .green)
            : StatusLight(label: "open", color: .yellow)
    }

    // MARK: Commands — the only writers

    @MainActor
    func load() async {
        let loaded = await service.load()
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

nonisolated(unsafe) let store = TaskStore(service: FileTaskService())

// MARK: Views

// No conditionals left: a row renders five facts it was handed.
struct TaskRow: TerminalView {
    let presentation: TaskRowPresentation

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(presentation.cursor).foreground(.cyan)
            Text(presentation.checkbox).foreground(presentation.checkboxColor)
            Text(presentation.title).foreground(presentation.titleColor)
        }
    }
}

struct StatusText: TerminalView {
    let light: StatusLight

    var body: some TerminalView {
        Text(light.label).foreground(light.color)
    }
}

@main
struct TasksApp: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let keyEvent) = event {
            guard !store.confirmDelete else { return true }
            switch keyEvent.key {
            case .character("q") where store.draft.isEmpty: return false
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
                StatusText(light: store.stateLight(for: task))
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
            Text("type + Enter add   Enter toggle   ↑↓ move   ⌫ delete   q quit")
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
                // The three-way if/else that used to live here is now the
                // `statusLight` query — the body just places the answer.
                StatusText(light: store.statusLight)
            }
            Divider()
            if store.isLoading {
                HStack(spacing: 1) {
                    Spinner(frame: store.spinnerFrame).foreground(.cyan)
                    Text("Loading tasks…").foreground(.gray)
                }
                .task {
                    while store.isLoading {
                        try? await Task.sleep(for: .milliseconds(100))
                        store.spinnerFrame += 1
                    }
                }
            } else {
                ForEach(store.visibleTasks) { task in
                    TaskRow(presentation: store.row(for: task))
                        .onClick { _, _ in store.toggle(id: task.id) }
                }
            }
            Spacer()
        }
        .padding(1)
    }
}
