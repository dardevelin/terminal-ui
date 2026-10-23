/// Result of validating a `TextInput`'s current value.
///
/// The severity drives the input's visual state — `.ok` renders with default
/// chrome, `.warning` tints the border yellow, `.error` tints it red. The
/// optional `message` is shown below the input when present so users can read
/// why their value was rejected.
public struct TextInputValidation: Sendable, Equatable {
    /// How the field should present the result: `.ok` default chrome,
    /// `.warning` yellow, `.error` red.
    public enum Severity: Sendable, Equatable {
        /// Value accepted — default chrome.
        case ok
        /// Value suspect — yellow border tint, input still usable.
        case warning
        /// Value rejected — red border tint.
        case error
    }
    /// Drives the field's tint.
    public let severity: Severity
    /// Shown on a row beneath the input when present.
    public let message: String?

    /// Creates a validation result.
    ///
    /// - Parameters:
    ///   - severity: Visual state the field should adopt.
    ///   - message: Optional short explanation rendered under the input.
    public init(_ severity: Severity, _ message: String? = nil) {
        self.severity = severity
        self.message = message
    }

    /// Shorthand for "the value is valid, no message."
    public static let ok = TextInputValidation(.ok)
}

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
    /// Single-row field; overflowing content scrolls horizontally.
    case horizontal
    /// Field may grow downward when the line-break mode wraps.
    case vertical
}

/// An editable single-line text field with insertion-index cursor.
///
/// Renders as one terminal row: an optional dim prompt, then the value with
/// the cursor glyph (`│`) at the insertion point while the field holds
/// focus. When the value outgrows the available width, a virtual window
/// slides over it — and only when the cursor would clip an edge, so
/// arrowing around mid-buffer does not recentre the view. Characters insert
/// at the cursor, not the tail; every other key edits with the
/// environment's ``TextKeymap``, ``TextKeymap/standard`` unless a subtree
/// sets one.
///
/// The field joins the Tab order via the framework's `.focusable`
/// machinery. While it holds focus, every printable key belongs to the
/// value — so global single-letter chords must not claim letters while a
/// text field is focused. Enter is deliberately *not* handled: it bubbles
/// to the parent, which can treat it as submit.
///
/// This is the single-line member of the text-entry trio: reach for
/// ``TextArea`` when the user is editing a document (multi-line, selection,
/// undo — Enter inserts a newline), and ``PromptInput`` for a chat/command
/// prompt (Enter submits, Up recalls history).
///
/// The first positional argument is a persistent **prompt/label** rendered
/// before the input (SwiftUI `TextField`-style, e.g. `"Name: "`). Use
/// `placeholder:` for ghost text that disappears once the user types.
/// Attach a `validate:` closure to colour the input's border and surface a
/// short error message when the value fails validation.
///
/// Usage:
/// ```swift
/// @TerminalState var name = ""
/// @TerminalState var email = ""
///
/// TextInput("Name: ", text: $name)
/// TextInput(text: $name, placeholder: "type here...")
/// TextInput(text: $email, validate: { value in
///     value.contains("@") ? .ok : TextInputValidation(.error, "missing @")
/// })
/// ```
public struct TextInput: TerminalView {
    /// Persistent label drawn dim before the value; never disappears.
    public let prompt: String
    /// Ghost text shown dim while the value is empty; gone once the user
    /// types.
    public let placeholder: String
    /// The edited value. The field reads and writes through this binding
    /// on every keystroke and paste.
    public let text: Binding<String>
    /// Runs against the current value once per render. A `.warning` or
    /// `.error` result tints the field and shows the message on a row
    /// beneath it; `nil` (no validator) keeps the default chrome.
    public let validate: ((String) -> TextInputValidation)?
    /// Growth axis — see ``TextInputAxis``. `.horizontal` (default) is
    /// always one row.
    public let axis: TextInputAxis
    /// Hard ceiling on `value.count`. When non-nil, `.character`
    /// insertions that would push the value past `maxLength` are
    /// blocked at the handler and the `.maxLength` boundary reason
    /// fires through the environment's `boundaryHit`. Backspace
    /// still works — the ceiling is not a one-way ratchet.
    public let maxLength: Int?

    /// HIG line-break behaviour for content that exceeds the field
    /// width. Default `.byClipping` matches HIG's prescription for
    /// single-line text fields. App authors override via
    /// `.lineBreakMode(_:)` on this view or any ancestor.
    @TerminalEnvironment(\.lineBreakMode) var lineBreakMode

    /// The keymap, kill ring and boundary feedback the field edits with.
    /// Read at body-eval time for the handlers, which run when no
    /// environment is bound. Set with `.textKeymap(_:)` and
    /// `.boundaryFeedback(_:)`.
    @TerminalEnvironment(\.textEditing) var textEditing

    /// Read at body-eval time. When false (a `.disabled()` ancestor
    /// has run), the rendered value is dimmed via `.foreground(.gray)`
    /// — the visual half of `.disabled()`.
    @TerminalEnvironment(\.isEnabled) var isEnabled
    @TerminalEnvironment(\.theme) private var theme

    /// Insertion index in `value` (`0...value.count`). Internal
    /// `@TerminalState` so it survives re-renders without leaking
    /// into the public API. The projected `$cursor` binding is
    /// captured in `body` (NOT inside the GR closure) so handler
    /// closures observe the same node-resident slot — see
    /// `feedback_bindings_in_geometryreader.md`.
    @TerminalState var cursor: Int = -1

    /// Stored left-edge offset of the visible window over `value`.
    /// `-1` is the uninitialised sentinel — first observation pins
    /// to the value's tail (legacy "scroll the tail into view"
    /// rendering for the typing case). Persisted across renders so
    /// the window stays put while the cursor moves WITHIN it; it
    /// only slides when the cursor would clip an edge. Same node-
    /// resident-state pattern as `cursor`.
    ///
    /// The anchor `windowedSlice` keeps, so the window slides only
    /// when the cursor would clip an edge.
    @TerminalState var windowStart: Int = -1

    /// Creates a single-row field bound to `text`.
    ///
    /// `prompt` is a persistent label before the value; `placeholder` is
    /// ghost text while the value is empty. `maxLength` `nil` means
    /// unlimited; `validate` `nil` skips validation chrome entirely.
    public init(
        _ prompt: String = "",
        text: Binding<String>,
        placeholder: String = "",
        maxLength: Int? = nil,
        validate: ((String) -> TextInputValidation)? = nil
    ) {
        self.prompt = prompt
        self.text = text
        self.placeholder = placeholder
        self.validate = validate
        self.axis = .horizontal
        self.maxLength = maxLength
    }

    /// Vertical-axis overload. When combined with a wrap-y
    /// `lineBreakMode` the field grows to fit the wrapped content;
    /// otherwise behaves like `.horizontal`.
    public init(
        _ prompt: String = "",
        text: Binding<String>,
        axis: TextInputAxis,
        placeholder: String = "",
        maxLength: Int? = nil,
        validate: ((String) -> TextInputValidation)? = nil
    ) {
        self.prompt = prompt
        self.text = text
        self.placeholder = placeholder
        self.validate = validate
        self.axis = axis
        self.maxLength = maxLength
    }

    public var body: some TerminalView {
        // Run validation once per render so severity drives both chrome
        // colour and the optional diagnostic row. Nil when no validator was
        // supplied — omit decoration entirely.
        let theme = theme
        let validation = validate?(text.get())
        let accent = Self.validationColor(validation, theme: theme)
        // Capture env-driven line-break mode at body-eval time. The
        // GR closure runs at rebuild time when GraphContext's env may
        // be nil — projecting here mirrors the pattern documented in
        // `feedback_bindings_in_geometryreader.md`.
        let mode = lineBreakMode
        let axis = self.axis

        // Project the cursor binding in `body` (NOT inside the GR
        // closure) so handler closures see the same node-resident
        // slot. Same pattern as TreeView's $expandedIDs.
        let cursorBinding = $cursor
        // Same pattern for the persisted window-start anchor. The
        // GR closure reads + writes this so the window stays put
        // while the cursor moves within it; only edge-clip events
        // (cursor < windowStart, cursor > windowStart + room - 1)
        // slide the window.
        let windowStartBinding = $windowStart

        let textEditing = self.textEditing
        let maxLength = self.maxLength

        // Input + optional error row are stacked vertically so callers can
        // just drop `TextInput(... validate:)` and see the full UX.
        return VStack {
            WidthReader { width in
                let value = text.get()
                let showPlaceholder = value.isEmpty && !placeholder.isEmpty
                // Resolve insertion index. `-1` is the uninitialized
                // sentinel — first observation snaps to value.count
                // (legacy "cursor pinned to end" behaviour for the
                // initial render). Callers seeing the binding always
                // see a clamped value.
                let resolvedCursor = Self.resolveCursor(cursorBinding.get(), valueCount: value.count)
                // The whole post-prompt rect is available for value + cursor.
                // `composeSpans` reserves its own cell for the cursor glyph;
                // rect-clip keeps any residual writes inside the rect.
                let available = max(1, width - prompt.count)
                let composed = composeSpans(
                    value: value,
                    cursor: resolvedCursor,
                    showPlaceholder: showPlaceholder,
                    maxValueWidth: available,
                    mode: mode,
                    axis: axis,
                    windowStart: windowStartBinding,
                    theme: theme)
                return TextInputRow(spans: composed.spans, caret: composed.caret)
                    .focusable()
                    .onKeyPress { [text, cursorBinding, textEditing, maxLength] event in
                        Self.handleKey(event,
                                       text: text,
                                       cursor: cursorBinding,
                                       maxLength: maxLength,
                                       textEditing: textEditing)
                    }
                    .onPaste { [text, cursorBinding, textEditing, maxLength] payload in
                        Self.handlePaste(payload,
                                         text: text,
                                         cursor: cursorBinding,
                                         maxLength: maxLength,
                                         boundaryHit: textEditing.boundaryHit)
                    }
            }
            // Single-row height for horizontal axis OR clip/truncation
            // modes (which always render single-row regardless of
            // axis). Vertical axis with wrap modes lets the GR's
            // intrinsic height (driven by Text spans' newline count)
            // grow naturally — no fixed-height frame.
            .frame(height: Self.shouldUseFixedHeight(axis: axis, mode: mode) ? 1 : nil)
            .foreground(isEnabled ? (accent ?? theme.foreground) : theme.foregroundMuted)

            if let message = validation?.message {
                Text(message).foreground(accent ?? theme.foregroundMuted)
            }
        }
    }

    /// Snap a stored cursor value to a valid insertion index for the
    /// current value length. `-1` is the uninitialized sentinel —
    /// resolves to `valueCount` so initial renders pin the cursor at
    /// the tail (legacy behaviour). Otherwise clamps into
    /// `[0, valueCount]`.
    static func resolveCursor(_ stored: Int, valueCount: Int) -> Int {
        if stored < 0 { return valueCount }
        return max(0, min(stored, valueCount))
    }

    /// Single dispatch site for key events, factored out of the body
    /// closure so the binding capture list stays small and the logic
    /// is unit-testable in isolation if needed.
    static func handleKey(_ event: KeyEvent,
                          text: Binding<String>,
                          cursor: Binding<Int>,
                          maxLength: Int?,
                          textEditing: TextEditingContext) -> KeyEventResult {
        let value = text.get()
        let pos = resolveCursor(cursor.get(), valueCount: value.count)

        /// What the field does with `command`, or nil to pass it over: a
        /// single line takes no new line, rows or history.
        func perform(_ command: TextEditCommand) -> KeyEventResult? {
            guard command.isBufferCommand, command != .insertNewline else { return nil }
            // A yank is a paste of the last kill: held to maxLength, its line
            // breaks made spaces.
            if command == .yank {
                let yanked = textEditing.killBuffer.lastKill
                guard !yanked.isEmpty else { return nil }
                handlePaste(String(yanked), text: text, cursor: cursor,
                            maxLength: maxLength, boundaryHit: textEditing.boundaryHit)
                return .handled
            }
            var buffer = TextEditingBuffer(text: Array(value), cursor: pos)
            switch textEditing.perform(command, on: &buffer) {
            case .unsupported, .unchanged:
                return nil
            case .moved, .hitWall:
                cursor.set(buffer.cursor)
            case .edited:
                text.set(String(buffer.text))
                cursor.set(buffer.cursor)
            }
            return .handled
        }

        let commands = textEditing.keymap.commands(for: event)
        if !commands.isEmpty {
            // The first command that applies wins; each runs at most once.
            for command in commands {
                if let result = perform(command) { return result }
            }
            return .ignored
        }

        guard case .character(let c) = event.key,
              !event.modifiers.contains(.ctrl), !event.modifiers.contains(.alt) else {
            // Chords no command claims bubble to the parent.
            return .ignored
        }
        // maxLength is a hard ceiling on value.count. When the buffer is
        // full, block the insert and emit .maxLength. Deleting stays
        // unrestricted so the ceiling isn't a one-way ratchet.
        if let limit = maxLength, value.count >= limit {
            textEditing.boundaryHit(.maxLength)
            return .handled
        }
        let insertAt = value.index(value.startIndex, offsetBy: pos)
        var mutated = value
        mutated.insert(c, at: insertAt)
        text.set(mutated)
        cursor.set(pos + 1)
        return .handled
    }

    /// Scalars a terminal renders as a line break. Unicode Annex #14 (Line
    /// Breaking Algorithm) class BK plus CR/LF: a single-line field must
    /// neutralise all of them, not just the ASCII pair.
    private static let lineTerminators: Set<Unicode.Scalar> = [
        "\u{000A}",  // LF
        "\u{000B}",  // VT
        "\u{000C}",  // FF
        "\u{000D}",  // CR
        "\u{0085}",  // NEL
        "\u{2028}",  // LINE SEPARATOR
        "\u{2029}",  // PARAGRAPH SEPARATOR
    ]

    /// Handle a bracketed-paste payload. TextInput is single-line, so
    /// embedded `\n` and `\r` are stripped (replaced with spaces) — the
    /// alternative would silently truncate the paste at the first
    /// newline, which is worse UX. Paste inserts at the cursor and
    /// respects `maxLength`: when the resulting value would exceed the
    /// ceiling, the paste is truncated to fit and `.maxLength` fires.
    static func handlePaste(_ payload: String,
                            text: Binding<String>,
                            cursor: Binding<Int>,
                            maxLength: Int?,
                            boundaryHit: BoundaryHitAction) {
        guard !payload.isEmpty else { return }

        // Map over unicode scalars, not Characters: "\r\n" is a SINGLE
        // grapheme cluster in Swift, equal to neither "\n" nor "\r", so a
        // per-Character map leaves CRLF untouched and a literal newline
        // survives into a single-line field. Scalar-level replacement also
        // covers the other line terminators a paste can carry — U+0085
        // NEL, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR (Unicode
        // Annex #14) — which a terminal will otherwise render as line
        // breaks inside the field.
        var insertion = String(String.UnicodeScalarView(payload.unicodeScalars.map {
            Self.lineTerminators.contains($0) ? " " : $0
        }))
        let value = text.get()
        let pos = resolveCursor(cursor.get(), valueCount: value.count)

        var truncated = false
        if let limit = maxLength {
            let room = max(0, limit - value.count)
            if insertion.count > room {
                insertion = String(insertion.prefix(room))
                truncated = true
            }
        }

        if !insertion.isEmpty {
            let insertAt = value.index(value.startIndex, offsetBy: pos)
            var mutated = value
            mutated.insert(contentsOf: insertion, at: insertAt)
            text.set(mutated)
            cursor.set(pos + insertion.count)
        }

        if truncated {
            boundaryHit(.maxLength)
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
    private static func validationColor(_ validation: TextInputValidation?, theme: any Theme) -> Color? {
        guard let validation else { return nil }
        switch validation.severity {
        case .ok: return nil
        case .warning: return theme.warning
        case .error: return theme.error
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
    ///
    /// `caret` is the index in `spans` of the cursor glyph's own span, which
    /// the row drops while the field does not hold focus.
    private func composeSpans(value: String, cursor: Int,
                               showPlaceholder: Bool,
                               maxValueWidth: Int,
                               mode: LineBreakMode,
                               axis: TextInputAxis,
                               windowStart: Binding<Int>,
                               theme: any Theme) -> (spans: [TextSpan], caret: Int?) {
        var spans: [TextSpan] = []
        if !prompt.isEmpty {
            spans.append(TextSpan(prompt, foreground: theme.foregroundMuted))
        }
        if showPlaceholder {
            // When field is empty, cursor at left then placeholder clipped to fit.
            let caret = spans.count
            spans.append(TextSpan("│"))
            let clipped = String(placeholder.prefix(max(0, maxValueWidth - 1)))
            spans.append(TextSpan(clipped, foreground: theme.foregroundFaint))
            return (spans, caret)
        }
        if value.isEmpty {
            let caret = spans.count
            spans.append(TextSpan("│"))
            return (spans, caret)
        }
        // Reserve 1 cell for the cursor glyph so the visible value
        // fits in `valueRoom` cells.
        let valueRoom = max(1, maxValueWidth - 1)

        // Vertical-axis wrap path: emit chunks separated by `\n` so
        // the Text primitive renders one row per chunk. Cursor pins
        // to the right edge of the final chunk for now (mid-buffer
        // cursor in vertical-wrap mode is tracked separately — the
        // wrap mode targets multi-line authoring where the cursor's
        // visual position depends on which display row it falls in).
        if axis == .vertical {
            switch mode {
            case .byCharWrapping, .byWordWrapping:
                let chunks = mode.wrap(value, width: valueRoom)
                for (i, chunk) in chunks.enumerated() {
                    if i > 0 { spans.append(TextSpan("\n")) }
                    spans.append(TextSpan(chunk))
                }
                let caret = spans.count
                spans.append(TextSpan("│"))
                return (spans, caret)
            case .byClipping, .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
                // Fall through to single-row path below — clipping
                // and truncation are inherently single-line.
                break
            }
        }

        // Single-row path (horizontal axis or non-wrap modes).
        // Render value with cursor glyph at the insertion index.
        switch mode {
        case .byClipping, .byCharWrapping, .byWordWrapping:
            // Virtual horizontal scroll: when the value exceeds the
            // available room, slide the visible window only when the
            // cursor would otherwise clip an edge. Persisted
            // `windowStart` anchors the window across renders so
            // arrow-left mid-buffer doesn't recentre the view.
            let result = Self.windowedSlice(
                value: value, cursor: cursor, room: valueRoom,
                windowStart: windowStart.get())
            // Persist the (possibly slid) anchor for the next frame.
            // Equality guard avoids state churn when the window didn't
            // actually move, which would otherwise mark the node dirty
            // every render.
            if result.windowStart != windowStart.get() {
                windowStart.set(result.windowStart)
            }
            let caret = Self.appendWithCursor(into: &spans,
                                              text: result.visible,
                                              cursorIndex: result.cursorOffset)
            return (spans, caret)
        case .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            // Truncation modes: apply to fit the value into
            // `valueRoom`, then drop the cursor at the matching
            // position in the visible string. Mid-buffer cursor
            // alignment under non-tail truncation is approximate —
            // the cursor lands at the visible offset, not the logical
            // one — which is a HIG-acceptable trade-off.
            let visible = mode.apply(to: value, width: valueRoom)
            let visibleCursor = min(cursor, visible.count)
            let caret = Self.appendWithCursor(into: &spans,
                                              text: visible,
                                              cursorIndex: visibleCursor)
            return (spans, caret)
        }
    }

    /// Slide a fixed-width window of `room` chars over `value` so
    /// the cursor stays visible. Returns the visible substring, the
    /// cursor's offset within it, and the (possibly updated)
    /// `windowStart` so the caller can persist it across renders.
    ///
    /// Behaviour: "scroll only when the cursor would clip" —
    ///   * Value fits in room → window covers the whole value.
    ///   * Cursor < windowStart → slide windowStart to cursor.
    ///   * Cursor > windowStart + room - 1 → slide windowStart so
    ///     cursor sits at the right edge.
    ///   * Cursor inside [windowStart, windowStart + room - 1] →
    ///     leave windowStart alone. Cursor moves WITHIN the window.
    ///
    /// `windowStart == -1` is the uninitialised sentinel: first
    /// observation pins to the tail (legacy "scroll the tail into
    /// view" rendering for the typing case).
    ///
    /// Slides only when the cursor would clip an edge: recentring every
    /// frame made the window jump when the user arrowed left
    /// mid-buffer.
    static func windowedSlice(value: String, cursor: Int, room: Int, windowStart: Int = -1)
        -> (visible: String, cursorOffset: Int, windowStart: Int)
    {
        // Whole value fits — no window math needed.
        if value.count <= room {
            return (value, cursor, 0)
        }

        let maxStart = value.count - room
        var start: Int

        if windowStart < 0 {
            // First render — pin to tail when cursor is at end (the
            // typical typing case), otherwise centre on cursor as a
            // sane default for non-typing first observation.
            start = (cursor >= value.count) ? maxStart : max(0, min(maxStart, cursor - room / 2))
        } else {
            start = windowStart
        }

        // "Scroll only when the cursor would clip" — single direction
        // per call.
        if cursor < start {
            // Clip-left → slide window left so cursor sits at offset 0.
            start = cursor
        } else if cursor > start + room - 1 {
            // Clip-right → slide window right so cursor sits at the
            // right edge. Formula `cursor - room + 1` puts the cursor
            // at offset `room - 1`. When `cursor == value.count`
            // (typing past the last char), the start clamps to
            // `maxStart` and the cursor lands at offset `room` — the
            // legacy "after-tail cursor" rendering that
            // `appendWithCursor` expects.
            start = cursor - room + 1
        }
        // Clamp into [0, maxStart].
        start = max(0, min(maxStart, start))

        let startIdx = value.index(value.startIndex, offsetBy: start)
        let endIdx = value.index(value.startIndex, offsetBy: start + room)
        return (String(value[startIdx..<endIdx]), cursor - start, start)
    }

    /// Emit `text` as a span, inserting the cursor glyph `│` at
    /// `cursorIndex` (an offset within `text`). Splits the run when
    /// the cursor is mid-buffer; appends the glyph at the tail
    /// otherwise. Returns the index of the glyph's span.
    @discardableResult
    static func appendWithCursor(into spans: inout [TextSpan], text: String, cursorIndex: Int) -> Int {
        let clamped = max(0, min(cursorIndex, text.count))
        if clamped >= text.count {
            spans.append(TextSpan(text))
            spans.append(TextSpan("│"))
            return spans.count - 1
        }
        let splitIdx = text.index(text.startIndex, offsetBy: clamped)
        let head = String(text[text.startIndex..<splitIdx])
        let tail = String(text[splitIdx..<text.endIndex])
        if !head.isEmpty {
            spans.append(TextSpan(head))
        }
        let caret = spans.count
        spans.append(TextSpan("│"))
        if !tail.isEmpty {
            spans.append(TextSpan(tail))
        }
        return caret
    }
}

/// A text field's row, drawn as a view of its own under the field's
/// focusable so it can ask whether it holds focus — `isFocused` reports to
/// the content below the focusable — and drop the caret while it does not.
/// Handed the composed spans, not the bindings, for the reason `PromptRows`
/// gives.
struct TextInputRow: TerminalView {
    let spans: [TextSpan]
    let caret: Int?

    @TerminalEnvironment(\.isFocused) var isFocused
    @TerminalEnvironment(\.cursorFlash) var cursorFlash
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        // Only the focused field reads the flash, and the theme only while it
        // is lit: a read is a subscription, and every other field would
        // redraw at each hit for nothing.
        let lit = isFocused && cursorFlash?.isLit == true
        return Text(spans: Self.visibleSpans(spans, caret: caret, isFocused: isFocused,
                                             litColor: lit ? theme.cursorColor(lit: true) : nil))
    }

    /// `spans` as drawn: the caret dropped while the field is not focused,
    /// and in `litColor` while the cursor flash is lit.
    static func visibleSpans(_ spans: [TextSpan], caret: Int?, isFocused: Bool,
                             litColor: Color?) -> [TextSpan] {
        var visible = spans
        guard let caret else { return visible }
        if !isFocused {
            visible.remove(at: caret)
        } else if let litColor {
            visible[caret].foreground = litColor
        }
        return visible
    }
}
