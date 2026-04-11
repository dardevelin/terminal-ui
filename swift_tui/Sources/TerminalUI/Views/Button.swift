/// A button that triggers an action on enter/space when focused.
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
        Text("[\(label)]")
    }
}
