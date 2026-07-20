/// Mouse event types from SGR 1006 extended mouse protocol.
public struct MouseEvent: Sendable {
    public let kind: MouseEventKind
    public let x: Int  // 0-indexed column
    public let y: Int  // 0-indexed row
    public let modifiers: KeyModifiers

    public init(kind: MouseEventKind, x: Int, y: Int, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.x = x
        self.y = y
        self.modifiers = modifiers
    }
}

public enum MouseEventKind: Equatable, Sendable {
    case press(MouseButton)
    case release(MouseButton)
    case drag(MouseButton)
    case moved
    case scrollUp
    case scrollDown
}

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case middle = 1
    case right = 2
}
