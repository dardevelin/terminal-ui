import TerminalUI

// Reusable chrome: the small, high-frequency devices that carry most of
// the visual identity. Each one is a candidate to graduate into the
// framework once the demo proves its shape — see design/crush-parity.md §4.

// MARK: - Section rule

/// A section heading followed by a rule that fills the remaining width,
/// with optional right-aligned trailing text.
///
/// ```
/// Modified Files ───────────────────── 3
/// ```
///
/// GAP LEDGER — needs the container width, so it must be wrapped in a
/// `GeometryReader` at every call site. A framework `SectionHeader` would
/// read the proposed width directly during layout instead.
struct SectionRule: TerminalView {
    let title: String
    var trailing: String = ""
    var theme = CoderTheme.dark

    var body: some TerminalView {
        GeometryReader { size in
            Text(spans: Self.spans(
                title: title,
                trailing: trailing,
                width: size.width,
                theme: theme
            ))
        }
        .frame(height: 1)
    }

    static func spans(
        title: String,
        trailing: String,
        width: Int,
        theme: CoderTheme
    ) -> [TextSpan] {
        var spans: [TextSpan] = [
            TextSpan(title, foreground: theme.foregroundSubtle, bold: true),
            TextSpan(" "),
        ]
        let trailingWidth = trailing.isEmpty ? 0 : trailing.count + 1
        let fill = width - title.count - 1 - trailingWidth
        if fill > 0 {
            spans.append(TextSpan(
                String(repeating: Glyph.rule, count: fill),
                foreground: theme.separator
            ))
        }
        if !trailing.isEmpty {
            spans.append(TextSpan(" "))
            spans.append(TextSpan(trailing, foreground: theme.foregroundFaint))
        }
        return spans
    }
}

// MARK: - Status row

/// Icon, name, and a dimmer trailing detail — the shape every resource
/// list in an agent TUI uses.
///
/// ```
/// ● sourcekit-lsp  ready
/// ```
struct StatusRow: TerminalView {
    let icon: String
    let iconColor: Color
    let name: String
    let detail: String
    var theme = CoderTheme.dark

    var body: some TerminalView {
        // A status row is a fixed-height line: the detail gives way rather
        // than pushing the rows below it down.
        Text(spans: [
            TextSpan(icon, foreground: iconColor),
            TextSpan(" "),
            TextSpan(name, foreground: theme.foregroundSubtle),
            TextSpan("  "),
            TextSpan(detail, foreground: theme.foregroundFaint),
        ])
        .wrap(.truncate(.tail))
    }
}

extension Resource.Health {
    func icon(_ theme: CoderTheme) -> (glyph: String, color: Color) {
        switch self {
        case .online: (Glyph.dot, theme.success)
        case .busy: (Glyph.dot, theme.warning)
        case .offline: (Glyph.dot, theme.foregroundFaint)
        case .failed: (Glyph.cross, theme.error)
        }
    }
}

// MARK: - Key hint

/// A keystroke chip followed by its action, the unit the status bar and
/// help legend are both built from.
enum KeyHint {
    static func spans(_ key: String, _ action: String, theme: CoderTheme) -> [TextSpan] {
        [
            TextSpan(key, foreground: theme.foregroundSubtle, bold: true),
            TextSpan(" \(action)", foreground: theme.foregroundFaint),
        ]
    }
}

// MARK: - Diagonal field

/// The run of `╱` that fills space beside the wordmark and dialog titles.
///
/// The ramp is what makes this read as designed rather than drawn: a flat
/// fill of the same glyph looks like padding, while a sweep from the brand
/// colour down into the background reads as a deliberate edge. It fades
/// *away* from the wordmark so the eye is pulled back toward the name.
enum DiagonalField {
    static func spans(width: Int, theme: CoderTheme) -> [TextSpan] {
        guard width > 0 else { return [] }
        return Text.gradient(
            String(repeating: Glyph.diagonal, count: width),
            from: theme.primary,
            to: theme.backgroundOverlay
        ).spans
    }
}
