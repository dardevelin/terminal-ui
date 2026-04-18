/// A single styled run of text. Each field is optional — `nil` means
/// "inherit from the modifier chain / render context."
public struct TextSpan: Sendable, Equatable {
    public var text: String
    public var foreground: Color?
    public var background: Color?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?

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
    public func fg(_ color: Color) -> TextSpan {
        var copy = self; copy.foreground = color; return copy
    }
    public func bg(_ color: Color) -> TextSpan {
        var copy = self; copy.background = color; return copy
    }
    public func bolded() -> TextSpan {
        var copy = self; copy.bold = true; return copy
    }
    public func italicized() -> TextSpan {
        var copy = self; copy.italic = true; return copy
    }
    public func underlined() -> TextSpan {
        var copy = self; copy.underline = true; return copy
    }
}

// MARK: - String → TextSpan convenience

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

@resultBuilder
public struct SpanBuilder {
    public static func buildBlock(_ components: [TextSpan]...) -> [TextSpan] {
        components.flatMap { $0 }
    }
    public static func buildExpression(_ span: TextSpan) -> [TextSpan] {
        [span]
    }
    public static func buildExpression(_ text: String) -> [TextSpan] {
        [TextSpan(text)]
    }
    public static func buildExpression(_ spans: [TextSpan]) -> [TextSpan] {
        spans
    }
    public static func buildOptional(_ component: [TextSpan]?) -> [TextSpan] {
        component ?? []
    }
    public static func buildEither(first: [TextSpan]) -> [TextSpan] {
        first
    }
    public static func buildEither(second: [TextSpan]) -> [TextSpan] {
        second
    }
    public static func buildArray(_ components: [[TextSpan]]) -> [TextSpan] {
        components.flatMap { $0 }
    }
}

// MARK: - Text view

/// A run of styled text, optionally composed of multiple `TextSpan`s.
///
/// `Text` wraps on newlines and supports per-character styling via spans.
/// Apply styling via modifiers (`.foreground`, `.bold`, `.italic`, `.underline`).
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
