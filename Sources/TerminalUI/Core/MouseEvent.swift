/// Mouse event types from SGR 1006 extended mouse protocol.
///
/// The runtime enables SGR 1006 tracking on startup, so every press, release,
/// drag, movement, and scroll tick arrives as one of these — coordinates are
/// cell positions, not pixels. Most apps never handle mouse events directly:
/// the runtime routes clicks to `.focusable`/`.onClick` views, and scroll
/// ticks to the nearest view under the cursor that scrolls. Handle
/// `TerminalEvent.mouse(_:)` in `onEvent(_:)` only for app-global gestures
/// the focus system doesn't cover.
public struct MouseEvent: Sendable {
    /// What happened: press, release, drag, bare movement, or a scroll tick.
    public let kind: MouseEventKind
    /// Terminal column of the event, 0-indexed from the left edge (the SGR
    /// protocol's 1-indexed `Cx` is converted during parsing).
    public let x: Int  // 0-indexed column
    /// Terminal row of the event, 0-indexed from the top edge.
    public let y: Int  // 0-indexed row
    /// Modifier keys held during the event, decoded from the SGR button
    /// bitfield (shift / alt / ctrl).
    public let modifiers: KeyModifiers

    /// Creates a mouse event at a 0-indexed cell position; `modifiers`
    /// defaults to none. Used by the parser and by tests injecting events.
    public init(kind: MouseEventKind, x: Int, y: Int, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.x = x
        self.y = y
        self.modifiers = modifiers
    }
}

/// What a ``MouseEvent`` reports happening at its cell position.
public enum MouseEventKind: Equatable, Sendable {
    /// A button went down.
    case press(MouseButton)
    /// A button came up.
    case release(MouseButton)
    /// The cursor moved while a button was held.
    case drag(MouseButton)
    /// The cursor moved with no button held.
    case moved
    /// One wheel tick away from the user.
    case scrollUp
    /// One wheel tick toward the user.
    case scrollDown

    /// A wheel tick, either way.
    var isWheel: Bool { self == .scrollUp || self == .scrollDown }

    /// The cursor moved, with or without a button held.
    var isMotion: Bool {
        switch self {
        case .moved, .drag: true
        default: false
        }
    }
}

/// Which physical mouse button an event refers to. Raw values match the
/// SGR 1006 button-code low bits.
public enum MouseButton: UInt8, Sendable {
    /// The primary button.
    case left = 0
    /// The wheel button.
    case middle = 1
    /// The secondary button.
    case right = 2
}
