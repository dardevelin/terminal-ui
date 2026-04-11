/// An editable text field.
///
/// Usage:
/// ```
/// TextInput("Name: ", text: $name)
/// ```
public struct TextInput: TerminalView {
    public let prompt: String
    public let text: Binding<String>

    public init(_ prompt: String = "", text: Binding<String>) {
        self.prompt = prompt
        self.text = text
    }

    public var body: some TerminalView {
        Text("\(prompt)\(text.get())_")
    }
}
