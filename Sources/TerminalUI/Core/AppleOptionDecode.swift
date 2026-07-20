// HYP-336 — Reverse-map Apple Terminal's Option-compose Unicode chars
// back to their underlying Option+letter chord.
//
// The problem: Apple Terminal.app and iTerm2 default to "Option as
// compose key" — pressing Option+R sends the UTF-8 bytes for `®`
// (U+00AE), not `ESC r`. The InputParser's UTF-8 path produces a
// literal `®` character event with no modifier, and any binding
// registered for `Option+R` never fires.
//
// The fix: after decoding a character from the UTF-8 path, check the
// Apple compose map. If the character is one of Apple's known Option-
// chord outputs, rewrite the event to `KeyEvent(.character(letter),
// modifiers: [.alt])`. The framework's `KeyModifiers.alt` covers what
// Apple labels Option (and Linux labels Alt) — same modifier bit.
//
// Why pasted content is safe: bracketed-paste mode (ESC[200~ ...
// ESC[201~) is collected as a single `.paste` event in
// `collectBracketedPaste` — it never reaches the per-character UTF-8
// path. So a user pasting `®` from the clipboard does NOT trigger
// the decoder.
//
// Why we do this even though `.auto` should require capability
// detection: HYP-335 (`Runtime.capabilities.optionAsMetaConfigured`)
// hasn't shipped yet. Today the framework can't distinguish
// "stock Apple Terminal" from "iTerm2 with Esc+ on" at runtime. The
// safe default is "decode" because:
//   - Stock Apple Terminal is the dominant macOS environment.
//   - iTerm2 with Esc+ on sends `ESC r` (no UTF-8 compose char), so
//     the decoder never fires for those bytes — the UTF-8 path isn't
//     even reached.
//   - The only false-positive is a user typing `®` literally via a
//     non-default keyboard layout. They can override via the env
//     value `appleOptionDecode = .never` once that env value lands
//     (separate slice).
//
// Reference: Apple Terminal.app's "Use Option as Meta key" preference
// behaviour. Map sourced from System Settings > Keyboard > Input
// Sources > ABC layout's Option-modifier output table.

/// Reverse map from Apple's Option+letter compose-key Unicode output
/// back to the (letter, modifier) pair the user actually typed. Empty
/// optional return = the character is NOT a known Option-compose
/// output and should pass through as a literal character event.
enum AppleOptionDecode {
    /// Decode `character` if it's a known Option-compose output.
    /// Returns the underlying `(key, modifiers)` for the chord, or
    /// `nil` if the character is a literal.
    static func decode(_ character: Character) -> (key: Key, modifiers: KeyModifiers)? {
        guard let entry = composeMap[character] else { return nil }
        return entry
    }

    /// Apple Option+letter → underlying chord. Lowercase letters cover
    /// the Option+letter chords; uppercase compose chars (e.g. `‰` for
    /// Option+Shift+R) map to `[.alt, .shift]`.
    ///
    /// Source: macOS Keyboard Viewer with the U.S. layout active.
    /// Holding Option shows the compose row; holding Option+Shift
    /// shows the second row. Letters/digits/punctuation only — dead
    /// keys (Option+E, Option+I, Option+N, Option+U, Option+`) are
    /// EXCLUDED because they emit no character on their own; they
    /// wait for the next keystroke to compose. Apps wanting Option+E
    /// as a chord would need a different mechanism.
    private static let composeMap: [Character: (key: Key, modifiers: KeyModifiers)] = [
        // Option+letter (lowercase letters, no Shift)
        "å": (.character("a"), .alt),
        "∫": (.character("b"), .alt),
        "ç": (.character("c"), .alt),
        "∂": (.character("d"), .alt),
        "ƒ": (.character("f"), .alt),
        "©": (.character("g"), .alt),
        "˙": (.character("h"), .alt),
        "∆": (.character("j"), .alt),
        "˚": (.character("k"), .alt),
        "¬": (.character("l"), .alt),
        "µ": (.character("m"), .alt),
        "ø": (.character("o"), .alt),
        "π": (.character("p"), .alt),
        "œ": (.character("q"), .alt),
        "®": (.character("r"), .alt),
        "ß": (.character("s"), .alt),
        "†": (.character("t"), .alt),
        "√": (.character("v"), .alt),
        "∑": (.character("w"), .alt),
        "≈": (.character("x"), .alt),
        "Ω": (.character("z"), .alt),
        // Note: Option+E/I/N/U dead keys excluded.

        // Option+Shift+letter (some entries — common chords)
        "Å": (.character("a"), [.alt, .shift]),
        "ı": (.character("b"), [.alt, .shift]),
        "Ç": (.character("c"), [.alt, .shift]),
        "Î": (.character("d"), [.alt, .shift]),
        "Ï": (.character("f"), [.alt, .shift]),
        "˝": (.character("g"), [.alt, .shift]),
        "Ó": (.character("h"), [.alt, .shift]),
        "Ô": (.character("j"), [.alt, .shift]),
        // Option+Shift+K (U+F8FF Apple logo) intentionally omitted —
        // private-use codepoint with inconsistent rendering across
        // Swift versions and platforms, not worth the risk.
        "Ò": (.character("l"), [.alt, .shift]),
        "Â": (.character("m"), [.alt, .shift]),
        "Ø": (.character("o"), [.alt, .shift]),
        "∏": (.character("p"), [.alt, .shift]),
        "Œ": (.character("q"), [.alt, .shift]),
        "‰": (.character("r"), [.alt, .shift]),
        "Í": (.character("s"), [.alt, .shift]),
        "ˇ": (.character("t"), [.alt, .shift]),
        "◊": (.character("v"), [.alt, .shift]),
        "„": (.character("w"), [.alt, .shift]),
        "˛": (.character("x"), [.alt, .shift]),
        "¸": (.character("z"), [.alt, .shift]),

        // Option+digit
        "¡": (.character("1"), .alt),
        "™": (.character("2"), .alt),
        "£": (.character("3"), .alt),
        "¢": (.character("4"), .alt),
        "∞": (.character("5"), .alt),
        "§": (.character("6"), .alt),
        "¶": (.character("7"), .alt),
        "•": (.character("8"), .alt),
        "ª": (.character("9"), .alt),
        "º": (.character("0"), .alt),
    ]
}
