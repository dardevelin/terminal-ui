// HYP-57 — composable styled text. Like NSAttributedString but for
// terminal output: a sequence of styled runs that render to ECMA-48
// SGR sequences, with capability-aware downgrade and stripping.
//
// Design choices:
//
//   - `StyledString` is a value type holding `[StyledRun]`. Concatenation
//     appends runs without merging — preserves per-run intent so a
//     `.red` segment followed by a `.blue` segment renders as two
//     wrapped sequences. Implementations that want to coalesce can
//     normalize at render time; we keep the model honest.
//   - `render(capability:)` produces the final terminal-bound String.
//     `.none` capability strips everything (NO_COLOR / piped output),
//     `.basic16` / `.ansi256` / `.trueColor` route through
//     `ColorCapability.downgrade(_:)`.
//   - Concatenation operators `+` accept `StyledString + String`,
//     `String + StyledString`, and `StyledString + StyledString`. The
//     plain-String overloads append a trait-less run so callers can
//     mix styled and unstyled text without ceremony.
//
// Companion: `StringExtensions.swift` adds `.red.bold` chaining on
// `String`; `Ink.swift` adds the top-level `ink(...)` print API.

/// Boolean SGR attributes that compose with foreground/background
/// colors. ECMA-48 §8.3.117 codes:
///
///   1 = bold, 2 = dim, 3 = italic, 4 = underline,
///   7 = inverse, 9 = strikethrough
///
/// Modeled as an option set so callers can write
/// `[.bold, .underline]`. Each trait occupies a distinct bit.
public struct TextTraits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold          = TextTraits(rawValue: 1 << 0)
    public static let dim           = TextTraits(rawValue: 1 << 1)
    public static let italic        = TextTraits(rawValue: 1 << 2)
    public static let underline     = TextTraits(rawValue: 1 << 3)
    public static let inverse       = TextTraits(rawValue: 1 << 4)
    public static let strikethrough = TextTraits(rawValue: 1 << 5)
}

/// One contiguous styled span within a `StyledString`. Plain text
/// uses `foreground == nil && background == nil && traits == []`.
public struct StyledRun: Sendable, Equatable {
    public var text: String
    public var foreground: InkColor?
    public var background: InkColor?
    public var traits: TextTraits

    public init(text: String, foreground: InkColor? = nil, background: InkColor? = nil, traits: TextTraits = []) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.traits = traits
    }

    /// True when this run has no SGR work to emit — useful for the
    /// renderer to skip wrapping plain text in `CSI ... m ... CSI 0 m`.
    var isPlain: Bool {
        foreground == nil && background == nil && traits.isEmpty
    }
}

/// Composable styled text. Build via `StyledString("...").foreground(...)`,
/// `.traits(...)`, or via the chain helpers on `String` (`.red.bold`).
/// Concatenate with `+`.
public struct StyledString: Sendable, Equatable {
    public var runs: [StyledRun]

    public init() { self.runs = [] }
    public init(_ text: String) { self.runs = [StyledRun(text: text)] }
    public init(runs: [StyledRun]) { self.runs = runs }

    // MARK: - Builder methods (return new value)

    /// Set the foreground color on every run that doesn't already
    /// have one. Doesn't override per-run colors — useful for
    /// "default foreground" behavior on plain segments.
    public func foreground(_ color: InkColor) -> StyledString {
        StyledString(runs: runs.map { run in
            var r = run
            if r.foreground == nil { r.foreground = color }
            return r
        })
    }

    /// Set the background color on every run that doesn't already
    /// have one.
    public func background(_ color: InkColor) -> StyledString {
        StyledString(runs: runs.map { run in
            var r = run
            if r.background == nil { r.background = color }
            return r
        })
    }

    /// Add `traits` to every run's existing trait set (union).
    public func traits(_ t: TextTraits) -> StyledString {
        StyledString(runs: runs.map { run in
            var r = run
            r.traits.formUnion(t)
            return r
        })
    }

    // MARK: - Render

    /// Emit the final terminal-bound string. `capability` controls
    /// downgrade and ANSI stripping per HYP-56:
    ///
    ///   - `.none` strips all SGR (NO_COLOR / piped output)
    ///   - `.basic16` collapses every color to a named slot
    ///   - `.ansi256` collapses RGB to the 6×6×6 cube + grayscale
    ///   - `.trueColor` passes RGB through unchanged
    ///
    /// Each non-plain run emits `CSI ... m` opening + text + `CSI 0 m`
    /// reset. Plain runs pass through verbatim — no escape overhead.
    public func render(capability: ColorCapability) -> String {
        var out = ""
        for run in runs {
            // Capability-stripped → plain text. The capability check
            // also handles `run.isPlain` since stripping yields no
            // codes either way.
            if capability == .none || run.isPlain {
                out += run.text
                continue
            }
            if let fg = run.foreground {
                out += ANSICode.foreground(capability.downgrade(fg))
            }
            if let bg = run.background {
                out += ANSICode.background(capability.downgrade(bg))
            }
            if !run.traits.isEmpty {
                out += ANSICode.traits(run.traits)
            }
            out += run.text
            out += ANSICode.reset
        }
        return out
    }
}

// MARK: - Concatenation

public func + (lhs: StyledString, rhs: StyledString) -> StyledString {
    StyledString(runs: lhs.runs + rhs.runs)
}

public func + (lhs: StyledString, rhs: String) -> StyledString {
    StyledString(runs: lhs.runs + [StyledRun(text: rhs)])
}

public func + (lhs: String, rhs: StyledString) -> StyledString {
    StyledString(runs: [StyledRun(text: lhs)] + rhs.runs)
}
