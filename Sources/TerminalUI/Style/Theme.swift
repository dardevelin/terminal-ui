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
    /// timestamps, tree connectors.
    var foregroundMuted: Color { get }
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
}

/// Defaults for every role, so a conforming type states only what it changes.
///
/// Each fallback is derived from a role one step stronger in the same ramp
/// rather than from a literal, which keeps a partially-specified theme
/// internally consistent: setting ``foregroundMuted`` alone drags
/// ``foregroundFaint`` with it instead of stranding it at a hue from a
/// palette the theme never opted into.
extension Theme {
    public var accent: Color { .cyan }
    public var primary: Color { accent }
    public var secondary: Color { accent }
    public var onPrimary: Color { .brightWhite }

    public var foregroundEmphasis: Color { .white }
    public var foreground: Color { .default }
    public var foregroundSubtle: Color { foreground }
    public var foregroundMuted: Color { .gray }
    public var foregroundFaint: Color { foregroundMuted }

    public var background: Color { .default }
    public var backgroundRaised: Color { background }
    public var backgroundOverlay: Color { backgroundRaised }
    // Blue rather than a derived step: this is the selection fill the
    // components already drew, and a ramp derived from a `.default`
    // background would resolve to no highlight at all.
    public var backgroundSelected: Color { .blue }

    public var separator: Color { foregroundMuted }
    public var borderIdle: Color { .default }
    public var borderActive: Color { accent }
    public var border: BorderStyle { .rounded }

    public var success: Color { .green }
    public var successSubtle: Color { success }
    public var warning: Color { .yellow }
    public var warningSubtle: Color { warning }
    public var error: Color { .red }
    public var errorSubtle: Color { error }
    public var info: Color { .blue }
    public var infoSubtle: Color { info }
    public var attention: Color { warning }
    public var busy: Color { accent }
    public var destructive: Color { error }
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
/// The values deliberately reproduce the literals the components used before
/// they read the theme at all, so adopting it changes nothing until a theme
/// says otherwise. Backgrounds default to ``Color/default`` — the terminal's
/// own — because a framework that paints its own ground over every app is a
/// worse neighbour than one that inherits.
public struct DefaultTheme: Theme {
    public var accent: Color = .cyan
    public var primary: Color = .cyan
    public var secondary: Color = .blue
    public var onPrimary: Color = .brightWhite

    public var foregroundEmphasis: Color = .white
    public var foreground: Color = .default
    public var foregroundSubtle: Color = .default
    public var foregroundMuted: Color = .gray
    public var foregroundFaint: Color = .gray

    public var background: Color = .default
    public var backgroundRaised: Color = .default
    public var backgroundOverlay: Color = .default
    public var backgroundSelected: Color = .blue

    public var separator: Color = .gray
    public var borderIdle: Color = .default
    public var borderActive: Color = .cyan
    public var border: BorderStyle = .rounded

    public var success: Color = .green
    public var successSubtle: Color = .green
    public var warning: Color = .yellow
    public var warningSubtle: Color = .yellow
    public var error: Color = .red
    public var errorSubtle: Color = .red
    public var info: Color = .blue
    public var infoSubtle: Color = .blue
    public var attention: Color = .yellow
    public var busy: Color = .cyan
    public var destructive: Color = .red

    /// Creates the default palette; every property can be mutated after.
    public init() {}
}

extension Theme {
    /// The historical name for ``foregroundMuted``.
    ///
    /// Kept because it was the whole de-emphasis vocabulary before the ramp
    /// existed, and themes written against it should keep working. New code
    /// should name the step it wants: ``foregroundSubtle`` for subordinate
    /// content, ``foregroundMuted`` for chrome, ``foregroundFaint`` for the
    /// quietest step.
    @available(*, deprecated, renamed: "foregroundMuted")
    public var muted: Color { foregroundMuted }
}
