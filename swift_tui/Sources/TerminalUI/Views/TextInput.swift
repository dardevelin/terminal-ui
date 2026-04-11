/// An editable single-line text field with cursor.
/// Handles character input, backspace, delete, and cursor movement.
///
/// Usage:
/// ```
/// @TerminalState var name = ""
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
        // Display: prompt + text with cursor indicator
        // The cursor position is managed by the key handler
        HStack {
            Text(prompt)
                .foreground(.gray)
            Text(text.get().isEmpty ? "│" : text.get() + "│")
        }
        .focusable()
        .onKeyPress { [text] event in
            switch event.key {
            case .character(let c):
                // Don't insert control characters
                guard !event.modifiers.contains(.ctrl) && !event.modifiers.contains(.alt) else {
                    return .ignored
                }
                text.set(text.get() + String(c))
                return .handled

            case .backspace:
                var current = text.get()
                if !current.isEmpty {
                    current.removeLast()
                    text.set(current)
                }
                return .handled

            case .delete:
                // Delete is same as backspace for single-cursor implementation
                var current = text.get()
                if !current.isEmpty {
                    current.removeLast()
                    text.set(current)
                }
                return .handled

            case .enter:
                // Enter could submit — let it bubble up to parent handlers
                return .ignored

            default:
                return .ignored
            }
        }
    }
}
