/// A semantic palette the built-in components draw from, so an app can
/// restyle every widget by swapping one value instead of touching each
/// call site.
///
/// Components ask for roles (`accent`, `error`), never literal colors —
/// a conforming type answers with whatever ``Color`` fits its look.
/// Sticking to named ANSI colors (as ``DefaultTheme`` does) keeps the
/// theme deferring to the user's terminal palette; ``Color/rgb(_:_:_:)``
/// values pin an exact look instead.
///
/// ```swift
/// struct HighContrast: Theme {
///     var accent: Color = .brightCyan
///     var muted: Color = .white
///     var success: Color = .brightGreen
///     var warning: Color = .brightYellow
///     var error: Color = .brightRed
///     var border: BorderStyle = .heavy
/// }
/// ```
public protocol Theme: Sendable {
    /// Highlight color for the focused or selected element — cursors,
    /// active borders, selection bars.
    var accent: Color { get }
    /// De-emphasis color for secondary content — hints, placeholders,
    /// inactive chrome.
    var muted: Color { get }
    /// Color for positive outcomes — additions, passing states,
    /// confirmations.
    var success: Color { get }
    /// Color for cautionary states that don't block — pending work,
    /// approaching limits.
    var warning: Color { get }
    /// Color for failures and destructive actions.
    var error: Color { get }
    /// The box-drawing character set components use for their borders.
    var border: BorderStyle { get }
}

/// The stock ``Theme``: cyan accent, gray muted, green/yellow/red
/// semantics, rounded borders. Mutate a copy's properties to rebrand.
public struct DefaultTheme: Theme {
    public var accent: Color = .cyan
    public var muted: Color = .gray
    public var success: Color = .green
    public var warning: Color = .yellow
    public var error: Color = .red
    public var border: BorderStyle = .rounded

    /// Creates the default palette; every property can be mutated after.
    public init() {}
}
