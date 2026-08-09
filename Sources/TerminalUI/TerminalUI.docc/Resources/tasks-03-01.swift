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

    func moveSelection(_ delta: Int) {
        guard !tasks.isEmpty else { return }
        let current = tasks.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), tasks.count - 1)
        selectedID = tasks[next].id
    }
}

nonisolated(unsafe) let store = TaskStore()

struct TaskRow: TerminalView {
    let task: TaskItem
    let isSelected: Bool

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(isSelected ? "▸" : " ")
            Text(task.done ? "☑" : "☐")
            Text(task.title)
        }
    }
}

@main
struct TasksApp: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let keyEvent) = event {
            switch keyEvent.key {
            case .character("q"), .escape: return false
            case .up, .character("k"): store.moveSelection(-1)
            case .down, .character("j"): store.moveSelection(1)
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        VStack {
            Text("Tasks").bold()
            Divider()
            ForEach(store.tasks) { task in
                TaskRow(task: task, isSelected: task.id == store.selectedID)
            }
            Spacer()
        }
    }
}
