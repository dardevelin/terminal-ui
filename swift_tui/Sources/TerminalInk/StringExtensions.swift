// chain-style ergonomic API on `String`.
//
//   "error".red.bold       // StyledString
//   "ok".success
//   "Hello, \(name.cyan)"  // works because StyledString is interpolatable
//
// These extensions give callers the dollar-sign-free ergonomics the
// ticket pitched. Each named-color and trait property returns a fresh
// `StyledString`; the cascade composes by re-applying on the result
// — `"x".red.bold` is `"x".red` (StyledString) followed by `.bold`
// (StyledString → StyledString trait setter).
//
// Underneath: `String.red` constructs `StyledString(self).foreground(.red)`,
// `StyledString.bold` calls `traits(.bold)`. The two namespaces share
// names because they target different types — Swift overload
// resolution picks the right one at every step of the chain.

extension String {
    /// Programmatic counterpart to the named chain helpers
    /// (`.red`, `.bold`, etc.) — useful when the color/traits are
    /// values rather than literals (e.g., picked from a level enum
    /// or theme). Composes the same as the chain form:
    ///
    ///     "ERROR".styled(level.color, .bold)
    public func styled(_ color: InkColor, _ traits: TextTraits = []) -> StyledString {
        var s = StyledString(self).foreground(color)
        if !traits.isEmpty { s = s.traits(traits) }
        return s
    }

    // Named colors — 16 ANSI slots.
    public var black:         StyledString { StyledString(self).foreground(.named(.black)) }
    public var red:           StyledString { StyledString(self).foreground(.named(.red)) }
    public var green:         StyledString { StyledString(self).foreground(.named(.green)) }
    public var yellow:        StyledString { StyledString(self).foreground(.named(.yellow)) }
    public var blue:          StyledString { StyledString(self).foreground(.named(.blue)) }
    public var magenta:       StyledString { StyledString(self).foreground(.named(.magenta)) }
    public var cyan:          StyledString { StyledString(self).foreground(.named(.cyan)) }
    public var white:         StyledString { StyledString(self).foreground(.named(.white)) }
    public var brightBlack:   StyledString { StyledString(self).foreground(.named(.brightBlack)) }
    public var brightRed:     StyledString { StyledString(self).foreground(.named(.brightRed)) }
    public var brightGreen:   StyledString { StyledString(self).foreground(.named(.brightGreen)) }
    public var brightYellow:  StyledString { StyledString(self).foreground(.named(.brightYellow)) }
    public var brightBlue:    StyledString { StyledString(self).foreground(.named(.brightBlue)) }
    public var brightMagenta: StyledString { StyledString(self).foreground(.named(.brightMagenta)) }
    public var brightCyan:    StyledString { StyledString(self).foreground(.named(.brightCyan)) }
    public var brightWhite:   StyledString { StyledString(self).foreground(.named(.brightWhite)) }

    // Semantic shorthand — themable layer.
    public var primary:   StyledString { StyledString(self).foreground(.primary) }
    public var secondary: StyledString { StyledString(self).foreground(.secondary) }
    public var success:   StyledString { StyledString(self).foreground(.success) }
    public var warning:   StyledString { StyledString(self).foreground(.warning) }
    public var error:     StyledString { StyledString(self).foreground(.error) }
    public var muted:     StyledString { StyledString(self).foreground(.muted) }

    // Trait shorthand. SGR boolean attributes — bold, italic, etc.
    public var bold:          StyledString { StyledString(self).traits(.bold) }
    public var italic:        StyledString { StyledString(self).traits(.italic) }
    public var underline:     StyledString { StyledString(self).traits(.underline) }
    public var dim:           StyledString { StyledString(self).traits(.dim) }
    public var strikethrough: StyledString { StyledString(self).traits(.strikethrough) }
    public var inverse:       StyledString { StyledString(self).traits(.inverse) }
}

extension StyledString {
    // Mirror trait shorthand on StyledString so the chain flows:
    //   "x".red.bold.underline
    public var bold:          StyledString { traits(.bold) }
    public var italic:        StyledString { traits(.italic) }
    public var underline:     StyledString { traits(.underline) }
    public var dim:           StyledString { traits(.dim) }
    public var strikethrough: StyledString { traits(.strikethrough) }
    public var inverse:       StyledString { traits(.inverse) }

    // Mirror semantic-color shorthand so callers can apply theme
    // colors to a pre-built StyledString without unwrapping to text.
    public var primary:   StyledString { foreground(.primary) }
    public var secondary: StyledString { foreground(.secondary) }
    public var success:   StyledString { foreground(.success) }
    public var warning:   StyledString { foreground(.warning) }
    public var error:     StyledString { foreground(.error) }
    public var muted:     StyledString { foreground(.muted) }
}
