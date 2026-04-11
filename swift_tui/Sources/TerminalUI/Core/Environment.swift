// Color support detection — kept from original stub.
// Full environment is in State/EnvironmentValues.swift

public enum ColorSupport: Sendable {
    case none
    case basic      // 8 colors
    case ansi256    // 256 colors
    case trueColor  // 24-bit
}
