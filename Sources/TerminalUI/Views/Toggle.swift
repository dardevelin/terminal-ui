/// A checkbox that flips a Boolean on Enter/Space when focused.
///
/// Renders as `[x] label` when on and `[ ] label` when off, on a single
/// terminal row. It joins the Tab order through the framework's `.focusable`
/// machinery; Enter, Space, or a click on the focused row flips the binding.
/// Inside a ``Form`` the label moves to the shared label column so the
/// checkbox aligns with every sibling control. Reach for ``Button`` when the
/// press should run a one-shot action instead of holding state, or
/// ``Picker`` when the choice has more than two mutually exclusive values.
///
/// Usage:
/// ```swift
/// @TerminalState var darkMode = false
/// Toggle("Dark mode", isOn: $darkMode)
/// ```
///
/// Driven from an `@Observable` model, the way the Settings example wires
/// it (handler closures cannot read `@TerminalState`, so screens hoist
/// state into a model and hand the control a `Binding`):
/// ```swift
/// Toggle("Telemetry", isOn: Binding(
///     get: { model.telemetry }, set: { model.telemetry = $0 }
/// ))
/// ```
public struct Toggle: TerminalView {
    /// Text shown beside the checkbox — or in the shared label column
    /// inside a ``Form``.
    public let label: String
    /// The on/off state the control reads and flips.
    public let isOn: Binding<Bool>

    /// Read at body-eval time so a `.disabled()` ancestor dims the
    /// rendered checkbox + label. Behavioural half (handler gating +
    /// focus skip) ships behaviorally with the .disabled() modifier.
    @TerminalEnvironment(\.isEnabled) var isEnabled

    /// - Parameters:
    ///   - label: Text shown beside the checkbox.
    ///   - isOn: The Boolean state the control flips on activation.
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
