// Minimal environment for the prototype.
// Will grow into full @Environment property wrapper later.

public struct TerminalEnvironment: Sendable {
    public var terminalSize: TerminalSize
    public var colorSupport: ColorSupport
    public var theme: any Theme

    public init(
        terminalSize: TerminalSize = Terminal.size(),
        colorSupport: ColorSupport = .trueColor,
        theme: any Theme = DefaultTheme()
    ) {
        self.terminalSize = terminalSize
        self.colorSupport = colorSupport
        self.theme = theme
    }
}

public enum ColorSupport: Sendable {
    case none
    case basic      // 8 colors
    case ansi256    // 256 colors
    case trueColor  // 24-bit
}
