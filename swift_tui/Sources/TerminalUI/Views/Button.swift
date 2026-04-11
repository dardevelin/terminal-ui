/// A button that triggers an action on enter/space when focused.
/// Highlights when keyboard-focused, shows underline on mouse hover.
///
/// Usage:
/// ```
/// Button("Submit") {
///     handleSubmit()
/// }
/// ```
public struct Button: TerminalView {
    public let label: String
    public let action: () -> Void

    public init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some TerminalView {
        Text("[ \(label) ]")
            .focusable()
            .onKeyPress { event in
                if event.key == .enter || event.key == .character(" ") {
                    action()
                    return .handled
                }
                return .ignored
            }
    }
}
