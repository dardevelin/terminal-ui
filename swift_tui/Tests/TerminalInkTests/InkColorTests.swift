import Testing
@testable import TerminalInk

// HYP-56 / HYP-13 — TerminalInk ships its own color model so non-render
// tooling (swtui CLI, DevTools dumps, future Log) can produce styled
// output without pulling the full TUI runtime. The model also subsumes
// the older HYP-13 truecolor → 256 → 16 downgrade ticket: degradation
// happens at write time, driven by `ColorCapability` detected from
// `$COLORTERM` / `$TERM` / `$NO_COLOR` / `isatty(1)`.

@Suite("InkColor — color model")
struct InkColorTests {

    @Test("named colors enumerate all 16 ANSI standard colors")
    func namedColorsCount() {
        // Black + 7 + bright variants = 16. Spec: ECMA-48 §8.3.117 SGR
        // 30-37 (foreground) and 90-97 (bright foreground).
        #expect(NamedColor.allCases.count == 16,
                "NamedColor must cover the 16 ANSI palette slots; got \(NamedColor.allCases.count)")
    }

    @Test("InkColor.named carries a NamedColor")
    func namedCase() {
        let c = InkColor.named(.red)
        if case .named(let n) = c { #expect(n == .red) } else { Issue.record("not named") }
    }

    @Test("InkColor.ansi256 carries a UInt8 index")
    func ansi256Case() {
        let c = InkColor.ansi256(202)
        if case .ansi256(let n) = c { #expect(n == 202) } else { Issue.record("not ansi256") }
    }

    @Test("InkColor.rgb carries three channels")
    func rgbCase() {
        let c = InkColor.rgb(255, 128, 0)
        if case .rgb(let r, let g, let b) = c {
            #expect(r == 255); #expect(g == 128); #expect(b == 0)
        } else {
            Issue.record("not rgb")
        }
    }

    @Test("semantic shorthand is reachable")
    func semanticColors() {
        // `.success` / `.warning` / `.error` / `.muted` / `.primary` /
        // `.secondary` are part of the spec — they MUST exist as static
        // members so callers can write `.foreground(.error)` without
        // memorizing palette indices.
        _ = InkColor.primary
        _ = InkColor.secondary
        _ = InkColor.success
        _ = InkColor.warning
        _ = InkColor.error
        _ = InkColor.muted
    }
}

@Suite("ColorCapability — detection from environment")
struct ColorCapabilityDetectTests {

    @Test("COLORTERM=truecolor → trueColor")
    func truecolor() {
        let cap = ColorCapability.detect(env: ["COLORTERM": "truecolor"], isTTY: true)
        #expect(cap == .trueColor)
    }

    @Test("COLORTERM=24bit → trueColor")
    func twentyFourBit() {
        let cap = ColorCapability.detect(env: ["COLORTERM": "24bit"], isTTY: true)
        #expect(cap == .trueColor)
    }

    @Test("TERM=xterm-256color (no COLORTERM) → ansi256")
    func ansi256() {
        let cap = ColorCapability.detect(env: ["TERM": "xterm-256color"], isTTY: true)
        #expect(cap == .ansi256)
    }

    @Test("TERM without 256color (no COLORTERM) → basic16")
    func basic16Default() {
        let cap = ColorCapability.detect(env: ["TERM": "xterm"], isTTY: true)
        #expect(cap == .basic16)
    }

    @Test("NO_COLOR set (any value) → none, even with COLORTERM=truecolor")
    func noColorWins() {
        // Spec: https://no-color.org — "When present, regardless of its
        // value, prevents the addition of ANSI color." NO_COLOR must
        // beat every positive capability signal.
        let cap = ColorCapability.detect(env: ["COLORTERM": "truecolor", "NO_COLOR": "1"], isTTY: true)
        #expect(cap == .none)
    }

    @Test("NO_COLOR= (empty string) — per spec also disables color (any value)")
    func noColorEmpty() {
        let cap = ColorCapability.detect(env: ["COLORTERM": "truecolor", "NO_COLOR": ""], isTTY: true)
        #expect(cap == .none)
    }

    @Test("isTTY=false → none, regardless of env (output is piped)")
    func pipedOutput() {
        let cap = ColorCapability.detect(env: ["COLORTERM": "truecolor"], isTTY: false)
        #expect(cap == .none)
    }
}

@Suite("ColorCapability — downgrade")
struct ColorCapabilityDowngradeTests {

    @Test("trueColor passes RGB through unchanged")
    func trueColorPassthrough() {
        let c = InkColor.rgb(123, 45, 67)
        let down = ColorCapability.trueColor.downgrade(c)
        #expect(down == c)
    }

    @Test("ansi256 collapses RGB to nearest 256-palette index")
    func rgbTo256() {
        // Pure red (255, 0, 0) maps to ansi 196 in the standard 256
        // palette — the brightest red in the 6×6×6 RGB cube.
        let c = InkColor.rgb(255, 0, 0)
        let down = ColorCapability.ansi256.downgrade(c)
        if case .ansi256(let n) = down {
            #expect(n == 196,
                    "pure red (255,0,0) must map to ansi256 196 (top-left red corner of the 6×6×6 cube); got \(n)")
        } else {
            Issue.record("downgraded color not ansi256: \(down)")
        }
    }

    @Test("basic16 collapses RGB to nearest named color")
    func rgbToNamed() {
        // Pure red (255, 0, 0) → `.brightRed` (the 16-color palette's
        // closest match — index 9 in CGA-style mapping).
        let c = InkColor.rgb(255, 0, 0)
        let down = ColorCapability.basic16.downgrade(c)
        if case .named(let n) = down {
            #expect(n == .brightRed || n == .red,
                    "pure red must map to .red or .brightRed; got \(n)")
        } else {
            Issue.record("downgraded color not named: \(down)")
        }
    }

    @Test("none erases color to .default")
    func noneErases() {
        let c = InkColor.rgb(255, 128, 0)
        let down = ColorCapability.none.downgrade(c)
        #expect(down == .default)
    }
}

@Suite("ANSICode — SGR escape sequence generation")
struct ANSICodeTests {

    @Test("named foreground produces the 30-series SGR code")
    func namedForeground() {
        let code = ANSICode.foreground(.named(.red))
        #expect(code == "\u{1B}[31m",
                "red foreground must be CSI 31 m; got \(code.debugDescription)")
    }

    @Test("named bright foreground produces the 90-series SGR code")
    func brightForeground() {
        let code = ANSICode.foreground(.named(.brightRed))
        #expect(code == "\u{1B}[91m")
    }

    @Test("ansi256 foreground uses the CSI 38;5;n m form")
    func ansi256Foreground() {
        let code = ANSICode.foreground(.ansi256(202))
        #expect(code == "\u{1B}[38;5;202m")
    }

    @Test("RGB foreground uses the CSI 38;2;r;g;b m form")
    func rgbForeground() {
        let code = ANSICode.foreground(.rgb(255, 128, 0))
        #expect(code == "\u{1B}[38;2;255;128;0m")
    }

    @Test("named background uses the 40-series SGR code")
    func namedBackground() {
        let code = ANSICode.background(.named(.blue))
        #expect(code == "\u{1B}[44m")
    }

    @Test(".default foreground returns the SGR-39 reset")
    func defaultReset() {
        let code = ANSICode.foreground(.default)
        #expect(code == "\u{1B}[39m")
    }

    @Test("reset() emits the SGR-0 sequence")
    func reset() {
        #expect(ANSICode.reset == "\u{1B}[0m")
    }
}
