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
    // Presentation state is state like any other: the dialog is on screen
    // exactly while this is true, and both the presenting modifier and the
    // key handling read it from the same place.
    var confirmDelete = false
    private var nextID = 4

    // The split's panes are view values; their bodies read the store, so
    // both sides follow selection changes like any other view. The state
    // lives here so pane ratios survive re-renders.
    let split = SplitState(root: .split(
        axis: .horizontal,
        children: [.leaf(TasksPane()), .leaf(DetailPane())],
        ratios: [0.6, 0.4]))

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

    func requestDelete() {
        // Nothing selected means nothing to confirm — don't present a
        // dialog whose Delete would do nothing.
        guard tasks.contains(where: { $0.id == selectedID }) else { return }
        confirmDelete = true
    }

    func deleteSelected() {
        guard let index = tasks.firstIndex(where: { $0.id == selectedID }) else { return }
        tasks.remove(at: index)
        guard !tasks.isEmpty else { return }
        // Land the cursor on the row that slid into the gap, or on the new
        // last row when the deleted task was at the bottom.
        selectedID = tasks[min(index, tasks.count - 1)].id
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
            // While the dialog is up it owns the keyboard: the app's
            // bindings stand aside so Enter presses the focused dialog
            // button instead of toggling a task behind it. (Escape needs
            // no help — the framework refuses an onEvent quit while a
            // modal contains focus, so Escape closes the dialog first.)
            guard !store.confirmDelete else { return true }
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
            // Destructive, so it only asks. Backspace rather than a letter:
            // handled keys still reach the focused prompt, so a letter
            // chord would also type itself into the draft — the same
            // reasoning that gated q. With an empty draft Backspace has
            // nothing to erase, leaving it free to mean "delete task".
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
            Text("type + Enter add   Enter toggle   ↑↓ move   ⌫ delete   q quit")
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
