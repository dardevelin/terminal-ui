/// A toggle switch that toggles on enter/space when focused.
///
/// Usage:
/// ```
/// @TerminalState var darkMode = false
/// Toggle("Dark mode", isOn: $darkMode)
/// ```
public struct Toggle: TerminalView {
    public let label: String
    public let isOn: Binding<Bool>

    /// Read at body-eval time so a `.disabled()` ancestor dims the
    /// rendered checkbox + label. Behavioural half (handler gating +
    /// focus skip) ships behaviorally with the .disabled() modifier.
    @TerminalEnvironment(\.isEnabled) var isEnabled

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }

    /// Inside a `Form` the label moves to the shared column, so the checkbox
    /// lines up with every other control. Outside one, `formLabelWidth` is nil
    /// and this renders exactly as it always has: `[x] label`.
    @TerminalEnvironment(\.formLabelWidth) private var formLabelWidth

    /// `[x] label` on its own; `label   [x]` inside a `Form`, where the label
    /// belongs to the shared column instead.
    @TerminalViewBuilder private var labelledBody: some TerminalView {
        if formLabelWidth == nil {
            HStack {
                Text(isOn.get() ? "[x]" : "[ ]")
                Text(" \(label)")
            }
        } else {
            FormRow(label: label) {
                Text(isOn.get() ? "[x]" : "[ ]")
            }
        }
    }

    public var body: some TerminalView {
        labelledBody
            .foreground(isEnabled ? .default : .gray)
            .focusable()
            .onKeyPress { [isOn] event in
                // `.activate` mirrors Enter/Space for click-to-fire — see
                // Button.swift for the rationale. Without this, clicking
                // a focused Toggle synthesised `.enter` and toggled — but
                // adjacent TextArea clicks would have inserted newlines.
                // The framework now synthesises `.activate` on click;
                // Toggle accepts it.
                if event.key == .enter
                    || event.key == .character(" ")
                    || event.key == .activate
                {
                    isOn.set(!isOn.get())
                    return .handled
                }
                return .ignored
            }
    }
}

extension Toggle: _FormRowLabel {
    var formLabelText: String { label }
}
