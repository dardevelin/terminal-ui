import Foundation

// top-level styled print replacement.
//
//   ink("Build failed", .red, .bold)                  // stdout
//   ink("Warning: \(msg)", .yellow, to: .stderr)      // stderr
//   ink("plain")                                      // no styles
//   ink("error".error.bold + ": missing", to: .stdout) // pre-built StyledString
//
// Detection is automatic: capability comes from
// `ColorCapability.detectFromProcess()` (NO_COLOR / isatty / COLORTERM /
// TERM) so piped output strips ANSI and `NO_COLOR=1` always wins.
//
// The call site stays terse — no need to import streams or pass the
// capability through every call. Callers who need deterministic
// behavior (snapshot tests, CI logging) can use
// `StyledString.render(capability:)` directly and write to whatever
// FileHandle they like.

/// Output destination for `ink(_:_:to:)`. Maps to the standard
/// FileHandles. `.stdout` is the default.
public enum InkStream: Sendable {
    case stdout
    case stderr

    /// Underlying FileHandle. Public so TerminalLog and other Ink
    /// consumers can write directly to the same stream the `ink()`
    /// helper uses, without re-deriving the mapping.
    public var fileHandle: FileHandle {
        switch self {
        case .stdout: return .standardOutput
        case .stderr: return .standardError
        }
    }
}

// MARK: - StyledString-based ink()

/// Write a pre-built `StyledString` to `stream`. Capability is
/// auto-detected once per call. Appends a newline like `print(_:)`.
public func ink(_ s: StyledString, to stream: InkStream = .stdout) {
    let cap = ColorCapability.detectFromProcess()
    let rendered = s.render(capability: cap) + "\n"
    if let data = rendered.data(using: .utf8) {
        stream.fileHandle.write(data)
    }
}

// MARK: - Convenience: text + foreground + traits

/// Convenience for the 95% case: take a string, optionally a color,
/// optionally traits, write to `stream`.
///
///   ink("Build OK", .green)
///   ink("PANIC", .red, .bold)
///
/// Equivalent to `ink(StyledString(text).foreground(color).traits(traits))`.
public func ink(_ text: String,
                _ color: InkColor? = nil,
                _ traits: TextTraits = [],
                to stream: InkStream = .stdout) {
    var s = StyledString(text)
    if let color { s = s.foreground(color) }
    if !traits.isEmpty { s = s.traits(traits) }
    ink(s, to: stream)
}
