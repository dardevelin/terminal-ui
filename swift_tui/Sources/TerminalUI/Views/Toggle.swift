/// A toggle switch.
///
/// Usage:
/// ```
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
    }
}
