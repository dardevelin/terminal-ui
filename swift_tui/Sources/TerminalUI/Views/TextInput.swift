/// An editable single-line text field with cursor.
/// Handles character input, backspace, delete, and cursor movement.
///
/// The first positional argument is a persistent **prompt/label** rendered
/// before the input (SwiftUI `TextField`-style, e.g. `"Name: "`). Use
/// `placeholder:` for ghost text that disappears once the user types.
///
/// Usage:
/// ```
/// @TerminalState var name = ""
/// TextInput("Name: ", text: $name)
/// TextInput(text: $name, placeholder: "type here...")
/// ```
public struct TextInput: TerminalView {
    public let prompt: String
    public let placeholder: String
    public let text: Binding<String>

    public init(_ prompt: String = "", text: Binding<String>, placeholder: String = "") {
        self.prompt = prompt
        self.text = text
        self.placeholder = placeholder
    }

    public var body: some TerminalView {
        // GeometryReader supplies the container width so we can slide the
        // visible window when the value exceeds the field.
        GeometryReader { size in
            let value = text.get()
            let showPlaceholder = value.isEmpty && !placeholder.isEmpty
            // The whole post-prompt rect is available for value + cursor.
            // `composeSpans` reserves its own cell for the cursor glyph; HYP-90
            // rect-clip keeps any residual writes inside the assigned rect.
            let available = max(1, size.width - prompt.count)
            return Text(spans: composeSpans(
                value: value,
                showPlaceholder: showPlaceholder,
                maxValueWidth: available))
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
        }.frame(height: 1)
    }

    /// Compose the rendered spans, sliding the visible value window when
    /// `value.count + 1` (cursor) exceeds `maxValueWidth`. Keeps cursor visible
    /// at the right edge and clips from the left (classic shell-prompt behavior).
    private func composeSpans(value: String, showPlaceholder: Bool,
                               maxValueWidth: Int) -> [TextSpan] {
        var spans: [TextSpan] = []
        if !prompt.isEmpty {
            spans.append(TextSpan(prompt, foreground: .gray))
        }
        if showPlaceholder {
            // When field is empty, cursor at left then placeholder clipped to fit.
            spans.append(TextSpan("│", foreground: .default))
            let clipped = String(placeholder.prefix(max(0, maxValueWidth - 1)))
            spans.append(TextSpan(clipped, foreground: .gray))
        } else if value.isEmpty {
            spans.append(TextSpan("│", foreground: .default))
        } else {
            // Virtual horizontal scroll: cursor always pinned at the right edge
            // once the value exceeds available width. Left edge clips older chars.
            // Keep 1 cell for the cursor, so value occupies at most (maxValueWidth - 1).
            let valueRoom = max(1, maxValueWidth - 1)
            let visible: String
            if value.count <= valueRoom {
                visible = value
            } else {
                // Drop leading chars so tail + cursor fit
                visible = String(value.suffix(valueRoom))
            }
            spans.append(TextSpan(visible))
            spans.append(TextSpan("│"))
        }
        return spans
    }
}
