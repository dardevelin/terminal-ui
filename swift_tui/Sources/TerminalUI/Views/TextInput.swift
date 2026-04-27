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

/// An editable single-line text field with insertion-index cursor.
///
/// Left/Right move the cursor by one character clamped to `[0, value.count]`;
/// Home/End jump to the extremes. Character insertion + backspace operate
/// at the cursor index, not the tail. The visible cursor glyph (`│`)
/// renders at the insertion point.
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

    /// Boundary-feedback mode read at body-eval time. Drives the
    /// `BoundaryFeedbackEmitter.shared.emit` calls at the wall sites
    /// in `handleKey` (cursor at 0 + Left, cursor at value.count +
    /// Right). Captured via env so app authors override per subtree
    /// with `.boundaryFeedback(_:)`.
    @TerminalEnvironment(\.boundaryFeedback) var boundaryFeedback

    /// Optional `.onBoundaryHit { reason in ... }` callback registered
    /// by an ancestor. Forwarded to the emitter so `.modal` mode
    /// dispatches to app code instead of the bell/bounce sinks.
    @TerminalEnvironment(\.onBoundaryHit) var onBoundaryHit

    /// Insertion index in `value` (`0...value.count`). Internal
    /// `@TerminalState` so it survives re-renders without leaking
    /// into the public API. The projected `$cursor` binding is
    /// captured in `body` (NOT inside the GR closure) so handler
    /// closures observe the same node-resident slot — see
    /// `feedback_bindings_in_geometryreader.md`.
    @TerminalState var cursor: Int = -1

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

        // Project the cursor binding in `body` (NOT inside the GR
        // closure) so handler closures see the same node-resident
        // slot. Same pattern as TreeView's $expandedIDs.
        let cursorBinding = $cursor

        // Capture env-resolved boundary-feedback channels at body
        // eval. The handler closure runs later when GraphContext's
        // env may be unset; passing the captured values keeps the
        // emit path deterministic.
        let boundaryMode = boundaryFeedback
        let onBoundaryHit = self.onBoundaryHit

        // Input + optional error row are stacked vertically so callers can
        // just drop `TextInput(... validate:)` and see the full UX.
        return VStack {
            GeometryReader { size in
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
                let available = max(1, size.width - prompt.count)
                return Text(spans: composeSpans(
                    value: value,
                    cursor: resolvedCursor,
                    showPlaceholder: showPlaceholder,
                    maxValueWidth: available,
                    mode: mode,
                    axis: axis))
                    .focusable()
                    .onKeyPress { [text, cursorBinding, boundaryMode, onBoundaryHit] event in
                        Self.handleKey(event,
                                       text: text,
                                       cursor: cursorBinding,
                                       boundaryMode: boundaryMode,
                                       onBoundaryHit: onBoundaryHit)
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
    ///
    /// `boundaryMode` + `onBoundaryHit` are env values captured at
    /// body-eval time and threaded in so the wall-hit emit path
    /// works without re-reading `GraphContext.currentEnvironment`
    /// (which would be nil inside the deferred handler closure).
    static func handleKey(_ event: KeyEvent,
                          text: Binding<String>,
                          cursor: Binding<Int>,
                          boundaryMode: BoundaryFeedback,
                          onBoundaryHit: BoundaryHitCallback?) -> KeyEventResult {
        let value = text.get()
        let pos = resolveCursor(cursor.get(), valueCount: value.count)

        // Synthesize the env slice the emitter actually consults so
        // the call site doesn't need to know which fields matter.
        var env = EnvironmentValues()
        env.boundaryFeedback = boundaryMode
        env.onBoundaryHit = onBoundaryHit

        switch event.key {
        case .character(let c):
            guard !event.modifiers.contains(.ctrl) && !event.modifiers.contains(.alt) else {
                return .ignored
            }
            let insertAt = value.index(value.startIndex, offsetBy: pos)
            var mutated = value
            mutated.insert(c, at: insertAt)
            text.set(mutated)
            cursor.set(pos + 1)
            return .handled

        case .backspace:
            // Remove the char BEFORE the cursor; clamp at 0.
            guard pos > 0 else { return .handled }
            let removeAt = value.index(value.startIndex, offsetBy: pos - 1)
            var mutated = value
            mutated.remove(at: removeAt)
            text.set(mutated)
            cursor.set(pos - 1)
            return .handled

        case .delete:
            // Forward delete — remove char AT the cursor; no-op at end.
            guard pos < value.count else { return .handled }
            let removeAt = value.index(value.startIndex, offsetBy: pos)
            var mutated = value
            mutated.remove(at: removeAt)
            text.set(mutated)
            return .handled

        case .left:
            if pos == 0 {
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .leftEdge, env: env, callback: onBoundaryHit)
            } else {
                cursor.set(pos - 1)
            }
            return .handled

        case .right:
            if pos == value.count {
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .rightEdge, env: env, callback: onBoundaryHit)
            } else {
                cursor.set(pos + 1)
            }
            return .handled

        case .home:
            cursor.set(0)
            return .handled

        case .end:
            cursor.set(value.count)
            return .handled

        case .enter:
            // Let Enter bubble up so parent handlers can submit.
            return .ignored

        default:
            return .ignored
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
    private func composeSpans(value: String, cursor: Int,
                               showPlaceholder: Bool,
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
        // Render value with cursor glyph at the insertion index.
        switch mode {
        case .byClipping, .byCharWrapping, .byWordWrapping:
            // Virtual horizontal scroll: when the value exceeds the
            // available room, slide the visible window so the cursor
            // is always on screen. Window anchors to the cursor's
            // tail when cursor is at end (legacy behaviour preserved).
            let (visible, visibleCursor) = Self.windowedSlice(
                value: value, cursor: cursor, room: valueRoom)
            Self.appendWithCursor(into: &spans,
                                   text: visible,
                                   cursorIndex: visibleCursor)
        case .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail:
            // Truncation modes: apply to fit the value into
            // `valueRoom`, then drop the cursor at the matching
            // position in the visible string. Mid-buffer cursor
            // alignment under non-tail truncation is approximate —
            // the cursor lands at the visible offset, not the logical
            // one — which is a HIG-acceptable trade-off.
            let visible = mode.apply(to: value, width: valueRoom)
            let visibleCursor = min(cursor, visible.count)
            Self.appendWithCursor(into: &spans,
                                   text: visible,
                                   cursorIndex: visibleCursor)
        }
        return spans
    }

    /// Slide a fixed-width window of `room` chars over `value` so
    /// the cursor is always inside it. Returns the visible substring
    /// and the cursor's offset within that substring.
    ///
    /// Legacy behaviour preserved: when the value fits in `room`,
    /// the window is the whole value. When it doesn't, the window
    /// shows `room` consecutive chars sliding to keep the cursor on
    /// screen — anchored at the start when cursor is near the head,
    /// at the tail when cursor is near the end (the legacy
    /// `value.suffix(room)` rendering when cursor sits at end).
    static func windowedSlice(value: String, cursor: Int, room: Int) -> (visible: String, cursorOffset: Int) {
        if value.count <= room {
            return (value, cursor)
        }
        // Cursor at end → anchor to tail (legacy "pin right" rendering).
        // Cursor mid-buffer → roughly centre, so the user sees context on
        // both sides while editing. Clamp so we never run off either end.
        let maxStart = value.count - room
        let proposedStart: Int
        if cursor >= value.count {
            // At end: show the trailing window so the cursor sits past
            // the last char and the legacy assertions still hold.
            proposedStart = maxStart
        } else {
            // Mid-buffer: anchor the cursor near the centre.
            proposedStart = cursor - room / 2
        }
        let windowStart = max(0, min(maxStart, proposedStart))
        let startIdx = value.index(value.startIndex, offsetBy: windowStart)
        let endIdx = value.index(value.startIndex, offsetBy: windowStart + room)
        return (String(value[startIdx..<endIdx]), cursor - windowStart)
    }

    /// Emit `text` as a span, inserting the cursor glyph `│` at
    /// `cursorIndex` (an offset within `text`). Splits the run when
    /// the cursor is mid-buffer; appends the glyph at the tail
    /// otherwise.
    static func appendWithCursor(into spans: inout [TextSpan], text: String, cursorIndex: Int) {
        let clamped = max(0, min(cursorIndex, text.count))
        if clamped >= text.count {
            spans.append(TextSpan(text))
            spans.append(TextSpan("│"))
            return
        }
        let splitIdx = text.index(text.startIndex, offsetBy: clamped)
        let head = String(text[text.startIndex..<splitIdx])
        let tail = String(text[splitIdx..<text.endIndex])
        if !head.isEmpty {
            spans.append(TextSpan(head))
        }
        spans.append(TextSpan("│"))
        if !tail.isEmpty {
            spans.append(TextSpan(tail))
        }
    }
}
