public protocol Theme: Sendable {
    var accent: Color { get }
    var muted: Color { get }
    var success: Color { get }
    var warning: Color { get }
    var error: Color { get }
    var border: BorderStyle { get }
}

public struct DefaultTheme: Theme {
    public var accent: Color = .cyan
    public var muted: Color = .gray
    public var success: Color = .green
    public var warning: Color = .yellow
    public var error: Color = .red
    public var border: BorderStyle = .rounded

    public init() {}
}
