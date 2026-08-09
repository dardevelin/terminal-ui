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

// The framework calls onEvent and content() on the main thread; file-scope
// state with nonisolated(unsafe) is the pattern the bundled examples use.
nonisolated(unsafe) let store = TaskStore()

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
            Text("Nothing here yet.").foreground(.gray)
        }
    }
}
