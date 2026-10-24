/// A logical key press, decoded from raw terminal bytes by ``InputParser``.
///
/// Terminals don't send keycodes — they send byte sequences (plain bytes,
/// ANSI CSI/SS3 escape sequences, or kitty-protocol `CSI u` sequences).
/// `Key` is the normalized result: one case per logical key, with modifier
/// state carried separately in ``KeyEvent/modifiers``. Match on it in
/// `onKeyPress` handlers or `onEvent(_:)`.
public enum Key: Hashable, Sendable {
    /// A printable character, including Unicode beyond ASCII. Ctrl+letter and
    /// Alt+key chords also arrive here — as the plain letter with `.ctrl` /
    /// `.alt` set in ``KeyEvent/modifiers``, never as a control character.
    case character(Character)
    /// The Return key — a carriage return byte (0x0D) in raw mode.
    case enter
    /// The Tab key (0x09). Shift+Tab arrives as this case with `.shift` set
    /// (terminals send it as the distinct sequence `ESC [ Z`).
    case tab
    /// The Backspace key. Most terminals send DEL (0x7F) for it; a few send
    /// BS (0x08) — both normalize to this case.
    case backspace
    /// A standalone press of the Escape key (0x1B). Because ESC also prefixes
    /// every escape sequence, the parser disambiguates by read timeout: an ESC
    /// byte followed by ~100 ms of silence is a real Escape press.
    case escape
    /// Up arrow — `ESC [ A` (or the SS3/modified variants).
    case up
    /// Down arrow — `ESC [ B` (or the SS3/modified variants).
    case down
    /// Left arrow — `ESC [ D` (or the SS3/modified variants).
    case left
    /// Right arrow — `ESC [ C` (or the SS3/modified variants).
    case right
    /// The Home key — `ESC [ H` or the VT220-style `ESC [ 1 ~`.
    case home
    /// The End key — `ESC [ F` or the VT220-style `ESC [ 4 ~`.
    case end
    /// The Page Up key — `ESC [ 5 ~`.
    case pageUp
    /// The Page Down key — `ESC [ 6 ~`.
    case pageDown
    /// The forward-delete key — `ESC [ 3 ~`. Distinct from ``backspace``:
    /// this deletes under/after the cursor, not before it.
    case delete
    /// A function key F1–F12. F1–F4 arrive as SS3 `ESC O P/Q/R/S`; F5–F12 use
    /// the tilde codes `ESC [ 15/17–21/23/24 ~` (the gaps are historical
    /// VT220 assignments).
    case f(Int)
    /// An escape sequence the parser doesn't recognize. Carries the raw bytes
    /// unmodified so apps and the debug input log can diagnose exactly what
    /// the terminal sent.
    case unknown([UInt8])
    /// Synthesized when a click lands on a focusable that has no
    /// `.onClick` handler. Activatable widgets (Button) treat
    /// `.activate` the same as `.enter`; text-input components
    /// (TextArea / TextInput / PromptInput) ignore it because their
    /// `.enter` handler interprets Enter as user input (newline /
    /// submit). Lets the framework deliver "click means activate"
    /// without inserting a newline into focused text fields.
    case activate
}

/// Where a key event came from. Used by the debug input log and audit
/// trails so remote-control injected input is distinguishable from real
/// terminal stdin. Regular app code doesn't need to branch on this — it's
/// observability, not logic.
public enum KeyEventSource: Sendable, Equatable {
    /// The app's stdin reader parsed this from the terminal. Default.
    case stdin
    /// remote control socket injected this event.
    case remote
}

/// A single key press: the logical ``Key`` plus modifier state and origin.
///
/// This is what key handlers receive — via `TerminalEvent.key(_:)` in
/// `onEvent(_:)`, or through per-view handlers like `.onKeyPress`. Modifiers
/// are separate from the key: Ctrl+C is `.character("c")` with `.ctrl` set,
/// not a control character.
public struct KeyEvent: Sendable {
    /// The logical key that was pressed.
    public let key: Key
    /// Modifier keys held during the press. Empty for an unmodified key.
    public let modifiers: KeyModifiers
    /// Where the event came from — real stdin or the debug remote-control
    /// socket. Observability only; app logic shouldn't branch on it.
    public let source: KeyEventSource

    /// Creates a key event. `modifiers` defaults to none and `source` to
    /// `.stdin` — tests and synthetic dispatch usually pass just the key.
    public init(key: Key, modifiers: KeyModifiers = [], source: KeyEventSource = .stdin) {
        self.key = key
        self.modifiers = modifiers
        self.source = source
    }
}

extension KeyEvent {
    /// An arrow, PageUp, PageDown, Home or End with a modifier held. A view
    /// that moves by these keys moves on the plain ones and passes this on:
    /// views see a key before the app's bindings, so one that took Shift+↓
    /// as ↓ would leave the app no way to bind it.
    var isModifiedNavigation: Bool {
        guard !modifiers.isEmpty else { return false }
        switch key {
        case .up, .down, .left, .right, .pageUp, .pageDown, .home, .end: return true
        default: return false
        }
    }
}

/// Modifier keys held during a key press, as an option set.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    /// The held modifiers as bits: Shift in bit 0, Alt in bit 1, Control in
    /// bit 2 — xterm's modifier parameter less its +1 offset. Modifiers a
    /// terminal reports beyond these three have no bit and are dropped.
    public let rawValue: UInt8
    /// Creates a set from its bit pattern; prefer the named members.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The Shift key.
    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    /// The Alt key — Option on macOS; the parser produces `.alt` for
    /// both.
    public static let alt     = KeyModifiers(rawValue: 1 << 1)
    /// The Control key.
    public static let ctrl    = KeyModifiers(rawValue: 1 << 2)
}
