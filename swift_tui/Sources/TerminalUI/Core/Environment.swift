// Color support detection — kept from original stub.
// Full environment is in State/EnvironmentValues.swift
//
// HYP-105: this value is exposed via @TerminalEnvironment(\.colorSupport)
// and defaults to `.trueColor`. Today it is *advisory only* — the renderer
// always emits truecolor SGR escapes regardless of the value. The downgrade
// pipeline (truecolor → 256 → 16) is tracked in HYP-13. Read this enum to
// branch your own colour choices, but do not assume the framework adapts
// its output for you yet.

public enum ColorSupport: Sendable {
    case none
    case basic      // 8 colors
    case ansi256    // 256 colors
    case trueColor  // 24-bit
}
