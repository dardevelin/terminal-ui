import TerminalUI

/// The demo's theme — a real ``Theme`` conformance, not a parallel one.
///
/// This file used to be a thirty-property struct sitting *outside* the
/// framework's theming, because `Theme` carried six roles and no component
/// read them. It states eight colours now and derives the rest: the framework
/// mixes each quieter step toward the background, so the foreground ramp, the
/// raised surfaces and the subdued statuses all fall out of the ground and the
/// text colour rather than being nominated one at a time.
///
/// The eight are the ones a derivation cannot guess — the ground everything
/// sits on, the text on it, the brand voices, and the statuses whose hue
/// carries meaning.
struct CoderTheme: Theme {
    // The two that everything else is measured against.
    var background: Color = Palette.ink
    var foreground: Color = Palette.chalk

    // Brand. `accent` is what focus and selection use; `primary` and
    // `secondary` are the two ends of every gradient in the app.
    var accent: Color = Palette.mint
    var primary: Color = Palette.violet
    var secondary: Color = Palette.turquoise
    var onPrimary: Color = Palette.paper

    // Statuses keep their hue, and the framework derives the quiet versions.
    var success: Color = Palette.jade
    var warning: Color = Palette.amber
    var error: Color = Palette.coral
    var info: Color = Palette.azure

    // Structure. The separator wants to be dimmer than derived chrome —
    // a rule should recede further than a timestamp does.
    var separator: Color = Palette.graphite
    var borderIdle: Color = Palette.graphite
    var borderActive: Color = Palette.violet
    var backgroundSelected: Color = Palette.pewter

    static let dark = CoderTheme()
}

/// Single-glyph vocabulary, fixed semantics.
///
/// Consistency here is most of what reads as polish: the same check mark
/// for every success, the same bar for every quiet frame. Collected as
/// constants rather than typed inline so a glyph swap is one edit.
enum Glyph {
    static let check = "✓"
    static let cross = "✕"
    static let dot = "●"
    static let bullet = "•"
    static let arrowRight = "→"
    static let diamond = "◇"
    static let triangle = "▶"

    /// Emphatic left frame — focused messages, active rails.
    static let barThick = "▌"
    /// Quiet left frame — blurred messages.
    static let barThin = "│"
    /// Horizontal rule fill for section headers.
    static let rule = "─"
    /// Diagonal field beside the wordmark and dialog titles.
    static let diagonal = "╱"

    static let radioOn = "◉"
    static let radioOff = "○"
    static let scrollThumb = "┃"
    static let scrollTrack = "│"
}
