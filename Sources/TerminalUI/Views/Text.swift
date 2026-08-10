/// A single styled run of text — the building block of multi-color ``Text``.
///
/// Each field is optional — `nil` means "inherit from the modifier chain /
/// render context", so a span only pins the attributes it cares about and
/// everything else follows the surrounding style. Compose spans into a
/// ``Text`` when one line needs more than one color or weight; for uniformly
/// styled text, plain `Text("…").foreground(.red)` is simpler.
///
/// ```swift
/// Text(spans: [
///     TextSpan("+42", foreground: .green, bold: true),
///     TextSpan(" additions"),
/// ])
/// // or fluent, from a String:
/// Text("error".fg(.red).bolded())
/// ```
public struct TextSpan: Sendable, Equatable {
    /// The literal characters this span contributes.
    public var text: String
    /// Foreground color; `nil` inherits from the render context.
    public var foreground: Color?
    /// Background color; `nil` inherits from the render context.
    public var background: Color?
    /// Bold weight; `nil` inherits from the render context.
    public var bold: Bool?
    /// Italic slant; `nil` inherits from the render context.
    public var italic: Bool?
    /// Underline; `nil` inherits from the render context.
    public var underline: Bool?

    /// Create a span from its text and any attributes it should pin.
    /// Every attribute defaults to `nil` — "inherit from the render
    /// context" — so `TextSpan("plain")` is an unstyled run and each
    /// argument overrides exactly one attribute.
    public init(
        _ text: String,
        foreground: Color? = nil,
        background: Color? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    /// Whether any style field is explicitly set.
    public var hasOverrides: Bool {
        foreground != nil || background != nil
            || bold != nil || italic != nil || underline != nil
    }

    /// Merge this span's overrides onto a base style from the render context.
    public func resolved(over base: Style) -> Style {
        Style(
            foreground: foreground ?? base.foreground,
            background: background ?? base.background,
            bold: bold ?? base.bold,
            italic: italic ?? base.italic,
            underline: underline ?? base.underline
        )
    }
}

// MARK: - TextSpan styling fluent API

extension TextSpan {
    /// A copy of this span with its foreground color set.
    public func fg(_ color: Color) -> TextSpan {
        var copy = self; copy.foreground = color; return copy
    }
    /// A copy of this span with its background color set.
    public func bg(_ color: Color) -> TextSpan {
        var copy = self; copy.background = color; return copy
    }
    /// A copy of this span rendered bold.
    public func bolded() -> TextSpan {
        var copy = self; copy.bold = true; return copy
    }
    /// A copy of this span rendered italic.
    public func italicized() -> TextSpan {
        var copy = self; copy.italic = true; return copy
    }
    /// A copy of this span rendered underlined.
    public func underlined() -> TextSpan {
        var copy = self; copy.underline = true; return copy
    }
}

// MARK: - String → TextSpan convenience

/// Span-building sugar on `String` — `"text".styled(...)`, `.fg(_:)`,
/// `.bg(_:)` produce ``TextSpan``s for mixed-style lines.
extension String {
    /// Create a styled span from a string literal.
    public func styled(
        foreground: Color? = nil,
        background: Color? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil
    ) -> TextSpan {
        TextSpan(self, foreground: foreground, background: background,
                 bold: bold, italic: italic, underline: underline)
    }

    /// Shorthand: "hello".fg(.red)
    public func fg(_ color: Color) -> TextSpan {
        TextSpan(self, foreground: color)
    }

    /// Shorthand: "hello".bg(.blue)
    public func bg(_ color: Color) -> TextSpan {
        TextSpan(self, background: color)
    }
}

// MARK: - SpanBuilder (result builder)

/// Result builder that assembles ``TextSpan`` arrays for `Text { … }`.
///
/// Accepts bare `String`s (promoted to unstyled spans), single ``TextSpan``s,
/// and span arrays, with `if`/`else` and `for` support — so mixed-style lines
/// read declaratively instead of as array concatenation.
///
/// ```swift
/// Text {
///     "status: "
///     if isHealthy {
///         "ok".fg(.green)
///     } else {
///         "degraded".fg(.red).bolded()
///     }
/// }
/// ```
@resultBuilder
public struct SpanBuilder {
    /// Concatenates the block's per-expression span lists in source order.
    public static func buildBlock(_ components: [TextSpan]...) -> [TextSpan] {
        components.flatMap { $0 }
    }
    /// Accepts a single styled ``TextSpan`` expression.
    public static func buildExpression(_ span: TextSpan) -> [TextSpan] {
        [span]
    }
    /// Accepts a bare `String`, promoted to an unstyled span that inherits
    /// the surrounding style.
    public static func buildExpression(_ text: String) -> [TextSpan] {
        [TextSpan(text)]
    }
    /// Accepts a prebuilt span array (e.g. from a helper function).
    public static func buildExpression(_ spans: [TextSpan]) -> [TextSpan] {
        spans
    }
    /// `if` without `else`: `nil` contributes no spans.
    public static func buildOptional(_ component: [TextSpan]?) -> [TextSpan] {
        component ?? []
    }
    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first: [TextSpan]) -> [TextSpan] {
        first
    }
    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second: [TextSpan]) -> [TextSpan] {
        second
    }
    /// Flattens `for` loop iterations into one span list.
    public static func buildArray(_ components: [[TextSpan]]) -> [TextSpan] {
        components.flatMap { $0 }
    }
}

// MARK: - Text view

/// A run of styled text, optionally composed of multiple ``TextSpan``s.
///
/// The fundamental leaf view: every character-cell of output ultimately
/// comes from a `Text` (higher-level views like ``Table`` and ``BarChart``
/// precompute their content into one). Embedded `\n` starts a new row, and
/// long lines soft-wrap to the container width unless `.wrap(.none)` opts
/// out. Style the whole run via modifiers (`.foreground`, `.bold`,
/// `.italic`, `.underline`), or vary style within the line via spans.
///
/// `Text` is also the bridge for string-producing helpers: render a
/// ``BrailleCanvas`` or precomputed grid to a `String` and wrap it in
/// `Text` to place it in the view tree.
///
/// ```swift
/// Text("hello").bold().foreground(.cyan)
/// Text(spans: [
///     TextSpan("red", foreground: .red),
///     TextSpan(" + "),
///     TextSpan("blue", foreground: .blue),
/// ])
/// ```
public struct Text: TerminalView {
    /// The styled runs, concatenated left to right; `\n` inside any span's
    /// content starts a new row. Plain-string constructors produce a
    /// single unstyled span.
    public let spans: [TextSpan]

    /// Plain text — backward compatible with existing `Text("hello")` usage.
    public init(_ content: String) {
        self.spans = [TextSpan(content)]
    }

    /// Single styled span.
    public init(_ span: TextSpan) {
        self.spans = [span]
    }

    /// Styled text from an array of spans.
    public init(spans: [TextSpan]) {
        self.spans = spans
    }

    /// Styled text via result builder.
    public init(@SpanBuilder content: () -> [TextSpan]) {
        self.spans = content()
    }

    /// The plain text content (all spans concatenated). Used for measurement/debug.
    public var content: String {
        spans.map(\.text).joined()
    }

    /// Whether this text has any per-span styling (not just plain text).
    public var isStyled: Bool {
        guard spans.count == 1 else { return true }
        let s = spans[0]
        return s.foreground != nil || s.background != nil
            || s.bold != nil || s.italic != nil || s.underline != nil
    }

    public var body: Never { fatalError() }
}
