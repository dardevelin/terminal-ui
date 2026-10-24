/// A semantic palette the framework's components draw from, so an app can
/// restyle every widget by swapping one value instead of touching each
/// call site.
///
/// Components ask for *roles* (`accent`, `error`, `foregroundMuted`), never
/// literal colors — a conforming type answers with whatever ``Color`` fits
/// its look. Sticking to named ANSI colors (as ``DefaultTheme`` does) keeps
/// the theme deferring to the user's terminal palette; ``Color/rgb(_:_:_:)``
/// values pin an exact look instead.
///
/// ## Roles come in ramps
///
/// The roles are not a flat list of hues. Foregrounds, backgrounds and the
/// informational statuses each come as a *ramp* — several steps of the same
/// idea, ordered by weight. This is the part that matters for dense screens:
/// a pane holding a heading, a rule, body text, a timestamp and a status chip
/// needs four distinct foreground weights before it needs a second hue, and a
/// palette that offers only "text" and "muted" forces every call site to
/// invent the difference.
///
/// - Foreground: ``foregroundEmphasis`` → ``foreground`` → ``foregroundSubtle``
///   → ``foregroundMuted`` → ``foregroundFaint``
/// - Background: ``background`` → ``backgroundRaised`` → ``backgroundOverlay``
///   → ``backgroundSelected``
/// - Status: each of ``success``, ``warning``, ``error`` and ``info`` has a
///   `…Subtle` partner for the same meaning stated more quietly.
///
/// ## Contrast pairings
///
/// ``onPrimary`` exists so "text drawn on top of a ``primary`` fill" is a
/// decision the theme makes once, rather than a guess repeated at every call
/// site that fills a background.
///
/// ## Conforming
///
/// Every role has a default, so a theme only states what it wants to change:
///
/// ```swift
/// struct Solarized: Theme {
///     var accent: Color = .rgb(38, 139, 210)
///     var foregroundMuted: Color = .rgb(88, 110, 117)
///     var border: BorderStyle = .heavy
/// }
/// ```
///
/// Defaults are derived from the roles above them in the ramp, so a theme
/// that sets only ``foregroundMuted`` still gets a coherent — if flat —
/// answer for ``foregroundSubtle`` and ``foregroundFaint``. Themes that care
/// about density should state the ramps explicitly.
public protocol Theme: Sendable {

    // MARK: Derivation

    /// Whether unstated roles are mixed from the ones they sit against, or
    /// simply borrow them. See ``ThemeDerivation``.
    var derivation: ThemeDerivation { get }

    // MARK: Brand

    /// Highlight color for the focused or selected element — cursors,
    /// active borders, selection bars.
    var accent: Color { get }
    /// The dominant brand color, used for fills rather than accents.
    var primary: Color { get }
    /// Supporting brand color, for the second voice in a two-tone treatment
    /// such as a gradient's far end.
    var secondary: Color { get }
    /// Foreground for text drawn on a ``primary`` fill.
    var onPrimary: Color { get }

    // MARK: Foreground ramp — strongest to faintest

    /// Strongest text: the selected row, the active tab, a heading that must
    /// win against everything around it.
    var foregroundEmphasis: Color { get }
    /// Body text. The weight most content is drawn at.
    var foreground: Color { get }
    /// Secondary content — descriptions, supporting detail that should read
    /// as subordinate without becoming chrome.
    var foregroundSubtle: Color { get }
    /// De-emphasised chrome — hints, placeholders, disabled controls,
    /// timestamps, tree connectors. Unstated, it is ``muted``.
    var foregroundMuted: Color { get }
    /// 1.0's name for de-emphasis, from before the ramp existed. A theme
    /// written then states this rather than ``foregroundMuted``, and the
    /// muted step takes it from here. New themes state
    /// ``foregroundMuted``; components never read this.
    ///
    /// A requirement rather than an alias so a theme's own `muted` is the
    /// one the ramp reads: as an extension member, a conforming type's
    /// `muted` compiled and was silently ignored.
    var muted: Color { get }
    /// The faintest legible step: watermarks, and text present only so its
    /// absence would be noticed.
    var foregroundFaint: Color { get }

    // MARK: Background ramp — ground to most-raised

    /// The window ground.
    var background: Color { get }
    /// A surface lifted off the ground: sidebar, panel, message body.
    var backgroundRaised: Color { get }
    /// Transient surfaces that sit above the layout: dialogs, popovers,
    /// completion lists.
    var backgroundOverlay: Color { get }
    /// Fill behind the selected row or cell.
    var backgroundSelected: Color { get }

    // MARK: Structure

    /// Low-contrast rules, dividers and separators.
    var separator: Color { get }
    /// Border color for a container at rest.
    var borderIdle: Color { get }
    /// Border color for the focused or active container.
    var borderActive: Color { get }
    /// The box-drawing character set components use for their borders.
    var border: BorderStyle { get }

    // MARK: Status

    /// Positive outcomes — additions, passing states, confirmations.
    var success: Color { get }
    /// The same meaning stated more quietly.
    var successSubtle: Color { get }
    /// Cautionary states that don't block — pending work, approaching limits.
    var warning: Color { get }
    /// The same meaning stated more quietly.
    var warningSubtle: Color { get }
    /// Failures.
    var error: Color { get }
    /// The same meaning stated more quietly.
    var errorSubtle: Color { get }
    /// Neutral information — counts, hints, non-urgent notices.
    var info: Color { get }
    /// The same meaning stated more quietly.
    var infoSubtle: Color { get }
    /// Something that wants the eye without being a failure — an unread
    /// marker, a diverged branch.
    var attention: Color { get }
    /// Work in progress: spinners, streaming output, pending requests.
    var busy: Color { get }
    /// Actions that destroy data. Distinct from ``error``, which reports
    /// that something already went wrong.
    var destructive: Color { get }

    // MARK: Changes

    /// The ground of a line a change added — a diff's `+` row. Tinted by
    /// ``success`` but near the ground, so code on it stays legible; the
    /// row's colour says it changed, which leaves its text free to be
    /// highlighted.
    var addedBackground: Color { get }
    /// The ground of a line a change removed — a diff's `-` row, tinted by
    /// ``error``.
    var removedBackground: Color { get }

    // MARK: Code

    /// Colours for highlighted source: ``CodeView``, fenced blocks in
    /// ``MarkdownView``, a highlighting ``TextArea``. Like ``border``, a theme
    /// states it once and every view that draws code follows.
    var syntax: SyntaxTheme { get }
}

/// Whether a theme fills in the roles it did not state by mixing colour, or
/// by borrowing it.
///
/// Derivation is a convenience, not a policy. A palette chosen by hand, or
/// pinned to a brand specification, has values that are the values — mixing
/// a "quieter" step from them produces a colour nobody signed off on. Such a
/// theme turns it off and states what it means.
///
/// Turning it off never *removes* a role: every one still answers, just by
/// borrowing the nearest stated colour rather than computing a new one. A
/// theme with derivation off and no explicit `foregroundFaint` gets its
/// `foregroundMuted`, which is exactly what the defaults did before any
/// colour science existed.
///
/// Orthogonal to overriding. A role a theme states explicitly always wins,
/// with derivation on or off — the switch only decides how the *unstated*
/// ones are filled in.
///
/// ```swift
/// struct BrandTheme: Theme {
///     var derivation: ThemeDerivation = .off
///     var foreground: Color = .rgb(0x1D, 0x1D, 0x1F)
///     var foregroundMuted: Color = .rgb(0x86, 0x86, 0x8B)   // from the spec
/// }
/// ```
public enum ThemeDerivation: Sendable, Equatable {
    /// Unstated roles are mixed toward the ground they sit against, in Oklab.
    case automatic
    /// Unstated roles borrow the nearest stated colour. No colour arithmetic.
    case off
}

/// How far a derived step travels toward the ground it sits on.
///
/// Every amount is deliberately below one half. When an endpoint cannot be
/// resolved to a value — ``Color/default`` means "whatever the terminal uses",
/// which no table can answer — ``Color/blended(with:amount:)`` returns the
/// nearer end. Keeping the travel under half therefore makes an underived
/// theme fall back to the colour it *did* state, rather than to the unknown
/// one. That is what lets a theme built entirely on terminal defaults behave
/// exactly as it did before derivation existed.
private enum RampStep {
    /// Secondary content, a short step off body text.
    static let subtle = 0.25
    /// Chrome — far enough to read as a different class of thing.
    static let muted = 0.45
    /// The quietest legible step, measured from `muted`.
    static let faint = 0.4
    /// A status colour stated more quietly, without changing its hue.
    static let statusSubtle = 0.4
    /// Surfaces lifting off the ground. Small: a panel that reads as a
    /// different colour rather than a different height is too far.
    static let raised = 0.08
    static let overlay = 0.16
    /// A changed line's ground, mixed from the ground toward its status:
    /// far enough to read as added or removed at a glance, near enough the
    /// ground that the code on it keeps its contrast. Mixed this way round
    /// so a ground that cannot be resolved stays the ground — no tint —
    /// rather than becoming the full status colour behind the code.
    static let changeSurface = 0.2
}

/// Defaults for every role, so a conforming type states only what it changes.
///
/// Steps are *derived*, not aliased: `foregroundFaint` is `foregroundMuted`
/// mixed toward the background, so a theme that states one step of a ramp gets
/// a genuinely quieter one below it instead of a duplicate. This is what makes
/// the role set authorable — a theme can state five or six colours and get a
/// coherent twenty-six, which is how Textual's token system stays usable at
/// this size.
///
/// Derivation needs resolvable endpoints, and a theme resting on terminal
/// defaults has none. Those cases name a literal instead, so the stock palette
/// keeps the contrast it always had rather than collapsing to one colour.
extension Theme {
    /// `base` mixed toward `ground`, or `base` untouched when the theme has
    /// turned derivation off. Every derived role goes through here, so the
    /// switch cannot end up honoured in some ramps and ignored in others.
    func derived(_ base: Color, toward ground: Color, _ amount: Double) -> Color {
        switch derivation {
        case .automatic: base.blended(with: ground, amount: amount)
        case .off: base
        }
    }

    /// Unstated: ``ThemeDerivation/automatic``, so the roles a theme leaves out
    /// are mixed from the ones it states. With ``ThemeDerivation/off`` each
    /// takes the colour it would have been mixed from.
    public var derivation: ThemeDerivation { .automatic }

    /// Unstated: cyan, from the terminal's own palette.
    public var accent: Color { .cyan }
    /// Unstated: ``accent``.
    public var primary: Color { accent }
    /// Unstated: ``accent``, so a gradient from ``primary`` to it is one colour
    /// until a theme states both.
    public var secondary: Color { accent }
    /// Unstated: bright white, legible on the stock cyan.
    public var onPrimary: Color { .brightWhite }

    /// Unstated: ``foreground`` lifted toward bright white by the muted step
    /// (0.45), or white when ``foreground`` is the terminal's own colour, which
    /// cannot be mixed.
    public var foregroundEmphasis: Color {
        foreground.nominalRGB == nil ? .white : derived(foreground, toward: .brightWhite, RampStep.muted)
    }
    /// Unstated: the terminal's own text colour, ``Color/default``.
    public var foreground: Color { .default }
    /// Unstated: ``foreground`` a quarter of the way toward ``background``.
    public var foregroundSubtle: Color { derived(foreground, toward: background, RampStep.subtle) }
    /// Unstated: ``muted``, 1.0's name for this step, so a theme written then
    /// keeps its colour.
    public var foregroundMuted: Color { muted }
    /// Unstated: ``foreground`` 0.45 of the way toward ``background``, or gray
    /// when ``foreground`` is the terminal's own colour.
    public var muted: Color {
        foreground.nominalRGB == nil ? .gray : derived(foreground, toward: background, RampStep.muted)
    }
    /// Unstated: ``foregroundMuted`` 0.4 of the way toward ``background``.
    public var foregroundFaint: Color { derived(foregroundMuted, toward: background, RampStep.faint) }

    /// Unstated: the terminal's own ground, ``Color/default`` — the framework
    /// paints no ground of its own.
    public var background: Color { .default }
    /// Unstated: ``background`` 0.08 of the way toward ``foreground``: a panel
    /// one shade off the ground. On the terminal's own ground, which cannot be
    /// mixed, it is that ground.
    public var backgroundRaised: Color { derived(background, toward: foreground, RampStep.raised) }
    /// Unstated: ``background`` 0.16 of the way toward ``foreground``, a step
    /// above ``backgroundRaised``.
    public var backgroundOverlay: Color { derived(background, toward: foreground, RampStep.overlay) }
    /// Unstated: blue rather than a derived step — the selection fill the
    /// components already drew, where a step mixed from the terminal's own
    /// ground would resolve to no highlight at all.
    public var backgroundSelected: Color { .blue }

    /// Unstated: ``foregroundMuted``.
    public var separator: Color { foregroundMuted }
    /// Unstated: the terminal's own colour, ``Color/default``.
    public var borderIdle: Color { .default }
    /// Unstated: ``accent``.
    public var borderActive: Color { accent }
    /// Unstated: ``BorderStyle/rounded``.
    public var border: BorderStyle { .rounded }

    /// Unstated: green.
    public var success: Color { .green }
    /// Unstated: ``success`` 0.4 of the way toward ``background``: the same
    /// hue, quieter.
    public var successSubtle: Color { derived(success, toward: background, RampStep.statusSubtle) }
    /// Unstated: yellow.
    public var warning: Color { .yellow }
    /// Unstated: ``warning`` 0.4 of the way toward ``background``.
    public var warningSubtle: Color { derived(warning, toward: background, RampStep.statusSubtle) }
    /// Unstated: red.
    public var error: Color { .red }
    /// Unstated: ``error`` 0.4 of the way toward ``background``.
    public var errorSubtle: Color { derived(error, toward: background, RampStep.statusSubtle) }
    /// Unstated: blue.
    public var info: Color { .blue }
    /// Unstated: ``info`` 0.4 of the way toward ``background``.
    public var infoSubtle: Color { derived(info, toward: background, RampStep.statusSubtle) }
    /// Unstated: ``warning``.
    public var attention: Color { warning }
    /// Unstated: ``accent``.
    public var busy: Color { accent }
    /// Unstated: ``error``.
    public var destructive: Color { error }

    /// Unstated: ``SyntaxTheme/defaultDark``.
    /// Unstated: ``background`` 0.2 of the way toward ``success``. On the
    /// terminal's own ground, which cannot be mixed, it is that ground — no
    /// tint.
    public var addedBackground: Color { derived(background, toward: success, RampStep.changeSurface) }
    /// Unstated: ``background`` 0.2 of the way toward ``error``.
    public var removedBackground: Color { derived(background, toward: error, RampStep.changeSurface) }

    public var syntax: SyntaxTheme { .defaultDark }
}

/// The stock ``Theme``: cyan accent, gray chrome, green/yellow/red
/// semantics, rounded borders, and every ramp deferring to the terminal's
/// own palette.
///
/// Every role is a stored property, so rebranding is mutation rather than a
/// new conformance:
///
/// ```swift
/// var theme = DefaultTheme()
/// theme.accent = .magenta
/// theme.backgroundRaised = .ansi256(236)
/// MyApp().environment(\.theme, theme)
/// ```
///
/// Because every role is stored, this theme never derives anything — each
/// value is already stated. Set ``derivation`` to ``ThemeDerivation/off`` on
/// a theme that fills in only some roles and wants the rest borrowed rather
/// than mixed.
///
/// The values deliberately reproduce the literals the components used before
/// they read the theme at all, so adopting it changes nothing until a theme
/// says otherwise. Backgrounds default to ``Color/default`` — the terminal's
/// own — because a framework that paints its own ground over every app is a
/// worse neighbour than one that inherits.
public struct DefaultTheme: Theme {
    /// Stored, so the stock theme can be handed to a brand palette with the
    /// derivation matrix switched off in the same copy-and-mutate step as any
    /// other role.
    public var derivation: ThemeDerivation = .automatic

    /// Cyan, from the terminal's own palette, as every component drew before
    /// themes.
    public var accent: Color = .cyan
    /// Cyan, matching ``accent``.
    public var primary: Color = .cyan
    /// Blue.
    public var secondary: Color = .blue
    /// Bright white, legible on the cyan primary.
    public var onPrimary: Color = .brightWhite

    /// White.
    public var foregroundEmphasis: Color = .white
    /// The terminal's own text colour, ``Color/default``.
    public var foreground: Color = .default
    /// The terminal's own text colour: with no colour to mix from, the stock
    /// theme does not quiet secondary text.
    public var foregroundSubtle: Color = .default
    /// Gray: hints, placeholders and chrome, as before themes.
    public var foregroundMuted: Color = .gray
    /// Gray, the same as ``foregroundMuted``.
    public var foregroundFaint: Color = .gray

    /// The terminal's own ground, ``Color/default``: the stock theme paints no
    /// ground of its own.
    public var background: Color = .default
    /// The terminal's own ground: the stock theme draws no panel bands, so
    /// inline code and a light terminal stay readable.
    public var backgroundRaised: Color = .default
    /// The terminal's own ground.
    public var backgroundOverlay: Color = .default
    /// Blue, the selection fill.
    public var backgroundSelected: Color = .blue

    /// Gray.
    public var separator: Color = .gray
    /// The terminal's own colour, ``Color/default``.
    public var borderIdle: Color = .default
    /// Cyan, matching ``accent``.
    public var borderActive: Color = .cyan
    /// ``BorderStyle/rounded``.
    public var border: BorderStyle = .rounded

    /// Green.
    public var success: Color = .green
    /// Green: on the terminal's own ground there is no quieter shade to mix.
    public var successSubtle: Color = .green
    /// Yellow.
    public var warning: Color = .yellow
    /// Yellow.
    public var warningSubtle: Color = .yellow
    /// Red.
    public var error: Color = .red
    /// Red.
    public var errorSubtle: Color = .red
    /// Blue.
    public var info: Color = .blue
    /// Blue.
    public var infoSubtle: Color = .blue
    /// Yellow, matching ``warning``.
    public var attention: Color = .yellow
    /// Cyan, matching ``accent``.
    public var busy: Color = .cyan
    /// Red, matching ``error``.
    public var destructive: Color = .red

    /// The terminal's own ground: a full status colour behind code would
    /// bury it, and there is no ground to mix a quieter one from.
    public var addedBackground: Color = .default
    /// The terminal's own ground, as ``addedBackground`` is.
    public var removedBackground: Color = .default

    /// ``SyntaxTheme/defaultDark``.
    public var syntax: SyntaxTheme = .defaultDark

    /// Creates the default palette; every property can be mutated after.
    public init() {}
}

extension DefaultTheme {
    /// 1.0's name for ``foregroundMuted``, settable as it was then, so a
    /// rebrand written as `theme.muted = …` still lands on the muted step.
    @available(*, deprecated, renamed: "foregroundMuted")
    public var muted: Color {
        get { foregroundMuted }
        set { foregroundMuted = newValue }
    }
}

extension Theme {
    /// The colour an input marks its cursor with: the accent, or the warning
    /// while a ``CursorFlash`` is lit — a key refused at a wall.
    func cursorColor(lit: Bool) -> Color {
        lit ? warning : accent
    }
}
