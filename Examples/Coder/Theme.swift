import TerminalUI

/// Semantic roles for the demo, resolved from ``Palette``.
///
/// GAP LEDGER — G1. TerminalUI's `Theme` protocol has six roles
/// (`accent`, `muted`, `success`, `warning`, `error`, `border`). A pane
/// with a header, a rule, body text, a timestamp and a status chip needs
/// four distinct foreground weights before it needs a second hue, and
/// the stock protocol can express two of them. So this type exists
/// entirely outside the framework's theming, which means:
///
///   - none of the built-in components (`Button`, `Table`, `TextInput`)
///     pick any of it up — they still resolve `DefaultTheme`;
///   - the demo has to restyle every built-in at the call site;
///   - a second theme means editing call sites, not swapping a value.
///
/// That is the wall. The framework fix is to widen `Theme` to roles of
/// this shape and resolve it through `EnvironmentValues`, so components
/// ask for `fgSubtle` and get whatever the active theme says. Written
/// here first so the shape is proven against real screens before it goes
/// into the framework.
struct CoderTheme: Sendable {
    // Brand
    var primary = Palette.violet
    var primaryDim = Palette.violetDim
    var primaryLift = Palette.violetLift
    var secondary = Palette.turquoise
    var accent = Palette.mint
    var keyword = Palette.pink

    // Foreground ramp
    var fgBase = Palette.chalk
    var fgSubtle = Palette.mist
    var fgMoreSubtle = Palette.ash
    var fgMostSubtle = Palette.dusk
    /// Text on a `primary`-filled ground.
    var onPrimary = Palette.paper

    // Background ramp
    var bgBase = Palette.ink
    var bgRaised = Palette.slate
    var bgOverlay = Palette.graphite
    var bgSelected = Palette.pewter

    // Structure
    var separator = Palette.graphite
    var borderIdle = Palette.graphite
    var borderActive = Palette.violet

    // Status
    var success = Palette.jade
    var successSubtle = Palette.jadeDim
    var successLift = Palette.jadeLift
    var warning = Palette.amber
    var warningSubtle = Palette.amberDim
    var error = Palette.coral
    var errorSubtle = Palette.coralDim
    var destructive = Palette.coral
    var attention = Palette.tangerine
    var info = Palette.azure
    var infoSubtle = Palette.azureDim
    var busy = Palette.turquoise

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
