// Color support detection — kept from original stub.
// Full environment is in State/EnvironmentValues.swift
//
// This value is exposed via @TerminalEnvironment(\.colorSupport) and
// defaults to `.trueColor`. Today it is *advisory only* — the renderer
// always emits truecolor SGR escapes regardless of the value. A
// downgrade pipeline (truecolor → 256 → 16) is on the roadmap. Read
// this enum to branch your own colour choices, but do not assume the
// framework adapts its output for you yet.

/// The terminal's color depth, exposed via
/// `@TerminalEnvironment(\.colorSupport)`.
///
/// Advisory only today: the renderer always emits truecolor SGR
/// regardless — read this to branch your own color choices, not to
/// expect framework downgrading.
public enum ColorSupport: Sendable {
    /// Monochrome — no color escapes expected to render.
    case none
    /// The 8 basic ANSI colors.
    case basic
    /// The 256-color ANSI palette.
    case ansi256
    /// 24-bit RGB ("truecolor"). The default assumption.
    case trueColor
}
