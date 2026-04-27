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

    /// Read at body-eval time. When false (a `.disabled()` ancestor
    /// has run), the label paints in `.gray` so users see the button
    /// is non-interactive. Pairs with the behavioral half of
    /// `.disabled()` (handler gating + focus skip).
    @TerminalEnvironment(\.isEnabled) var isEnabled

    public init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some TerminalView {
        Text("[ \(label) ]")
            .foreground(isEnabled ? .default : .gray)
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
