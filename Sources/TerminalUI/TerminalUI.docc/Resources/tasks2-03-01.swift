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
    var draft = ""
    var promptState = PromptInputState()
    private var nextID = 4

    var remaining: Int { tasks.filter { !$0.done }.count }

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
            // Letters belong to the text field now, so no letter quits: q would
            // end the app as the first letter of "quick fix". Escape quits, and
            // Ctrl+C always does.
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
        VStack {
            HStack {
                Text("Tasks").bold().foreground(.cyan)
                Spacer()
                Text("\(store.remaining) open").foreground(.gray)
            }
            Divider()
            ForEach(store.tasks) { task in
                TaskRow(task: task, isSelected: task.id == store.selectedID)
                    .onClick { _, _ in store.toggle(id: task.id) }
            }
            Spacer()
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
            Text("type + Enter add   click or Enter toggle   ↑↓ move   esc quit")
                .foreground(.gray)
        }
        .padding(1)
    }
}
