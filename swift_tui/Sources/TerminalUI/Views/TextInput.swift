/// Result of validating a `TextInput`'s current value (HYP-82 #3).
///
/// The severity drives the input's visual state — `.ok` renders with default
/// chrome, `.warning` tints the border yellow, `.error` tints it red. The
/// optional `message` is shown below the input when present so users can read
/// why their value was rejected.
public struct TextInputValidation: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case ok, warning, error
    }
    public let severity: Severity
    public let message: String?

    public init(_ severity: Severity, _ message: String? = nil) {
        self.severity = severity
        self.message = message
    }

    /// Shorthand for "the value is valid, no message."
    public static let ok = TextInputValidation(.ok)
}

/// An editable single-line text field.
/// Currently appends typed characters and removes from the tail on
/// backspace / delete. A real cursor model (insertion index, left/right,
/// home/end, delete-forward) is tracked under HYP-73; until then arrow
/// keys are routed to the parent and the visible cursor sits at the
/// right edge of the value. HYP-103 corrected this doc to match.
///
/// The first positional argument is a persistent **prompt/label** rendered
/// before the input (SwiftUI `TextField`-style, e.g. `"Name: "`). Use
/// `placeholder:` for ghost text that disappears once the user types.
/// Attach a `validate:` closure to colour the input's border and surface a
/// short error message when the value fails validation.
///
/// Usage:
/// ```
/// @TerminalState var name = ""
/// TextInput("Name: ", text: $name)
/// TextInput(text: $name, placeholder: "type here...")
/// TextInput(text: $email, validate: { v in
///     v.contains("@") ? .ok : TextInputValidation(.error, "missing @")
/// })
/// ```
public struct TextInput: TerminalView {
    public let prompt: String
    public let placeholder: String
    public let text: Binding<String>
    public let validate: ((String) -> TextInputValidation)?

    /// HIG line-break behaviour for content that exceeds the field
    /// width. Default `.byClipping` matches HIG's prescription for
    /// single-line text fields. App authors override via
    /// `.lineBreakMode(_:)` on this view or any ancestor.
    @TerminalEnvironment(\.lineBreakMode) var lineBreakMode

    public init(
        _ prompt: String = "",
        text: Binding<String>,
        placeholder: String = "",
        validate: ((String) -> TextInputValidation)? = nil
    ) {
        self.prompt = prompt
        self.text = text
        self.placeholder = placeholder
        self.validate = validate
    }

    public var body: some TerminalView {
        // Run validation once per render so severity drives both chrome
        // colour and the optional diagnostic row. Nil when no validator was
        // supplied — omit decoration entirely.
        let validation = validate?(text.get())
        let accent = validationColor(validation)
        // Capture env-driven line-break mode at body-eval time. The
        // GR closure runs at rebuild time when GraphContext's env may
        // be nil — projecting here mirrors the pattern documented in
        // `feedback_bindings_in_geometryreader.md`.
        let mode = lineBreakMode

        // Input + optional error row are stacked vertically so callers can
        // just drop `TextInput(... validate:)` and see the full UX.
        return VStack {
            GeometryReader { size in
                let value = text.get()
                let showPlaceholder = value.isEmpty && !placeholder.isEmpty
                // The whole post-prompt rect is available for value + cursor.
                // `composeSpans` reserves its own cell for the cursor glyph;
                // HYP-90 rect-clip keeps any residual writes inside the rect.
                let available = max(1, size.width - prompt.count)
                return Text(spans: composeSpans(
                    value: value,
                    showPlaceholder: showPlaceholder,
                    maxValueWidth: available,
                    mode: mode))
                    .focusable()
                    .onKeyPress { [text] event in
                        switch event.key {
                        case .character(let c):
                            guard !event.modifiers.contains(.ctrl) && !event.modifiers.contains(.alt) else {
                                return .ignored
                            }
                            text.set(text.get() + String(c))
                            return .handled

                        case .backspace, .delete:
                            var current = text.get()
                            if !current.isEmpty {
                                current.removeLast()
                                text.set(current)
                            }
                            return .handled

                        case .enter:
                            // Let Enter bubble up so parent handlers can submit.
                            return .ignored

                        default:
                            return .ignored
                        }
                    }
            }
            .frame(height: 1)
            .foreground(accent ?? .default)

            if let message = validation?.message {
                Text(message).foreground(accent ?? .gray)
            }
        }
    }

    /// Map validation severity to an accent colour. Returns `nil` when no
    /// validator was attached so the callers keep their default appearance.
    private func validationColor(_ validation: TextInputValidation?) -> Color? {
        guard let validation else { return nil }
        switch validation.severity {
        case .ok: return nil
        case .warning: return .yellow
        case .error: return .red
        }
    }

    /// Compose the rendered spans, applying the env-driven
    /// `LineBreakMode` to fit the value into `maxValueWidth`. Default
    /// `.byClipping` keeps the legacy "virtual horizontal scroll"
    /// behaviour (tail + cursor pinned right). Truncation modes
    /// transform the value with an ellipsis at head / middle / tail
    /// while leaving the cursor at the right edge of the visible
    /// content. Wrap modes (`.byCharWrapping`, `.byWordWrapping`)
    /// are accepted for symmetry but currently render as if
    /// `.byClipping` — multi-row TextInput needs the SwiftUI-style
    /// `axis: .vertical` shape, tracked separately.
    private func composeSpans(value: String, showPlaceholder: Bool,
                               maxValueWidth: Int,
                               mode: LineBreakMode) -> [TextSpan] {
        var spans: [TextSpan] = []
        if !prompt.isEmpty {
            spans.append(TextSpan(prompt, foreground: .gray))
        }
        if showPlaceholder {
            // When field is empty, cursor at left then placeholder clipped to fit.
            spans.append(TextSpan("│", foreground: .default))
            let clipped = String(placeholder.prefix(max(0, maxValueWidth - 1)))
            spans.append(TextSpan(clipped, foreground: .gray))
            return spans
        }
        if value.isEmpty {
            spans.append(TextSpan("│", foreground: .default))
            return spans
        }
        // Reserve 1 cell for the cursor glyph so the visible value
        // fits in `valueRoom` cells.
        let valueRoom = max(1, maxValueWidth - 1)

        switch mode {
        case .byClipping, .byCharWrapping, .byWordWrapping:
            // Virtual horizontal scroll: cursor always pinned at the
            // right edge once the value exceeds available width. Left
            // edge clips older chars. Wrap modes degrade to clipping
            // on a single-line input (axis:.vertical work tracked
            // separately).
            let visible: String
            if value.count <= valueRoom {
                visible = value
            } else {
                visible = String(value.suffix(valueRoom))
            }
            spans.append(TextSpan(visible))
            spans.append(TextSpan("│"))
        case .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            // Apply the truncation mode to fit the value into
            // `valueRoom`. Cursor lands at the right edge of the
            // truncated string for visual consistency with clipping.
            let visible = mode.apply(to: value, width: valueRoom)
            spans.append(TextSpan(visible))
            spans.append(TextSpan("│"))
        }
        return spans
    }
}
