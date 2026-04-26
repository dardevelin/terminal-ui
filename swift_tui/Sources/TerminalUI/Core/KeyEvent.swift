public enum Key: Hashable, Sendable {
    case character(Character)
    case enter
    case tab
    case backspace
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case delete
    case f(Int)
    case unknown([UInt8])
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

public struct KeyEvent: Sendable {
    public let key: Key
    public let modifiers: KeyModifiers
    public let source: KeyEventSource

    public init(key: Key, modifiers: KeyModifiers = [], source: KeyEventSource = .stdin) {
        self.key = key
        self.modifiers = modifiers
        self.source = source
    }
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let alt     = KeyModifiers(rawValue: 1 << 1)
    public static let ctrl    = KeyModifiers(rawValue: 1 << 2)
}
