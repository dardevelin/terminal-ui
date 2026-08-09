// MARK: - Section model

/// Describes which zone a section occupies in the ``StatusBar``.
public enum StatusBarAlignment: Sendable {
    case left
    case center
    case right
}

/// A single section of a ``StatusBar``, carrying its alignment and styled spans.
///
/// Usually built via the `StatusBar.Section(_:content:)` factory inside a
/// `StatusBar { … }` block rather than constructed directly. Span style
/// fields left `nil` inherit the bar's background/foreground, so sections
/// blend into the bar unless they opt out.
public struct StatusBarSection: Sendable {
    /// Which zone this section occupies.
    public let alignment: StatusBarAlignment
    /// The section's styled content, concatenated left to right.
    public let spans: [TextSpan]

    /// - Parameters:
    ///   - alignment: Zone to occupy.
    ///   - spans: Styled content; `nil` style fields inherit bar colors.
    public init(_ alignment: StatusBarAlignment, spans: [TextSpan]) {
        self.alignment = alignment
        self.spans = spans
    }
}

// MARK: - SectionBuilder (result builder for sections)

/// Result builder collecting ``StatusBarSection``s for `StatusBar { … }`,
/// with `if`/`else` and `for` support for conditional sections.
@resultBuilder
public struct StatusBarSectionBuilder {
    public static func buildBlock(_ sections: StatusBarSection...) -> [StatusBarSection] {
        sections
    }
    public static func buildOptional(_ section: StatusBarSection?) -> [StatusBarSection] {
        section.map { [$0] } ?? []
    }
    public static func buildEither(first: [StatusBarSection]) -> [StatusBarSection] {
        first
    }
    public static func buildEither(second: [StatusBarSection]) -> [StatusBarSection] {
        second
    }
    public static func buildArray(_ components: [[StatusBarSection]]) -> [StatusBarSection] {
        components.flatMap { $0 }
    }
    public static func buildBlock(_ components: [StatusBarSection]...) -> [StatusBarSection] {
        components.flatMap { $0 }
    }
}

// MARK: - StatusBar view

/// A one-row, full-width bar with left / center / right sections — the
/// vim-style mode line or key-hint strip at the bottom of an app.
///
/// Renders exactly one terminal row and stretches to its container's full
/// width, painting the gaps between sections in the bar's background color
/// (a dark gray by default) so the strip reads as one solid band.
/// Sections are ``TextSpan`` content, not views: spans that leave style
/// fields `nil` inherit the bar's colors. If content overflows the width,
/// sections pack with single-space gaps and truncate on the right.
///
/// The bar is one row of a layout, not a floating overlay — pin it with a
/// `Spacer()` above it in the app's root ``VStack``.
///
/// ```swift
/// VStack {
///     mainContent
///     Spacer()
///     StatusBar {
///         StatusBar.Section(.left) {
///             TextSpan("READY", bold: true)
///         }
///         StatusBar.Section(.center) {
///             TextSpan("tab:1/3")
///         }
///         StatusBar.Section(.right) {
///             TextSpan("0.2ms", foreground: .green)
///         }
///     }
/// }
///
/// // Or the canned key-hint strip:
/// StatusBar.keyHints([("^C", "Quit"), ("Tab", "Focus")])
/// ```
public struct StatusBar: TerminalView {
    let sections: [StatusBarSection]
    let barBackground: Color
    let barForeground: Color

    /// Create a status bar with section content.
    /// - Parameters:
    ///   - background: Bar fill color, applied to gaps and to spans that
    ///     don't override it (default dark gray, `.ansi256(238)`).
    ///   - foreground: Default text color for spans that don't override it.
    ///   - content: Sections, built via `StatusBar.Section(_:content:)`.
    public init(
        background: Color = .ansi256(238),
        foreground: Color = .white,
        @StatusBarSectionBuilder content: () -> [StatusBarSection]
    ) {
        self.sections = content()
        self.barBackground = background
        self.barForeground = foreground
    }

    /// Internal initializer for pre-built sections (used by keyHints).
    init(
        sections: [StatusBarSection],
        background: Color = .ansi256(238),
        foreground: Color = .white
    ) {
        self.sections = sections
        self.barBackground = background
        self.barForeground = foreground
    }

    public var body: some TerminalView {
        GeometryReader { size in
            Text(spans: composeLine(width: size.width))
        }.frame(height: 1)
    }

    // MARK: - Section factory

    /// Create a section with a specific alignment from styled spans.
    /// The builder accepts bare `String`s and ``TextSpan``s (not views).
    public static func Section(
        _ alignment: StatusBarAlignment,
        @SpanBuilder content: () -> [TextSpan]
    ) -> StatusBarSection {
        StatusBarSection(alignment, spans: content())
    }

    // MARK: - Key hints convenience

    /// A status bar pre-populated with key binding hints.
    /// Each tuple is (key, description), rendered as "key description" pairs
    /// separated by double spaces — keys bold in `keyColor`, descriptions
    /// in the bar foreground, all left-aligned.
    public static func keyHints(
        _ bindings: [(String, String)],
        background: Color = .ansi256(238),
        foreground: Color = .white,
        keyColor: Color = .brightWhite
    ) -> StatusBar {
        var spans: [TextSpan] = []
        for (i, binding) in bindings.enumerated() {
            if i > 0 {
                spans.append(TextSpan("  ", foreground: foreground))
            }
            spans.append(TextSpan(binding.0, foreground: keyColor, bold: true))
            spans.append(TextSpan(" \(binding.1)", foreground: foreground))
        }
        let section = StatusBarSection(.left, spans: spans)
        return StatusBar(sections: [section], background: background, foreground: foreground)
    }

    // MARK: - Line composition

    /// Build a single row of TextSpans that fills `width` columns.
    /// Left content is left-aligned, right content is right-aligned,
    /// center content is centered in the remaining space.
    func composeLine(width: Int) -> [TextSpan] {
        guard width > 0 else { return [] }

        // Collect spans per alignment
        var leftSpans: [TextSpan] = []
        var centerSpans: [TextSpan] = []
        var rightSpans: [TextSpan] = []

        for section in sections {
            switch section.alignment {
            case .left: leftSpans.append(contentsOf: section.spans)
            case .center: centerSpans.append(contentsOf: section.spans)
            case .right: rightSpans.append(contentsOf: section.spans)
            }
        }

        // Measure plain-text widths
        let leftWidth = textWidth(leftSpans)
        let centerWidth = textWidth(centerSpans)
        let rightWidth = textWidth(rightSpans)

        // Apply bar background/foreground defaults to spans that lack overrides
        let left = applyDefaults(leftSpans)
        let center = applyDefaults(centerSpans)
        let right = applyDefaults(rightSpans)

        // Calculate gap sizes
        // Layout: [left][gap1][center][gap2][right]
        // Center target position: (width - centerWidth) / 2
        let centerTarget = (width - centerWidth) / 2
        let gap1 = max(0, centerTarget - leftWidth)
        let gap2 = max(0, width - centerTarget - centerWidth - rightWidth)

        // If content overflows, just concatenate and truncate
        let totalContent = leftWidth + centerWidth + rightWidth
        if totalContent >= width {
            return buildOverflowLine(left: left, center: center, right: right, width: width)
        }

        var result: [TextSpan] = []
        result.append(contentsOf: left)
        if gap1 > 0 {
            result.append(fillSpan(gap1))
        }
        result.append(contentsOf: center)
        if gap2 > 0 {
            result.append(fillSpan(gap2))
        }
        // Fill any remaining space (rounding remainder)
        let usedWidth = leftWidth + gap1 + centerWidth + gap2 + rightWidth
        let trailing = width - usedWidth
        if trailing > 0 {
            result.append(fillSpan(trailing))
        }
        result.append(contentsOf: right)

        return result
    }

    /// When content overflows, pack left + center + right with single-space gaps.
    private func buildOverflowLine(
        left: [TextSpan], center: [TextSpan], right: [TextSpan], width: Int
    ) -> [TextSpan] {
        var result: [TextSpan] = []
        let hasLeft = !left.isEmpty
        let hasCenter = !center.isEmpty
        let hasRight = !right.isEmpty

        result.append(contentsOf: left)
        if hasLeft && (hasCenter || hasRight) {
            result.append(fillSpan(1))
        }
        result.append(contentsOf: center)
        if hasCenter && hasRight {
            result.append(fillSpan(1))
        }
        result.append(contentsOf: right)

        // Truncate to width
        return truncateSpans(result, to: width)
    }

    /// Apply bar default foreground/background to spans that don't override them.
    private func applyDefaults(_ spans: [TextSpan]) -> [TextSpan] {
        spans.map { span in
            TextSpan(
                span.text,
                foreground: span.foreground ?? barForeground,
                background: span.background ?? barBackground,
                bold: span.bold,
                italic: span.italic,
                underline: span.underline
            )
        }
    }

    /// A space-fill span using the bar's default colors.
    private func fillSpan(_ count: Int) -> TextSpan {
        TextSpan(
            String(repeating: " ", count: count),
            foreground: barForeground,
            background: barBackground
        )
    }

    /// Measure total character width of spans (single line).
    private func textWidth(_ spans: [TextSpan]) -> Int {
        spans.reduce(0) { $0 + $1.text.count }
    }

    /// Truncate spans to fit within a maximum width.
    private func truncateSpans(_ spans: [TextSpan], to maxWidth: Int) -> [TextSpan] {
        var result: [TextSpan] = []
        var remaining = maxWidth

        for span in spans {
            guard remaining > 0 else { break }
            if span.text.count <= remaining {
                result.append(span)
                remaining -= span.text.count
            } else {
                var truncated = span
                truncated.text = String(span.text.prefix(remaining))
                result.append(truncated)
                remaining = 0
            }
        }

        return result
    }
}
