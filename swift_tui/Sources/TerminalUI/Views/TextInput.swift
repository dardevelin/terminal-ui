/// Result of validating a `TextInput`'s current value.
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
/// home/end, delete-forward) is; until then arrow
/// keys are routed to the parent and the visible cursor sits at the
/// right edge of the value. corrected this doc to match.
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
/// Layout axis for `TextInput`. Mirrors SwiftUI's `Axis` shape on
/// `TextField(_:axis:)` introduced in iOS 16 (WWDC22 *What's new in
/// SwiftUI*: *"Text fields can be configured to expand vertically
/// using the new axis parameter, growing their height to fit the
/// text..."*).
///
/// `.horizontal` (default) keeps the legacy single-line behaviour
/// — long content scrolls horizontally with the cursor pinned at
/// the right edge.
///
/// `.vertical` lets the field grow vertically when the env-driven
/// `LineBreakMode` is a wrap mode (`.byCharWrapping` /
/// `.byWordWrapping`). Clip and truncation modes still produce a
/// single-row layout regardless of axis — wrap behaviour and growth
/// envelope are separate concerns.
public enum TextInputAxis: Sendable, Equatable {
    case horizontal
    case vertical
}

public struct TextInput: TerminalView {
    public let prompt: String
    public let placeholder: String
    public let text: Binding<String>
    public let validate: ((String) -> TextInputValidation)?
    public let axis: TextInputAxis

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
        self.axis = .horizontal
    }

    /// Vertical-axis overload. When combined with a wrap-y
    /// `lineBreakMode` the field grows to fit the wrapped content;
    /// otherwise behaves like `.horizontal`.
    public init(
        _ prompt: String = "",
        text: Binding<String>,
        axis: TextInputAxis,
        placeholder: String = "",
        validate: ((String) -> TextInputValidation)? = nil
    ) {
        self.prompt = prompt
        self.text = text
        self.placeholder = placeholder
        self.validate = validate
        self.axis = axis
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
        let axis = self.axis

        // Input + optional error row are stacked vertically so callers can
        // just drop `TextInput(... validate:)` and see the full UX.
        return VStack {
            GeometryReader { size in
                let value = text.get()
                let showPlaceholder = value.isEmpty && !placeholder.isEmpty
                // The whole post-prompt rect is available for value + cursor.
                // `composeSpans` reserves its own cell for the cursor glyph;
                // rect-clip keeps any residual writes inside the rect.
                let available = max(1, size.width - prompt.count)
                return Text(spans: composeSpans(
                    value: value,
                    showPlaceholder: showPlaceholder,
                    maxValueWidth: available,
                    mode: mode,
                    axis: axis))
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
            // Single-row height for horizontal axis OR clip/truncation
            // modes (which always render single-row regardless of
            // axis). Vertical axis with wrap modes lets the GR's
            // intrinsic height (driven by Text spans' newline count)
            // grow naturally — no fixed-height frame.
            .frame(height: Self.shouldUseFixedHeight(axis: axis, mode: mode) ? 1 : nil)
            .foreground(accent ?? .default)

            if let message = validation?.message {
                Text(message).foreground(accent ?? .gray)
            }
        }
    }

    /// Decide whether the input row should be height-clamped to 1.
    /// Horizontal axis is always 1 row. Vertical axis is 1 row UNLESS
    /// the line-break mode is a wrap mode (.byCharWrapping /
    /// .byWordWrapping) — those allow the field to grow vertically.
    private static func shouldUseFixedHeight(axis: TextInputAxis, mode: LineBreakMode) -> Bool {
        if axis == .horizontal { return true }
        switch mode {
        case .byCharWrapping, .byWordWrapping:
            return false
        case .byClipping, .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            return true
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
    /// `LineBreakMode` to fit the value into `maxValueWidth`. Behaviour:
    ///
    /// - `axis == .horizontal` (default): always single-row. Wrap
    ///   modes degrade to clipping; truncation modes apply ellipsis;
    ///   clipping shows the tail with cursor pinned right.
    ///
    /// - `axis == .vertical` with a wrap mode: emit multi-row spans
    ///   (chunks separated by `\n`) via `LineBreakMode.wrap`. Cursor
    ///   sits at the right edge of the LAST chunk. The body's frame
    ///   leaves height unconstrained so the GR sees the full
    ///   intrinsic chunk count.
    ///
    /// - `axis == .vertical` with clip/truncation modes: still
    ///   single-row (clipping is inherently single-line).
    private func composeSpans(value: String, showPlaceholder: Bool,
                               maxValueWidth: Int,
                               mode: LineBreakMode,
                               axis: TextInputAxis) -> [TextSpan] {
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

        // Vertical-axis wrap path: emit chunks separated by `\n` so
        // the Text primitive renders one row per chunk. Cursor pins
        // to the right edge of the final chunk.
        if axis == .vertical {
            switch mode {
            case .byCharWrapping, .byWordWrapping:
                let chunks = mode.wrap(value, width: valueRoom)
                for (i, chunk) in chunks.enumerated() {
                    if i > 0 { spans.append(TextSpan("\n")) }
                    spans.append(TextSpan(chunk))
                    if i == chunks.count - 1 {
                        spans.append(TextSpan("│"))
                    }
                }
                return spans
            case .byClipping, .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
                // Fall through to single-row path below — clipping
                // and truncation are inherently single-line.
                break
            }
        }

        // Single-row path (horizontal axis or non-wrap modes).
        switch mode {
        case .byClipping, .byCharWrapping, .byWordWrapping:
            // Virtual horizontal scroll: cursor always pinned at the
            // right edge once the value exceeds available width. Left
            // edge clips older chars. Wrap modes on horizontal axis
            // degrade to clipping (vertical axis above handled them).
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
