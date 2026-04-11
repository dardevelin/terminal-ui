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

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }

    public var body: some TerminalView {
        HStack {
            Text(isOn.get() ? "[x]" : "[ ]")
            Text(" \(label)")
        }
        .focusable()
        .onKeyPress { [isOn] event in
            if event.key == .enter || event.key == .character(" ") {
                isOn.set(!isOn.get())
                return .handled
            }
            return .ignored
        }
    }
}
