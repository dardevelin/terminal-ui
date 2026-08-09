import TerminalUI

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
