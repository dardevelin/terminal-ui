public enum Key: Equatable, Sendable {
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

public struct KeyEvent: Sendable {
    public let key: Key
    public let modifiers: KeyModifiers

    public init(key: Key, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let alt     = KeyModifiers(rawValue: 1 << 1)
    public static let ctrl    = KeyModifiers(rawValue: 1 << 2)
}
