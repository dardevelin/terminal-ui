import TerminalUI

/// The demo's brand palette: named colors only, no semantics.
///
/// Structured as *ramps* rather than single values — four background
/// steps, four foreground steps, three steps for each status hue. That
/// structure is the point: a dense pane layers six kinds of information
/// on one screen, and it only stays legible if "slightly dimmer" is a
/// value you can reach for rather than one you invent per call site.
///
/// Neutrals carry a deliberate violet bias (the `0x…26` blue channel
/// lift on `ink`) so they sit under the primary rather than fighting it.
///
/// Semantic roles live in ``CoderTheme`` — nothing outside that type
/// should name a color from here.
enum Palette {
    // MARK: Backgrounds — darkest ground to most-visible surface

    /// The window ground.
    static let ink = Color.rgb(0x1B, 0x1A, 0x24)
    /// Raised surface: sidebar, message bodies.
    static let slate = Color.rgb(0x24, 0x23, 0x30)
    /// Hairlines, rules, inactive borders.
    static let graphite = Color.rgb(0x33, 0x31, 0x42)
    /// Most-visible fill: selected rows, code blocks.
    static let pewter = Color.rgb(0x45, 0x43, 0x58)

    // MARK: Foregrounds — most subtle to brightest

    /// Barely-there text: disabled, watermarks.
    static let dusk = Color.rgb(0x63, 0x60, 0x7A)
    /// Secondary text: timestamps, hints, metadata.
    static let ash = Color.rgb(0x8B, 0x87, 0xA3)
    /// Primary de-emphasised text: descriptions.
    static let mist = Color.rgb(0xC2, 0xBE, 0xD6)
    /// Body text.
    static let chalk = Color.rgb(0xED, 0xEB, 0xF5)
    /// Text on a saturated fill.
    static let paper = Color.rgb(0xFD, 0xFC, 0xFF)

    // MARK: Brand

    static let violet = Color.rgb(0x7C, 0x5C, 0xFF)
    static let violetDim = Color.rgb(0x5B, 0x42, 0xC4)
    static let violetLift = Color.rgb(0x9B, 0x82, 0xFF)
    static let turquoise = Color.rgb(0x3D, 0xDB, 0xD9)
    static let mint = Color.rgb(0x7B, 0xFF, 0xCE)
    static let pink = Color.rgb(0xFF, 0x7A, 0xC6)

    // MARK: Status ramps

    static let jade = Color.rgb(0x2F, 0xD8, 0x96)
    static let jadeDim = Color.rgb(0x1E, 0x8F, 0x63)
    static let jadeLift = Color.rgb(0x86, 0xFF, 0xC7)

    static let amber = Color.rgb(0xF5, 0xC2, 0x4B)
    static let amberDim = Color.rgb(0xB3, 0x8A, 0x28)

    static let coral = Color.rgb(0xFF, 0x5D, 0x7E)
    static let coralDim = Color.rgb(0xC0, 0x36, 0x54)

    static let tangerine = Color.rgb(0xFF, 0x96, 0x4F)

    static let azure = Color.rgb(0x4F, 0xB4, 0xFF)
    static let azureDim = Color.rgb(0x2C, 0x74, 0xB8)
}
