/// Human-readable label for an `Action` — title, description, voice
/// prompt, accessibility text — that the framework's readout consumers
/// (HelpOverlay, CommandPalette, MenuBar, AccessibilityRotor) all
/// resolve through one resolution path.
///
/// `.literal(_:)` carries an untranslated string verbatim. Apps that
/// localize their UI provide a translated string at the call site;
/// future cases (`.key(_:bundle:)`, `.format(_:_:)`) extend the type
/// without touching call sites that already use `.literal`.
public enum LocalizedString: Sendable, Hashable {
    /// An untranslated string. The framework's readout consumers call
    /// `resolved()` to obtain the user-visible text; for `.literal` the
    /// answer is the carried value.
    case literal(String)

    /// The user-visible text. Today every case returns the carried
    /// string; future cases route through a localizer protocol.
    public func resolved() -> String {
        switch self {
        case .literal(let text): return text
        }
    }
}
