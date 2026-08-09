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
}

nonisolated(unsafe) let store = TaskStore()

struct TaskRow: TerminalView {
    let task: TaskItem

    var body: some TerminalView {
        HStack(spacing: 1) {
            Text(task.done ? "☑" : "☐")
            Text(task.title)
        }
    }
}

@main
struct TasksApp: TerminalAppProtocol {
    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let keyEvent) = event,
           keyEvent.key == .character("q") || keyEvent.key == .escape {
            return false
        }
        return true
    }

    static func content() -> some TerminalView {
        VStack {
            Text("Tasks").bold()
            Divider()
            ForEach(store.tasks) { task in
                TaskRow(task: task)
            }
            Spacer()
        }
    }
}
