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
        WidthReader { width in
            Text(spans: Self.spans(
                title: title,
                trailing: trailing,
                width: width,
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
            TextSpan(title, foreground: theme.foregroundSubtle),
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

// MARK: - Help line

/// The bottom row of keystrokes: `key action · key action`. Keys sit one
/// step brighter than their actions and the separators recede further, so
/// the eye finds keys first — Crush's help styles, stated in this theme.
enum HelpLine {
    static func spans(_ hints: [(key: String, action: String)], theme: CoderTheme) -> [TextSpan] {
        var spans: [TextSpan] = []
        for (index, hint) in hints.enumerated() {
            if index > 0 {
                spans.append(TextSpan(" \(Glyph.middleDot) ", foreground: theme.separator))
            }
            spans.append(TextSpan(hint.key, foreground: theme.foregroundMuted))
            spans.append(TextSpan(" \(hint.action)", foreground: theme.foregroundFaint))
        }
        return spans
    }
}

// MARK: - Wordmark

/// The sidebar's identity block, in the shape of Crush's logo: a diagonal
/// field, the label and version, the name in half-block letterforms swept
/// by the brand gradient, and the field again beneath — everything as wide
/// as the name. `compact`, the one-row form: label, name and a field to the
/// sidebar's edge.
struct Wordmark: TerminalView {
    /// The sidebar's width, which the one-row form fills.
    let width: Int
    var compact = false
    var theme = CoderTheme.dark

    static let name = "CODER"
    static let label = "TerminalUI"
    static let version = "v0.1"

    var body: some TerminalView {
        if compact {
            Text(spans: compactRow)
        } else {
            let letters = DotMatrixText(Self.name, mode: .halfBlock)
            let fieldRow = Text(spans: [field(letters.columns)])
            VStack(spacing: 0) {
                fieldRow
                fieldRow
                Text(spans: metaRow(width: letters.columns))
                letters.gradient(from: theme.secondary, to: theme.primary)
                fieldRow
            }
        }
    }

    private func field(_ count: Int) -> TextSpan {
        TextSpan(String(repeating: Glyph.diagonal, count: count), foreground: theme.primary)
    }

    private func metaRow(width: Int) -> [TextSpan] {
        let gap = max(1, width - Self.label.count - Self.version.count)
        return [
            TextSpan(Self.label, foreground: theme.secondary),
            TextSpan(String(repeating: " ", count: gap)),
            TextSpan(Self.version, foreground: theme.primary),
        ]
    }

    private var compactRow: [TextSpan] {
        var spans = [TextSpan(Self.label, foreground: theme.secondary), TextSpan(" ")]
        spans += Text.gradient(Self.name, from: theme.secondary, to: theme.primary).spans.map { $0.bolded() }
        let fill = width - Self.label.count - Self.name.count - 2
        if fill > 0 {
            spans += [TextSpan(" "), field(fill)]
        }
        return spans
    }
}
